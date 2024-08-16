using DataFrames, PrettyTables
using StatsBase, StatsBase.Statistics
using DecisionProgramming
using Base64

"""
    print_decision_strategy(diagram::InfluenceDiagram, Z::DecisionStrategy, state_probabilities::StateProbabilities; show_incompatible_states::Bool = false)

Print decision strategy.

# Arguments
- `diagram::InfluenceDiagram`: Influence diagram structure.
- `Z::DecisionStrategy`: Decision strategy structure with optimal decision strategy.
- `state_probabilities::StateProbabilities`: State probabilities structure corresponding to optimal decision strategy.
- `show_incompatible_states::Bool`: Choice to print rows also for incompatible states.

# Examples
```julia
print_decision_strategy(diagram, Z, S_probabilities)
```
"""
function print_decision_strategy(diagram::InfluenceDiagram, Z::DecisionStrategy, state_probabilities::StateProbabilities; show_incompatible_states::Bool = false)
    probs = state_probabilities.probs

    for (d, I_d, Z_d) in zip(Z.D, Z.I_d, Z.Z_d)
        s_I = vec(collect(paths(get_values(diagram.S)[I_d])))
        s_d = [Z_d(s) for s in s_I]

        if !isempty(I_d)
            informations_states = [join([String(get_values(diagram.States)[i][s_i]) for (i, s_i) in zip(I_d, s)], ", ") for s in s_I]
            decision_probs = [ceil(prod(probs[i][s1] for (i, s1) in zip(I_d, s))) for s in s_I]
            decisions = collect(p == 0 ? "--" : get_values(diagram.States)[d][s] for (s, p) in zip(s_d, decision_probs))
            df = DataFrame(informations_states = informations_states, decisions = decisions)
            if !show_incompatible_states
                 filter!(row -> row.decisions != "--", df)
            end
            pretty_table(df, header = ["State(s) of $(join([diagram.Names[i] for i in I_d], ", "))", "Decision in $(diagram.Names[d])"], alignment=:l)
        else
            df = DataFrame(decisions = get_values(diagram.States)[d][s_d])
            pretty_table(df, header = ["Decision in $(diagram.Names[d])"], alignment=:l)
        end
    end
end

"""
    print_utility_distribution(U_distribution::UtilityDistribution; util_fmt="%f", prob_fmt="%f")

Print utility distribution.

# Examples
```julia
U_distribution = UtilityDistribution(diagram, Z)
print_utility_distribution(U_distribution)
```
"""
function print_utility_distribution(U_distribution::UtilityDistribution; util_fmt="%f", prob_fmt="%f")
    df = DataFrame(Utility = U_distribution.u, Probability = U_distribution.p)
    formatters = (
        ft_printf(util_fmt, [1]),
        ft_printf(prob_fmt, [2]))
    pretty_table(df; formatters = formatters)
end

"""
    print_state_probabilities(diagram::InfluenceDiagram, state_probabilities::StateProbabilities, nodes::Vector{Name}; prob_fmt="%f")

Print state probabilities with fixed states.

# Examples
```julia
S_probabilities = StateProbabilities(diagram, Z)
print_state_probabilities(S_probabilities, ["R"])
print_state_probabilities(S_probabilities, ["A"])
```
"""
function print_state_probabilities(diagram::InfluenceDiagram, state_probabilities::StateProbabilities, nodes::Vector{Name}; prob_fmt="%f")
    node_indices = [findfirst(j -> j==node, diagram.Names) for node in nodes]
    states_list = get_values(diagram.States)[node_indices]
    state_sets = unique(states_list)
    n = length(states_list)

    probs = state_probabilities.probs
    fixed = state_probabilities.fixed

    prob(p, state) = if 1≤state≤length(p) p[state] else NaN end
    fix_state(i) = if i∈keys(fixed) string(get_values(diagram.States)[i][fixed[i]]) else "" end


    for state_set in state_sets
        node_indices2 = filter(i -> get_values(diagram.States)[i] == state_set, node_indices)
        state_names = get_values(diagram.States)[node_indices2[1]]
        states = 1:length(state_names)
        df = DataFrame()
        df[!, :Node] = diagram.Names[node_indices2]
        for state in states
            df[!, Symbol("$(state_names[state])")] = [prob(probs[i], state) for i in node_indices2]
        end
        df[!, Symbol("Fixed state")] = [fix_state(i) for i in node_indices2]
        pretty_table(df; formatters = ft_printf(prob_fmt, (first(states)+1):(last(states)+1)))
    end
