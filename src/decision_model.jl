using Parameters, JuMP

"""Positive affine transformation of path utility.

# Examples
```julia
U⁺ = PositivePathUtility(S, U)
```
"""
struct PositivePathUtility <: AbstractPathUtility
    U::AbstractPathUtility
    min::Float64
    function PositivePathUtility(S::States, U::AbstractPathUtility)
        u_min = minimum(U(s) for s in paths(S))
        new(U, u_min)
    end
end

"""Evaluate positive affine transformation of the path utility.

# Examples
```julia-repl
julia> all(U⁺(s) ≥ 1 for s in paths(S))
true
```
"""
(U::PositivePathUtility)(s::Path) = U.U(s) - U.min + 1

"""Create a multidimensional array of JuMP variables.

# Examples
```julia
model = Model()
v1 = variables(model, [2, 3, 2])
v2 = variables(model, [2, 3, 2]; binary=true)
```
"""
function variables(model::Model, dims::AbstractVector{Int}; binary::Bool=false, names::Union{Nothing, Array{String}}=nothing)
    v = Array{VariableRef}(undef, dims...)
    for i in eachindex(v)
        name = if isnothing(names) "" else names[i] end
        v[i] = @variable(model, binary=binary, base_name = name)
    end
    return v
end

"""DecisionModel type. Alias for `JuMP.Model`."""
const DecisionModel = Model

"""Construct a DecisionModel from states, decision nodes and path probability.

# Examples
```julia
model = DecisionModel(S, D, P; positive_path_utility=true)
```
"""
function DecisionModel(S::States, D::Vector{DecisionNode}, P::AbstractPathProbability; positive_path_utility::Bool=false, names::Bool=false)
    model = DecisionModel()

    # --- Decision variables ---
    z_names(z, dims) = if names; ["z_$z$s" for s in paths(dims)] else nothing end
    z = [variables(model, S[[d.I_j; d.j]]; binary=true, names=z_names(d.j, S[[d.I_j; d.j]])) for d in D]

    # Constraints to one decision per decision strategy.
    for (d, z_j) in zip(D, z)
        for s_I in paths(S[d.I_j])
            @constraint(model, sum(z_j[s_I..., s_j] for s_j in 1:S[d.j]) == 1)
        end
    end

    # --- Path probability variables ---
    π_names = if names; ["π$s" for s in paths(S)] else nothing end
    π = variables(model, S; names=π_names)

    for s in paths(S)
        if iszero(P(s))
            # If the upper bound is zero, we fix the value to zero.
            fix(π[s...], 0)
        else
            # Strict upper bound and non-strict lower bound.
            @constraint(model, 0 ≤ π[s...] ≤ P(s))

            # Constraints the path probability to zero if the path is
            # incompatible with the decision strategy.
            for (d, z_j) in zip(D, z)
                @constraint(model, π[s...] ≤ z_j[s[[d.I_j; d.j]]...])
            end

            # Strict lower bound.
            if !positive_path_utility
                @constraint(model,
                    π[s...] ≥ P(s) + sum(z_j[s[[d.I_j; d.j]]...] for (d, z_j) in zip(D, z)) - length(D))
            end
        end
    end

    model[:π] = π
    model[:z] = z

    return model
end

"""Adds a probability sum cut to the model as a lazy constraint.

# Examples
```julia
probability_cut(model, S, P)
```
"""
function probability_cut(model::DecisionModel, S::States, P::AbstractPathProbability)
    # Add the constraints only once
    ϵ = minimum(P(s) for s in paths(S))
    flag = false
    function probability_cut(cb_data)
        flag && return
        π = model[:π]
        πsum = sum(callback_value(cb_data, π[s]) for s in eachindex(π))
        if !isapprox(πsum, 1.0, atol=ϵ)
            con = @build_constraint(sum(π) == 1.0)
            MOI.submit(model, MOI.LazyConstraint(cb_data), con)
            flag = true
        end
    end
    MOI.set(model, MOI.LazyConstraintCallback(), probability_cut)
end

"""Adds a number of paths cut to the model as a lazy constraint.

# Examples
```julia
atol = 0.9  # Tolerance to trigger the creation of the lazy cut
active_paths_cut(model, S, P; atol=atol)
```
"""
function active_paths_cut(model::DecisionModel, S::States, P::AbstractPathProbability; atol::Float64 = 0.9)
    all_active_states = all(all((!).(iszero.(x))) for x in P.X)
    if !all_active_states
        throw(DomainError("Cannot use active paths cut if all states are not active."))
    end
    ϵ = minimum(P(s) for s in paths(S))
    num_compatible_paths = prod(S[c.j] for c in P.C)
    # Add the constraints only once
    flag = false
    function active_paths_cut(cb_data)
        flag && return
        π = model[:π]
        πnum = sum(callback_value(cb_data, π[s]) ≥ ϵ for s in eachindex(π))
        if !isapprox(πnum, num_compatible_paths, atol = atol)
            num_active_paths = @expression(model, sum(π[s...] / P(s) for s in paths(S) if !iszero(P(s))))
            con = @build_constraint(num_active_paths == num_compatible_paths)
            MOI.submit(model, MOI.LazyConstraint(cb_data), con)
            flag = true
        end
    end
    MOI.set(model, MOI.LazyConstraintCallback(), active_paths_cut)
