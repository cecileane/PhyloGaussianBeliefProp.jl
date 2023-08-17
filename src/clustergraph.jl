@inline function vgraph_eltype(net::HybridNetwork)
    nn = 2max(length(net.node), length(net.edge))
    (nn < typemax(Int8) ? Int8 : (nn < typemax(Int16) ? Int16 : Int))
end
@enum EdgeType etreetype=1 ehybridtype=2 moralizedtype=3 filltype=4

"""
    preprocessnet!(net::HybridNetwork, prefix="I")
"""
function preprocessnet!(net::HybridNetwork, prefix="I")
    PN.preorder!(net)
    PN.nameinternalnodes!(net, prefix)
end

"""
    moralize!(net::HybridNetwork, prefix="I")
    moralize(net)

Undirected graph `g` of type [MetaGraph](https://github.com/JuliaGraphs/MetaGraphsNext.jl)
with the same nodes as in `net`, labelled by their names in `net`, with extra
edges to moralize the graph, that is, to connect any nodes with a common child.
Node data, accessed as `g[:nodelabel]`, is their index in the network's preordering.
Edge data, accessed as `g[:label1, :label2]` is a type to indicate if the edge
was an original tree edge or hybrid edge, or added to moralize the graph.
Another type, not used here, if for fill edges that may need to be added to
triangulate `g` (make it chordal).

The first version modifies `net` to name its internal nodes (used as labels in `g`)
and to create or update its node preordering, then calls the second version.
"""
function moralize!(net::HybridNetwork, prefix="I")
    preprocessnet!(net, prefix)
    moralize(net)
end
@doc (@doc moralize!) moralize
function moralize(net::HybridNetwork)
    T = vgraph_eltype(net)
    mg = MetaGraph(Graph{T}(0), # simple graph
        Symbol,   # label type: Symbol(original node name)
        T,        # vertex data type: store postorder
        EdgeType, # edge data type
        :moralized, # graph data
        edge_data -> one(T),  # weight function
        zero(T))
    # add vertices in preorder, which saves their index to access them in net.
    sym2code = Dict{Symbol,T}()
    for (code,n) in enumerate(net.nodes_changed)
        ns = Symbol(n.name)
        vt = T(code)
        push!(sym2code, ns => vt)
        add_vertex!(mg, ns, vt)
    end
    for e in net.edge
        et = (e.hybrid ? ehybridtype : etreetype)
        add_edge!(mg, Symbol(getparent(e).name), Symbol(getchild(e).name), et)
    end
    # moralize
    for n in net.node
        n.hybrid || continue
        plab = [Symbol(node.name) for node in getparents(n)] # parent labels
        npar = length(plab)
        for (i1,p1) in enumerate(plab), i2 in (i1+1):npar
            p2 = plab[i2]
            has_edge(mg.graph, sym2code[p1], sym2code[p2]) && continue
            add_edge!(mg, p1, p2, moralizedtype)
        end
    end
    return mg
end

#= todo fixit: add function to add more moralizing edges,
for a degenerate hybrid node with a single tree child to be remove from scope:
connect the tree child to all its grandparents
e.g. connect_degeneratehybridparents_treechild
=#

"""
    triangulate_minfill!(graph)

Ordering for node elimination, chosen to greedily minimize the number of fill edges
necessary to eliminate the node (to connect all its neighbors with each other).
Ties are broken by favoring the post-ordering of nodes.
`graph` is modified with these extra fill edges, making it chordal.
"""
function triangulate_minfill!(graph::AbstractGraph{T}) where T
    ordering = typeof(label_for(graph, one(T)))[]
    g2 = deepcopy(graph)
    fe = Tuple{T,T}[] # to reduce memory allocation
    scorefun = v -> (min_fill!(fe,v,g2), - g2[label_for(g2,v)]) # break ties using post-ordering
    while nv(g2) > 1
        i = argmin(scorefun, vertices(g2))
        # add fill edges in both graph and g2, then delete i from g2
        filledges!(fe, T(i), g2)
        for (v1,v2) in fe
            l1 = label_for(g2,v1); l2 = label_for(g2,v2)
            add_edge!(g2,    l1, l2, filltype)
            add_edge!(graph, l1, l2, filltype)
        end
        lab = label_for(g2,i)
        push!(ordering, lab)
        delete!(g2, lab)
    end
    push!(ordering, label_for(g2,one(T)))
    return ordering
