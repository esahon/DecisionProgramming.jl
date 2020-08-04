# Used Car Buyer

## Description
To illustrate the basic functionality of Decision Programming, we implement a version of the used car buyer problem in [^1]. In this problem, Joe is buying a used car. The price of the car is \$1000 and its value is \$1100. Joe's base profit on the car is thus \$100. However, Joe knows that the car is a "lemon", meaning that it has defects in 6 major systems, with a 20% probability. With the remaining 80% probability, the car is a "peach", and it has a defect in only one of the systems.

The repair costs for a peach are only \$40, decreasing Joe's profit to \$60. However, the costs for a lemon are \$200, resulting in a total loss of \$100. We can now formulate an influence diagram of Joe's initial problem. The influence diagram is presented in the figure below. In an influence diagram, circle nodes such as $O$ are called **chance nodes**, representing uncertainty. Node $O$ is a chance node representing the state of the car, lemon or peach. Square nodes such as $A$ are **decision nodes**, representing decisions. Node $A$ represents the decision to buy or not to buy the car. The diamond-shaped **value node** $V$ denotes the utility calculation in the problem. For Joe, the utility function is the expected monetary value. The arrows or **arcs** show connections between nodes. The two arcs in this diagram point to the value node, meaning that the monetary value depends on state of the car and the purchase decision.

![\label{used-car-buyer-1}](figures/used-car-buyer-1.svg)

The optimal strategy for this problem can easily be determined. If Joe decides not to buy the car, his profit is certainly \$0. If he buys the car, there is a 20% probability of a loss of \$100 and an 80% probability of a profit of \$60. The expected profit for buying the car is thus \$28, which is clearly higher than the zero profit of not buying. Thus, Joe should buy the car.

We now add two new features to the problem. A stranger approaches Joe, offering to tell Joe whether the car is a lemon or a peach, for a price of \$25. Additionally, the car dealer offers a guarantee plan which costs \$60 and covers 50% of the repair costs. Joe notes that this is not a very good deal and the dealer includes an anti-lemon feature: if the total repair cost exceeds \$100, the repairs are fully covered by the guarantee. The new influence diagram is presented below. The decision node $T$ denotes the decision to accept or decline the stranger's offer, and $R$ is the outcome of the test. New value nodes $V_1$ and $V_2$ are introduced to represent costs of testing and the base profit from purchasing the car. Additionally, the decision node $A$ now also has the possibility of choosing to buy with a guarantee.

![\label{used-car-buyer-2}](figures/used-car-buyer-2.svg)

## The model

### Influence diagram
```julia
using Printf, Random, Logging, Parameters, JuMP, Gurobi
using DecisionProgramming


const O = 1     # Chance node: lemon or peach
const T = 2     # Decision node: pay stranger for advice
const R = 3     # Chance node: observation of state of the car
const A = 4     # Decision node: purchase alternative
const O_states = ["lemon", "peach"]
const T_states = ["no test", "test"]
const R_states = ["no test", "lemon", "peach"]
const A_states = ["buy without guarantee", "buy with guarantee", "don't buy"]

C = Vector{ChanceNode}()
D = Vector{DecisionNode}()
V = Vector{ValueNode}()
S_j = Vector{State}(undef, 4)
S_j[O] = length(O_states)
S_j[T] = length(T_states)
S_j[R] = length(R_states)
S_j[A] = length(A_states)
```

We start by defining the influence diagram structure. The decision and chance nodes, as well as their states are defined in the first block. Next, the influence diagram parameters consisting of the node sets and the state spaces of the nodes are defined.