end


# --- Objective Functions ---

"""Create an expected value objective.

# Examples
```julia
EV = expected_value(model, S, U)
```
"""
function expected_value(model::DecisionModel, S::States, U::AbstractPathUtility)
    @expression(model, sum(model[:π][s...] * U(s) for s in paths(S)))
end

"""Create a conditional value-at-risk (CVaR) objective.

# Examples
```julia
α = 0.05  # Parameter such that 0 ≤ α ≤ 1
CVaR = conditional_value_at_risk(model, S, U, α)
```
"""
function conditional_value_at_risk(model::DecisionModel, S::States, U::AbstractPathUtility, α::Float64)
    if !(0 ≤ α ≤ 1)
        throw(DomainError("α should be 0 ≤ α ≤ 1"))
    end

    # Pre-computer parameters
    u = collect(Iterators.flatten(U(s) for s in paths(S)))
    u_sorted = sort(u)
    u_min = u_sorted[1]
    u_max = u_sorted[end]
    M = u_max - u_min
    ϵ = minimum(filter(!iszero, abs.(diff(u_sorted)))) / 2

    # Variables
    η = @variable(model)
    λ = variables(model, S; binary=true)
    λ_bar = variables(model, S; binary=true)
    ρ = variables(model, S)
    ρ_bar = variables(model, S)

    # Constraints
    π = model[:π]
    @constraint(model, u_min ≤ η ≤ u_max)
    for s in paths(S)
        u_s = U(s)
        @constraint(model, η - u_s ≤ M * λ[s...])
        @constraint(model, η - u_s ≥ (M + ϵ) * λ[s...] - M)
        @constraint(model, η - u_s ≤ (M + ϵ) * λ_bar[s...] - ϵ)
        @constraint(model, η - u_s ≥ M * (λ_bar[s...] - 1))
        @constraint(model, 0 ≤ ρ[s...])
        @constraint(model, 0 ≤ ρ_bar[s...])
        @constraint(model, ρ[s...] ≤ λ[s...])
        @constraint(model, ρ_bar[s...] ≤ λ_bar[s...])
        @constraint(model, ρ[s...] ≤ ρ_bar[s...])
        @constraint(model, ρ_bar[s...] ≤ π[s...])
        @constraint(model, π[s...] - (1 - λ[s...]) ≤ ρ[s...])
    end
    @constraint(model, sum(ρ_bar[s...] for s in paths(S)) == α)

    # Add variables to the model
    model[:η] = η
    model[:ρ] = ρ
    model[:ρ_bar] = ρ_bar

    # Return CVaR as an expression
    CVaR = @expression(model, sum(ρ_bar[s...] * U(s) for s in paths(S)) / α)

    return CVaR
end


# --- Decision Strategy ---

"""Decision strategy type."""
struct LocalDecisionStrategy{N} <: AbstractArray{Int, N}
    data::Array{Int, N}
    function LocalDecisionStrategy(data::Array{Int, N}) where N
        if !all(0 ≤ x ≤ 1 for x in data)
            throw(DomainError("All values x must be 0 ≤ x ≤ 1."))
        end
        for s_I in CartesianIndices(size(data)[1:end-1])
            if !(sum(data[s_I, :]) == 1)
                throw(DomainError("Values should add to one."))
            end
        end
        new{N}(data)
    end
end

Base.size(Z::LocalDecisionStrategy) = size(Z.data)
Base.IndexStyle(::Type{<:LocalDecisionStrategy}) = IndexLinear()
Base.getindex(Z::LocalDecisionStrategy, i::Int) = getindex(Z.data, i)
Base.getindex(Z::LocalDecisionStrategy, I::Vararg{Int,N}) where N = getindex(Z.data, I...)

"""Construct decision strategy from variable refs."""
function LocalDecisionStrategy(z::Array{VariableRef})
    LocalDecisionStrategy(@. Int(round(value(z))))
end

"""Evalute decision strategy."""
(Z::LocalDecisionStrategy)(s_I::Path)::State = findmax(Z[s_I..., :])[2]


"""Global decision strategy type."""
struct DecisionStrategy
    D::Vector{DecisionNode}
    Z_j::Vector{LocalDecisionStrategy}
end

"""Extract values for decision variables from solved decision model.

# Examples
```julia
Z = GlobalDecisionStrategy(model, D)
```
"""
function DecisionStrategy(model::DecisionModel, D::Vector{DecisionNode})
    DecisionStrategy(D, [LocalDecisionStrategy(v) for v in model[:z]])
end