end
function min_fill!(fe, vertex_code, graph::AbstractGraph)
    filledges!(fe, vertex_code, graph::AbstractGraph)
    return length(fe)
end
function filledges!(fe, vertex_code, graph::AbstractGraph)
    empty!(fe)
    neighb = inneighbors(graph, vertex_code)
    nn = length(neighb)
    for (i1,n1) in enumerate(neighb), i2 in (i1+1):nn
        n2 = neighb[i2]
        has_edge(graph, n1,n2) || push!(fe, (n1,n2))
    end
    return nothing # nn
end

"""
    minimalclusters!(net)

The *minimal clusters* of a network is its collection of node families. Each
cluster comprises a node and its parent(s). Thus, each cluster either corresponds
to a tree edge (e.g. {child, parent}), or a set of hybrid edges into the same
node (e.g. {child, parent-1, parent-2, ..., parent-k}).

Returns a dictionary that maps each node's preorder index to a vector containing
its preorder index and those of its parents. Within each vector, the preorder
indices are sorted in decreasing order so that the parents' indices come after
the child's.
"""
function minimalclusters!(net::HybridNetwork)
    preprocessnet!(net)
    T = vgraph_eltype(net)
    node2family = Dict{T, Vector{T}}()
    preordernames = [n.name for n in net.nodes_changed]
    for (code, n) in enumerate(net.nodes_changed)
        o = sort!(indexin([p.name for p in getparents(n)], preordernames),
            rev=true)
        node2family[code] = [code; o]
    end
    return node2family
end

"""
    isfamilypreserving!(clusters, net)

`clusters` is *family-preserving* with respect to `net` if each minimal cluster
(see [`minimalclusters!`](@ref)) of `net` is contained in ≥1 cluster in
`clusters`.

Returns a tuple: (isfamilypreserving::Bool, family2cluster::Dict{T, BitVector}),
where `isfamilypreserving` indicates if `clusters` is family-preserving with
respect to `net`, and `family2cluster` is a dictionary that maps each node
family (represented by the preorder index for its child node) to a vector
indicating which clusters in `clusters` contain that node family.
"""
function isfamilypreserving!(clusters::Vector{Vector{T}},
    net::HybridNetwork) where {T <: Integer}
    T1 = vgraph_eltype(net)
    isa(T, Type{T1}) || error("Supply `clusters` as Vector{Vector{$T1}} object")
    node2family = minimalclusters!(net)
    family2cluster = Dict{T, BitVector}()
    isfamilypreserving = true
    for ni in keys(node2family)
        nf = node2family[ni]
        ch = nf[1] # index family by child node
        # mark which clusters (if any) each node family is contained in
        family2cluster[ch] = BitArray(nf ⊆ cl for cl in clusters)
        # check for potential violation only if family-preserving so far
        isfamilypreserving && (isfamilypreserving = any(family2cluster[ch]))
    end
    return (isfamilypreserving, family2cluster)
end

"""
    AbstractClusterGraphMethod

Abstract type for method of cluster graph construction.
"""
abstract type AbstractClusterGraphMethod end

getclusters(obj::AbstractClusterGraphMethod) =
    hasfield(typeof(obj), :clusters) ? obj.clusters : nothing

"""
    Bethe

Bethe cluster graph (also known as factor graph).
"""
struct Bethe <: AbstractClusterGraphMethod end

"""
    LTRIP

*Layered Trees Running Intersection Property* algorithm of Streicher & du Preez
(2017).

## References:

S. Streicher and J. du Preez. Graph Coloring: Comparing Cluster Graphs to Factor
Graphs. In *Proceedings of the ACM Multimedia 2017 Workshop on South African
Academic Participation, pages 35-42, 2017. doi: 10.1145/3132711.3132717.
"""
struct LTRIP <: AbstractClusterGraphMethod
    clusters::Vector{Vector{T}} where T <: Integer
