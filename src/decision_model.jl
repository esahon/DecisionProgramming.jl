using JuMP

function decision_variable(model::Model, S::States, d::DecisionNode, base_name::String="")
    # Create decision variables.
    dims = S[[d.I_j; d.j]]
    z_j = Array{VariableRef}(undef, dims...)
    for s in paths(dims)
        z_j[s...] = @variable(model, binary=true, base_name=base_name)
    end
    # Constraints to one decision per decision strategy.
    for s_I in paths(S[d.I_j])
        @constraint(model, sum(z_j[s_I..., s_j] for s_j in 1:S[d.j]) == 1)
    end
    return z_j
end

struct DecisionVariables
    D::Vector{DecisionNode}
    z::Vector{<:Array{VariableRef}}
end

"""Create decision variables and constraints.

# Examples
```julia
z = DecisionVariables(model, S, D)
```
"""
function DecisionVariables(model::Model, S::States, D::Vector{DecisionNode}; names::Bool=false, name::String="z")
    DecisionVariables(D, [decision_variable(model, S, d, (names ? "$(name)_$(d.j)$(s)" : "")) for d in D])
end

function is_forbidden(s::Path, forbidden_paths::Vector{ForbiddenPath})
    return !all(s[k]∉v for (k, v) in forbidden_paths)
end

function binary_path_variable(model::Model, z::DecisionVariables, base_name::String="")
    # Create a binary path variable
    x = @variable(model, base_name=base_name)

    # Constraint on the lower and upper bounds.
    @constraint(model, 0 ≤ x ≤ 1.0)

    return x
end

struct BinaryPathVariables{N} <: AbstractDict{Path{N}, VariableRef}
    data::Dict{Path{N}, VariableRef}
end

Base.getindex(x_s::BinaryPathVariables, key) = getindex(x_s.data, key)
Base.get(x_s::BinaryPathVariables, key, default) = get(x_s.data, key, default)
Base.keys(x_s::BinaryPathVariables) = keys(x_s.data)
Base.values(x_s::BinaryPathVariables) = values(x_s.data)
Base.pairs(x_s::BinaryPathVariables) = pairs(x_s.data)
Base.iterate(x_s::BinaryPathVariables) = iterate(x_s.data)
Base.iterate(x_s::BinaryPathVariables, i) = iterate(x_s.data, i)


function decision_strategy_constraint(model::Model, S::States, d::DecisionNode, D::Vector{DecisionNode}, z::Array{VariableRef}, x_s::BinaryPathVariables)

    # states of nodes in information structure (s_j | s_I(j))
    dims = S[[d.I_j; d.j]]

    # Theoretical upper bound based on number of paths with information structure (s_j | s_I(j)) divided by number of possible decision strategies in other decision nodes
    other_decisions = map(d_n -> d_n.j, filter(d_n -> all(d_n.j != i for i in [d.I_j; d.j]), D))
    theoretical_ub = prod(S)/prod(dims)/ prod(S[other_decisions])

    # paths that have corresponding binary path variables
    existing_paths = keys(x_s)

    for s_j_s_Ij in paths(dims) # iterate through all information states and states of d
        # paths with (s_j | s_I(j)) information structure
        feasible_paths = filter(s -> s[[d.I_j; d.j]] == s_j_s_Ij, existing_paths)

        @constraint(model, sum(get(x_s, s, 0) for s in feasible_paths) ≤ z[s_j_s_Ij...] * min(length(feasible_paths), theoretical_ub))
    end
end


"""Create binary path variables and constraints.

# Examples
```julia
x_s = BinaryPathVariables(model, z, S, P)
x_s = BinaryPathVariables(model, z, S, P; probability_cut = false)
```
"""
function BinaryPathVariables(model::Model,
    z::DecisionVariables,
    S::States,
    P::AbstractPathProbability;
    names::Bool=false,
    name::String="x_s",
    forbidden_paths::Vector{ForbiddenPath}=ForbiddenPath[],
    fixed::Dict{Node, State}=Dict{Node, State}(),
    probability_cut::Bool=true)

    if !isempty(forbidden_paths)
        @warn("Forbidden paths is still an experimental feature.")
    end

    # Create path probability variable for each effective path.
    N = length(S)
    variables_x_s = Dict{Path{N}, VariableRef}(
        s => binary_path_variable(model, z, (names ? "$(name)$(s)" : ""))
        for s in paths(S, fixed)
        if !iszero(P(s)) && !is_forbidden(s, forbidden_paths)
    )

    x_s = BinaryPathVariables{N}(variables_x_s)

    # Add decision strategy constraints for each decision node
    for (d, z_d) in zip(z.D, z.z)
        decision_strategy_constraint(model, S, d, z.D, z_d, x_s)
    end

    if probability_cut
        @constraint(model, sum(x * P(s) for (s, x) in x_s) == 1.0)
    end

    x_s
end

"""Adds a probability cut to the model as a lazy constraint.

# Examples
```julia
lazy_probability_cut(model, x_s, P)
```
"""
function lazy_probability_cut(model::Model, x_s::BinaryPathVariables, P::AbstractPathProbability)

    function probability_cut(cb_data)
        xsum = sum(callback_value(cb_data, x) * P(s) for (s, x) in x_s)
        if !isapprox(xsum, 1.0)
            con = @build_constraint(sum(x * P(s) for (s, x) in x_s) == 1.0)
            MOI.submit(model, MOI.LazyConstraint(cb_data), con)
        end
    end
    MOI.set(model, MOI.LazyConstraintCallback(), probability_cut)