end

"""
    print_statistics(U_distribution::UtilityDistribution; fmt = "%f")

Print statistics about utility distribution.
"""
function print_statistics(U_distribution::UtilityDistribution; fmt = "%f")
    u = U_distribution.u
    w = ProbabilityWeights(U_distribution.p)
    names = ["Mean", "Std", "Skewness", "Kurtosis"]
    statistics = [mean(u, w), std(u, w, corrected=false), skewness(u, w), kurtosis(u, w)]
    df = DataFrame(Name = names, Statistics = statistics)
    pretty_table(df, formatters = ft_printf(fmt, [2]))
end

"""
    print_risk_measures(U_distribution::UtilityDistribution, αs::Vector{Float64}; fmt = "%f")

Print risk measures.
"""
function print_risk_measures(U_distribution::UtilityDistribution, αs::Vector{Float64}; fmt = "%f")
    VaR = [value_at_risk(U_distribution, α) for α in αs]
    CVaR = [conditional_value_at_risk(U_distribution, α) for α in αs]
    df = DataFrame(α = αs, VaR = VaR, CVaR = CVaR)
    pretty_table(df, formatters = ft_printf(fmt))
end


#--- MERMAID GRAPH PRINTING FUNCTIONS ---

function nodes(diagram::InfluenceDiagram, class::String, edge::String; S::Union{Nothing, Vector{State}}=nothing)
    lines = []
    I_j = I_j_indices(diagram, diagram.Nodes)
    if class == "chance"
        N = indices(diagram.C)
        left = "(("
        right = "))"
    elseif class == "decision"
        N = indices(diagram.D)
        left = "["
        right = "]"
    elseif class == "value"
        N = indices(diagram.V)
        left = "{"
        right = "}"
    else
        throw(DomainError("Unknown class $(class)"))
    end
    for n in N
        if S === nothing
            push!(lines, "$(n)$(left)Node: $(diagram.Names[n])$(right)")
        else
            push!(lines, "$(n)$(left)Node: $(diagram.Names[n]) <br> $(S[n]) states$(right)")
        end
        if !isempty(I_j[n])
            I_j_joined = join(I_j[n], " & ")
            push!(lines, "$(I_j_joined) $(edge) $(n)")
        end
    end
    js = join([n for n in N], ",")
    push!(lines, "class $(js) $(class)")
    return join(lines, "\n")
end

function graph(diagram::InfluenceDiagram)
    return """
    graph LR
    %% Chance nodes
    $(nodes(diagram, "chance", "-->"; S=get_values(diagram.S)))

    %% Decision nodes
    $(nodes(diagram, "decision", "-->"; S=get_values(diagram.S)))

    %% Value nodes
    $(nodes(diagram, "value", "-.->"))

    %% Styles
    classDef chance fill:#F5F5F5 ,stroke:#666666,stroke-width:2px;
    classDef decision fill:#D5E8D4 ,stroke:#82B366,stroke-width:2px;
    classDef value fill:#FFE6CC ,stroke:#D79B00,stroke-width:2px;
    """
end

function mermaid(diagram::InfluenceDiagram, filename::String="mermaid_graph.png")
    graph_output = graph(diagram)
    graphbytes = codeunits(graph_output)
    base64_bytes = base64encode(graphbytes)
    img_url = "https://mermaid.ink/img/" * base64_bytes

    download(img_url, filename)
end