end

function LTRIP(net::HybridNetwork)
    node2family = minimalclusters!(net)
    clusters = collect(values(node2family))
    return LTRIP(clusters)
end
function LTRIP(clusters::Vector{Vector{T}}, net::HybridNetwork) where {T <: Integer}
    # checks if `clusters` is valid wrt to `net`
    isfamilypreserving!(clusters, net)[1] ||
    error("`clusters` is not family preserving with respect to `net`")
    return LTRIP(clusters)
end

"""
    JoinGraphStr

*Join-graph structuring* algorithm of Mateescu et al. (2010).

## References:

R. Mateescu, K. Kask, V.Gogate, and R. Dechter. Join-graph propagation algorithms.
*Journal of Artificial Intelligence Research*, 37:279-328,
2010. doi: 10.1613/jair.2842.
"""
struct JoinGraphStr <: AbstractClusterGraphMethod
    maxclustersize::Integer
end

"""
    Cliquetree

## References:
"""
struct Cliquetree <: AbstractClusterGraphMethod end

"""
    clustergraph!(net, method)

Cluster graph `U` for an input network `net`, a `method` of cluster graph
construction.

The following methods for cluster graph construction are supported:
    - [`Bethe`](@ref)
    - [`LTRIP`](@ref)
    - [`JoinGraphStr`](@ref)
    - [`Cliquetree`](@ref)

Some methods (e.g. LTRIP) require user-supplied clusters, and have constructors
that will check if the clusters provided are *family-preserving*
(see [`isfamilypreserving!`](@ref)) with respect to a given network.
"""
function clustergraph!(net::HybridNetwork, method::AbstractClusterGraphMethod)
    # preprocessing common to all cluster graph methods
    preprocessnet!(net)
    return clustergraph(method, net)
end

function clustergraph(method::Bethe, net::HybridNetwork)
    return betheclustergraph(net, method)
end

function clustergraph(method::LTRIP, net::HybridNetwork)
    return ltripclustergraph(net, method)
end

function clustergraph(method::JoinGraphStr, net::HybridNetwork)
    # fixit: implement
    return
end

function clustergraph(method::Cliquetree, net::HybridNetwork)
    return cliquetree!(net, method)
end

"""
    betheclustergraph(net, _)

Constructs a Bethe cluster graph, which comprises of:
    - a factor-cluster for each node-family (except for the singleton {root}) in
    `net`
    - a variable-cluster for each node in `net`

See [`Bethe`](@ref)
"""
function betheclustergraph(net::HybridNetwork, _)
    T = vgraph_eltype(net)
    clustergraph = init_clustergraph(T, :Bethe)

    node2cluster = Dict{T, Tuple{Symbol, Vector{Symbol}}}() # for joining clusters later
    preordernames = [n.name for n in net.nodes_changed]
    # iterate through network nodes in preorder
    for (code, n) in enumerate(net.nodes_changed)
        ns = Symbol(n.name)
        vt = T(code)
        o = sort!(indexin([p.name for p in getparents(n)], preordernames), rev=true)
        # vdat and nodeindlist are sorted in postorder
        vdat = [ns; [Symbol(n.name) for n in net.nodes_changed[o]]] # node symbols
        nodeindlist = [vt; Vector{T}(o)] # preorder indices
        if length(nodeindlist) > 1 # non-root node of graph
            # cluster data: (node labels, node preorder index), sorted in postorder
            # add factor clusters
            add_vertex!(clustergraph, Symbol(vdat...), (vdat, nodeindlist))
            for ni in nodeindlist
                if haskey(node2cluster, ni)
                    push!(node2cluster[ni][2], Symbol(vdat...))
                else node2cluster[ni] = (Symbol(preordernames[ni]), [Symbol(vdat...)])
                end
            end
        end
    end

    for ni in sort!(collect(keys(node2cluster)), rev=true)
        # sepsets will be sorted by nodes' postorder
        ns, clusterlist = node2cluster[ni]
        if length(clusterlist) > 1
            # add variable cluster only if there are > 1 clusters with this node
            add_vertex!(clustergraph, ns, ([ns], [ni]))
            # connect variable cluster to factor clusters that contain this node
            for lab in clusterlist
                add_edge!(clustergraph, ns, lab, [ni])
            end
        end
    end
    return clustergraph