```julia
# Node O: no predecessors
I_O = Vector{Node}()
X_O = [0.2,0.8]
push!(C, ChanceNode(O, I_O, S_j[O], X_O))

# Node T: no predecessors
I_T = Vector{Node}()
push!(D, DecisionNode(T, I_T, S_j[T]))

# Node R: dependent on nodes O and T
I_R = [O,T]
X_R = zeros(S_j[O], S_j[T], S_j[R])
X_R[1, 1, :] = [1,0,0]
X_R[1, 2, :] = [0,1,0]
X_R[2, 1, :] = [1,0,0]
X_R[2, 2, :] = [0,0,1]
push!(C, ChanceNode(R, I_R, S_j[R], X_R))

# Node A: dependent on node R
I_A = [R]
push!(D, DecisionNode(A, I_A, S_j[A]))

# Cost of test
I_V1 = [T]
Y_V1 = [0, -25]
push!(V, ValueNode(5, I_V1, Y_V1))

# Base profit of purchase alternatives
I_V2 = [A]
Y_V2 = [100, 40, 0]
push!(V, ValueNode(6, I_V2, Y_V2))

# Repair costs
I_V3 = [O,A]
Y_V3 = [-200 0 0; -40 -20 0]
push!(V, ValueNode(7, I_V3, Y_V3))

```

We continue by defining the probabilities associated with chance nodes and utilities (consequences) associated with value nodes. The rows of the consequence matrix Y_V3 correspond to the state of the car, while the columns correspond to the decision made in node $A$.

### Decision model

```julia
@info("Defining InfluenceDiagram")
G = InfluenceDiagram(C, D, V)

@info("Creating probabilities.")
X = Probabilities(G, C)

@info("Creating consequences.")
Y = Consequences(G, V)

@info("Creating path probability.")
P = PathProbability(G, X)

@info("Creating path utility.")
U = PathUtility(G, Y)

@info("Defining DecisionModel")
@time model = DecisionModel(G, P)

@info("Creating model objective.")
@time E = expected_value(model, G, U)
@objective(model, Max, E)
```
We then construct the decision model using the DecisionProgramming.jl package.

```julia
@info("Starting the optimization process.")
optimizer = optimizer_with_attributes(
    Gurobi.Optimizer,
    "IntFeasTol"      => 1e-9,
    "LazyConstraints" => 1,
)
set_optimizer(model, optimizer)
optimize!(model)

@info("Extracting results.")
Z = DecisionStrategy(model)

@info("Printing decision strategy:")
print_decision_strategy(G, Z)
println()
```
The model is solved. We get the following decision strategy:

```
┌────────┬────┬───┐
│  Nodes │ () │ 2 │
├────────┼────┼───┤
│ States │ () │ 2 │
└────────┴────┴───┘
┌────────┬──────┬───┐
│  Nodes │ (3,) │ 4 │
├────────┼──────┼───┤
│ States │ (1,) │ 3 │
│ States │ (2,) │ 2 │
│ States │ (3,) │ 1 │
└────────┴──────┴───┘
```

To start explaining this output, let's take a look at the top table. On the right, we have the decision node 2. We defined earlier that the node $T$ is node number 2. On the left, we have the information set of that decision node, which is empty. The strategy in the first decision node is to choose alternative 2, which we defined to be testing the car.

In the bottom table, we have node number 4 (node $A$) and its predecessor, node number 3 (node $R$). The first row, where no test result is obtained, is invalid for this strategy since the car was tested. If the car is a lemon, Joe should buy the car with guarantee (alternative 2), and if it is a peach, buy the car without guarantee (alternative 1).

### Analyzing the results

```julia
@info("Computing utility distribution.")
@time udist = UtilityDistribution(G, P, U, Z)

@info("Printing utility distribution.")
print_utility_distribution(udist)

@info("Printing expected utility.")
@unpack u, p = udist
@printf("Expected utility: %.1f", sum(u[i]*p[i] for i in 1:length(u)))
```

From the utility distribution, we can see that Joe's profit with this strategy is \$15 with a 20% probability (the car is a lemon) and \$35 with a 80% probability (the car is a peach). The expected profit is thus \$31.


## References
[^1]: Howard, R. A. (1977). The used car buyer. Reading in Decision Analysis, 2nd Ed. Stanford Research Institute, Menlo Park, CA.