end

# --- Objective Functions ---

"""Positive affine transformation of path utility. Always evaluates positive values.

# Examples
```julia-repl
julia> U⁺ = PositivePathUtility(S, U)
julia> all(U⁺(s) > 0 for s in paths(S))
true
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

(U::PositivePathUtility)(s::Path) = U.U(s) - U.min + 1

"""Negative affine transformation of path utility. Always evaluates negative values.

# Examples
```julia-repl
julia> U⁻ = NegativetivePathUtility(S, U)
julia> all(U⁻(s) < 0 for s in paths(S))
true
```
"""
struct NegativePathUtility <: AbstractPathUtility
    U::AbstractPathUtility
    max::Float64
    function NegativePathUtility(S::States, U::AbstractPathUtility)
        u_max = maximum(U(s) for s in paths(S))
        new(U, u_max)
    end
end

(U::NegativePathUtility)(s::Path) = U.U(s) - U.max - 1


"""Create an expected value objective.

# Examples
```julia
EV = expected_value(model, x_s, U, P)
EV = expected_value(model, x_s, U, P; probability_scale_factor = 10.0)
```
"""
function expected_value(model::Model, x_s::BinaryPathVariables, U::AbstractPathUtility, P::AbstractPathProbability; probability_scale_factor::Float64=1.0)
    if probability_scale_factor ≤ 0
        throw(DomainError("The probability_scale_factor must be greater than 0."))
    end

    @expression(model, sum(P(s) * x * U(s) * probability_scale_factor for (s, x) in x_s))
end

"""Create a conditional value-at-risk (CVaR) objective.

# Examples
```julia
α = 0.05  # Parameter such that 0 ≤ α ≤ 1
CVaR = conditional_value_at_risk(model, x_s, U, P, α)
CVaR = conditional_value_at_risk(model, x_s, U, P, α; probability_scale_factor = 10.0)
```
"""
function conditional_value_at_risk(model::Model, x_s::BinaryPathVariables{N}, U::AbstractPathUtility, P::AbstractPathProbability, α::Float64; probability_scale_factor::Float64=1.0) where N
    if probability_scale_factor ≤ 0
        throw(DomainError("The probability_scale_factor must be greater than 0."))
    end
    if !(0 < α ≤ 1)
        throw(DomainError("α should be 0 < α ≤ 1"))
    end

    if !(probability_scale_factor == 1.0)
        @warn("The conditional value at risk is scaled by the probability_scale_factor. Make sure other terms of the objective function are also scaled.")
    end

    # Pre-computed parameters
    u = collect(Iterators.flatten(U(s) for s in keys(x_s)))
    u_sorted = sort(u)
    u_min = u_sorted[1]
    u_max = u_sorted[end]
    M = u_max - u_min
    u_diff = diff(u_sorted)
    ϵ = if isempty(u_diff) 0.0 else minimum(filter(!iszero, abs.(u_diff))) / 2 end

    # Variables and constraints
    η = @variable(model)
    @constraint(model, η ≥ u_min)
    @constraint(model, η ≤ u_max)
    ρ′_s = Dict{Path{N}, VariableRef}()
    for (s, x) in x_s
        u_s = U(s)
        λ = @variable(model, binary=true)
        λ′ = @variable(model, binary=true)
        ρ = @variable(model)
        ρ′ = @variable(model)
        @constraint(model, η - u_s ≤ M * λ)
        @constraint(model, η - u_s ≥ (M + ϵ) * λ - M)
        @constraint(model, η - u_s ≤ (M + ϵ) * λ′ - ϵ)
        @constraint(model, η - u_s ≥ M * (λ′ - 1))
        @constraint(model, 0 ≤ ρ)
        @constraint(model, 0 ≤ ρ′)
        @constraint(model, ρ ≤ λ * probability_scale_factor)
        @constraint(model, ρ′ ≤ λ′* probability_scale_factor)
        @constraint(model, ρ ≤ ρ′)
        @constraint(model, ρ′ ≤ x * P(s) * probability_scale_factor)
        @constraint(model, (x * P(s) - (1 - λ))* probability_scale_factor ≤ ρ)
        ρ′_s[s] = ρ′
    end
    @constraint(model, sum(values(ρ′_s)) == α * probability_scale_factor)

    # Return CVaR as an expression
    CVaR = @expression(model, sum(ρ_bar * U(s) for (s, ρ_bar) in ρ′_s) / α)

    return CVaR
end

# --- Construct decision strategy from JuMP variables ---

"""Construct decision strategy from variable refs."""
function LocalDecisionStrategy(j::Node, z::Array{VariableRef})
    LocalDecisionStrategy(j, @. Int(round(value(z))))
end

"""Extract values for decision variables from solved decision model.

# Examples
```julia
Z = DecisionStrategy(z)
```
"""
function DecisionStrategy(z::DecisionVariables)
    DecisionStrategy(z.D, [LocalDecisionStrategy(d.j, v) for (d, v) in zip(z.D, z.z)])
end