end

"""
    ltripclustergraph(net, method)

See [`LTRIP`](@ref)
"""
function ltripclustergraph(net::HybridNetwork, method::LTRIP)
    T = vgraph_eltype(net)
    clustergraph = init_clustergraph(T, :ltrip)
    
    # only used for ltrip, so doesn't count as code duplication
    # auxiliary metagraph 
    cg = MetaGraph(Graph{T}(0),
        Symbol, # vertex label
        Tuple{Vector{Symbol}, Vector{T}}, # vertex data: nodes in cluster
        T, # edge data holds edge weight
        :auxiliary, # tag for the whole graph
        edge_data -> edge_data,
        zero(T)) # default weight

    node2cluster = Dict{T, Vector{T}}() # for joining clusters later
    clusters = getclusters(method)
    for (code, nodeindlist) in enumerate(clusters)
        o = sortperm(nodeindlist, rev=true) # order to list nodes in postorder
        nodeindlist .= nodeindlist[o] # preorder indices
        vdat = [Symbol(n.name) for n in net.nodes_changed[nodeindlist]]
        # cluster data: (node labels, node preorder index), sorted in postorder
        add_vertex!(clustergraph, Symbol(vdat...), (vdat, nodeindlist))
        add_vertex!(cg, Symbol(vdat...), (vdat, nodeindlist))
        for ni in nodeindlist
            if haskey(node2cluster, ni)
                push!(node2cluster[ni], T(code))
            else node2cluster[ni] = [T(code)]
            end
        end
    end

     # compute edge weights using auxiliary metagraph
     for ni in sort!(collect(keys(node2cluster)), rev=true)
        # sepsets will be sorted by nodes' postorder
        clusterindlist = node2cluster[ni]
        sg, _ = induced_subgraph(cg, clusterindlist)
        node2edge = Dict{Symbol, Vector{Symbol}}() # for updating edge weights later
        topscoring = Symbol[] # track strongly-connected clusters in `sg`
        topscore = 0 # track top score for cluster "connectivity"
        for (i1, cl1) in enumerate(clusterindlist)
            lab1 = label_for(clustergraph, cl1)
            maxw = 0 # track the max no. of elements `cl1` shares with its neighbors
            for i2 in 1:(i1-1)
                cl2 = clusterindlist[i2]
                lab2 = label_for(clustergraph, cl2)
                w = length(intersect(sg[lab1], sg[lab2]))
                maxw = (w > maxw) ? w : maxw
                add_edge!(sg, lab1, lab2, w)
            end
            # mark clusters that are incident to a max-weight edge
            if maxw > topscore # mark cluster `cl1` and unmark all others
                topscoring, topscore = [lab1], maxw
            elseif maxw == topscore # mark cluster `cl1`
                push!(topscoring, lab1)
            end
        end
        # update edge weights
        for cl in topscoring # topscoring nodes have incident max-weight edges
            neighborlabs = neighbor_labels(sg, cl)
            # count no. of incident max-weight edges and add this no. to weights
            # for all incident edges
            Δw = length([sg[cl, ncl] == topscore for ncl in neighborlabs])
            for ncl in neighborlabs
                sg[cl, ncl] += Δw
            end
        end
        mst_edges = kruskal_mst(sg, minimize=false)

        for e in mst_edges
            lab1 = label_for(sg, src(e))
            lab2 = label_for(sg, dst(e))
            if haskey(clustergraph, lab1, lab2) # if has edge {lab1, lab2}
                clustergraph[lab1, lab2] = push!(clustergraph[lab1, lab2], ni)
            else
                add_edge!(clustergraph, lab1, lab2, [ni])
            end
        end
    end
    return clustergraph
end

"""
    cliquetree!(net, _)

See [`Cliquetree`](@ref)
"""
function cliquetree!(net::HybridNetwork, _)
    g = moralize!(net)
    triangulate_minfill!(g)
    return cliquetree(g)
end

"""
    cliquetree(chordal_graph)

Clique tree `U` for an input graph `g` assumed to be chordal (triangulated),
e.g. using [`triangulate_minfill!`](@ref).  
**Warning**: does *not* check that the graph is already triangulated.

- Each node in `U` is a maximal clique of `g` whose data is the tuple of vectors
  (node_labels, node_data) using the labels and data from `g`, with nodes sorted
  by decreasing data.
  If `g` was originally built from a phylogenetic network using [`moralize`](@ref),
  then the nodes' data are their preorder index, making them sorted in postorder
  within in each clique.
  The clique label is the concatenation of the node labels.
- For each edge (clique1, clique2) in `U`, the edge data hold the sepset
  (separating set) information as a vector of node data, for nodes shared by
  both clique1 and clique2. In this sepset, nodes are sorted by decreasing data.

Uses `maximal_cliques` and `kruskal_mst` (for min/maximum spanning trees) from
[Graphs.jl](https://juliagraphs.org/Graphs.jl/stable/).
"""
function cliquetree(graph::AbstractGraph{T}) where T
    mc = maximal_cliques(graph)
    mg = MetaGraph(Graph{T}(0),
        Symbol, # vertex label
        Tuple{Vector{Symbol},Vector{T}}, # vertex data: nodes in clique
        Vector{T}, # edge data: nodes in sepset
        :cliquetree,
        edge_data -> T(length(edge_data)),
        zero(T))
    node2clique = Dict{T,Vector{T}}() # to connect cliques faster later
    for (code, cl) in enumerate(mc)
        nodeindlist = [graph[label_for(graph,u)] for u in cl] # preorder index
        o = sortperm(nodeindlist, rev=true) # order to list nodes in postorder
        vdat = [label_for(graph,cl[i]) for i in o]
        nodeindlist .= nodeindlist[o]
        # clique data: (node labels, node preorder index), sorted in postorder
        add_vertex!(mg, Symbol(vdat...), (vdat, nodeindlist))
        for ni in nodeindlist
            if haskey(node2clique, ni)
                push!(node2clique[ni], T(code))
            else node2clique[ni] = [T(code)]
            end
        end
    end

    # create edges between pairs of cliques sharing the same node
    for node in sort!(collect(keys(node2clique)), rev=true) # sepsets will be sorted by nodes' postorder
        cliquelist = node2clique[node]
        # add node to the sepset between each pair of cliques that has that node
        for (i1, cl1) in enumerate(cliquelist)
        lab1 = label_for(mg, cl1)
          for i2 in 1:(i1-1)
            cl2 = cliquelist[i2]
            lab2 = label_for(mg, cl2)
            if has_edge(mg, cl1, cl2)
              elabs = MetaGraphsNext.arrange(mg, lab1, lab2)
              haskey(mg.edge_data, elabs) || error("hmm, mg.graph has the edge, but mg has no edge data")
              push!(mg.edge_data[elabs], node)
            else
              add_edge!(mg, lab1, lab2, [node])
            end
          end
        end
    end
    #= altenate way to create edges between cliques
    # would be faster for a complex graph with many nodes but few (large) cliques.
    for cl1 in vertices(mg)
        lab1 = label_for(mg, cl1)
        ni1 = mg[lab1][2] # node indices: preorder index of nodes in the clique
        for cl2 in Base.OneTo(cl1 - one(T))
            lab2 = label_for(mg, cl2)
            ni2 = mg[lab2][2]
            sepset = intersect(ni1, ni2) # would be nice to take advantage of the fact that ni1 and ni2 are both sorted (descending)
            isempty(sepset) && continue
            add_edge!(mg, lab1, lab2, sepset)
        end
    end =#

    # find maximum spanning tree: with maximum sepset sizes
    mst_edges = kruskal_mst(mg, minimize=false)
    # delete the other edges to get the clique tree
    # complication: edge iterator is invalidated by the first edge deletion
    todelete = setdiff!(collect(edges(mg)), mst_edges)
    for e in todelete
        rem_edge!(mg, src(e), dst(e))
    end
    return mg
end

"""
    init_clustergraph(vertex_type, clustergraph_method)

Construct empty `MetaGraph` based on an empty `Graph`. Metadata types are
initialized as follows:
    - `label_type::Symbol`
    - `vertex_data_type::Tuple{Vector{Symbol}, Vector{T}}`
    - `edge_data_type::Vector{T}`
Metadata for `Graph` as a whole is `method::Symbol`.

Note: const Graph = Graphs.SimpleGraphs.SimpleGraph
Note: SimpleGraph{T}(n=0) constructs an empty SimpleGraph{T} with n vertices and
0 edges. If not specified, the element type `T` is the type of `n`.
"""
function init_clustergraph(T::Type{<:Integer}, method::Symbol)
    clustergraph = MetaGraph(
        Graph{T}(0),
        Symbol, # vertex label
        Tuple{Vector{Symbol}, Vector{T}}, # vertex data: nodes in cluster
        Vector{T}, # edge data: nodes in sepset
        method, # tag for the whole graph
        edge_data -> T(length(edge_data)),
        zero(T)) # default weight
    return clustergraph
end

"""
    spanningtree_clusterlist(clustergraph, root_index)
    spanningtree_clusterlist(clustergraph, nodevector_preordered)

Build the depth-first search spanning tree of the cluster graph, starting from
the node indexed `root_index` in the underlying simple graph;
find the associated topological ordering of the clusters (preorder); then
return a tuple of these four vectors:
1. `parent_labels`: labels of the parents' child clusters. The first one is the root.
2. `child_labels`: labels of clusters in pre-order, except for the cluster
    choosen to be the root.
3. `parent_indices`: indices of the parent clusters
4. `child_indices`: indices of the child clusters, listed in preorder as before.

In the second version in which `root_index` is not provided, the root of the
spanning tree is chosen to be a cluster that contains the network's root. If
multiple clusters contain the network's root, then one is chosen containing the
smallest number of taxa: see [`default_rootcluster`](@ref).
"""
function spanningtree_clusterlist(cgraph::MetaGraph, prenodes::Vector{PN.Node})
    rootj = default_rootcluster(cgraph, prenodes)
    spanningtree_clusterlist(cgraph, rootj)
end
function spanningtree_clusterlist(cgraph::MetaGraph, rootj::Integer)
    par = dfs_parents(cgraph.graph, rootj)
    spt = Graphs.tree(par) # or directly: spt = dfs_tree(cgraph.graph, rootj)
    # spt.fadjlist # forward adjacency list: sepsets, but edges not indexed
    childclust_j = topological_sort(spt)[2:end] # cluster in preorder, excluding the root cluster
    parentclust_j = par[childclust_j] # parent of each cluster in spanning tree
    childclust_lab  = [cgraph.vertex_labels[j] for j in childclust_j]
    parentclust_lab = [cgraph.vertex_labels[j] for j in parentclust_j]
    return parentclust_lab, childclust_lab, parentclust_j, childclust_j
end

"""
    default_rootcluster(clustergraph, nodevector_preordered)

Index of a cluster that contains the network's root, whose label is assumed to
be `1` (preorder index). If multiple clusters contain the network's root,
then one is chosen with the smallest number of taxa (leaves in the network).

For cluster with label `:lab`, its property `clustergraph[:lab][2]`
should list the nodes in the cluster, by the index of each node in
`nodevector_preordered` such that `1` corresponds to the network's root.
Typically, this vector is `net.nodes_changed` after the network is preordered.
"""
function default_rootcluster(cgraph::MetaGraph, prenodes::Vector{PN.Node})
    hasroot = lab -> begin   # Inf if the cluster does not contain the root 1
        nodelabs = cgraph[lab][2]  # number of taxa in the cluster otherwise
        (1 ∈ nodelabs ? sum(prenodes[i].leaf for i in nodelabs) : Inf)
    end
    rootj = argmin(hasroot(lab) for lab in labels(cgraph))
    return rootj
end
