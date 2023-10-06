abstract type AbstractResidual end

#= fixit: have a simple function that goes through and checks with different
tolerance values. `missing`s would indicate that a message has not been passed. =#
struct MessageResidual{T<:Real,P<:AbstractMatrix{T},V<:AbstractVector{T}} <: AbstractResidual
    Δh::V
    ΔJ::P
    # fixit: compute a norm from Δh and ΔJ, to store in `resid`?
    # resid::MVector{1,T}
    kldiv::Vector{Union{Missing,T}}
    iscalibrated_resid::MVector{1,Bool}
    iscalibrated_kl::MVector{1,Bool}
end

function MessageResidual(ΔJ::AbstractMatrix{T},
        Δh::AbstractVector{T}, _) where {T <: Real}
    MessageResidual(Δh, ΔJ, Union{Missing,T}[missing], MVector(false), MVector(false))
end

"""
    ClusterGraphBelief(belief_vector)

Structure to hold a vector of beliefs, with cluster beliefs coming first and
sepset beliefs coming last. Fields:
- `belief`: vector of beliefs
- `factor`: vector of initial cluster beliefs after factor assignment
- `nclusters`: number of clusters
- `cdict`: dictionary to get the index of a cluster belief from its node labels
- `sdict`: dictionary to get the index of a sepset belief from the labels of
   its two incident clusters.
- `messageresidual`: dictionary to log residual information from messages. For
example, this information can be used to track if a sending cluster and a
receiving sepset had calibrated beliefs (within some tolerance) at the last
instance of that message.

Assumptions:
- For a cluster belief, the cluster's nodes are stored in the belief's `metadata`.
- For a sepset belief, its incident clusters' nodes are in the belief's metadata.
"""
struct ClusterGraphBelief{T<:AbstractBelief}
    "vector of beliefs, cluster beliefs first and sepset beliefs last"
    belief::Vector{T}
    "vector of factors from the graphical model, used to initialize cluster beliefs"
    factors::Vector{T} # fixit: review
    "number of clusters"
    nclusters::Int
    "dictionary: cluster label => cluster index"
    cdict::Dict{Symbol,Int}
    "dictionary: cluster neighbor labels => sepset index"
    sdict::Dict{Set{Symbol},Int}
    "dictionary: message labels (cluster_to, cluster_from) => residual information"
    messageresidual::Dict{Tuple{Symbol,Symbol},Union{Missing,AbstractResidual}}
end
nbeliefs(obj::ClusterGraphBelief)  = length(obj.belief)
nclusters(obj::ClusterGraphBelief) = obj.nclusters
nsepsets(obj::ClusterGraphBelief)  = nbeliefs(obj) - nclusters(obj)
function Base.show(io::IO, b::ClusterGraphBelief)
    disp = "beliefs for $(nclusters(b)) clusters and $(nsepsets(b)) sepsets.\nclusters:\n"
    for (k,v) in b.cdict disp *= "  $(rpad(k,10)) => $v\n";end
    disp *= "sepsets:\n"
    for (k,v) in b.sdict disp *= "  $(rpad(join(k,", "),20)) => $v\n";end
    print(io, disp)
end

clusterindex(c, obj::ClusterGraphBelief) = clusterindex(c, obj.cdict)
function clusterindex(clusterlabel, clusterdict)
    clusterdict[clusterlabel]
end
sepsetindex(c1, c2, obj::ClusterGraphBelief) = sepsetindex(c1, c2, obj.sdict)
function sepsetindex(clustlabel1, clustlabel2, sepsetdict)
    sepsetdict[Set((clustlabel1, clustlabel2))]
end

# fixit: review. Assumes that `beliefs` modified by `init_beliefs_assignfactors!`
function ClusterGraphBelief(beliefs)
    i = findfirst(b -> b.type == bsepsettype, beliefs)
    nc = (isnothing(i) ? length(beliefs) : i-1)
    all(beliefs[i].type == bclustertype for i in 1:nc) ||
        error("clusters are not consecutive")
    all(beliefs[i].type == bsepsettype for i in (nc+1):length(beliefs)) ||
        error("sepsets are not consecutive")
    cdict = get_clusterindexdictionary(beliefs, nc)
    sdict = get_sepsetindexdictionary(beliefs, nc)
    messageresidual = init_messageresidual(beliefs, nc)
    factors = deepcopy(beliefs[1:nc])
    return ClusterGraphBelief{eltype(beliefs)}(beliefs,factors,nc,cdict,sdict,
        messageresidual)
end
function get_clusterindexdictionary(beliefs, nclusters)
    Dict(beliefs[j].metadata => j for j in 1:nclusters)
end
function get_sepsetindexdictionary(beliefs, nclusters)
    Dict(Set(beliefs[j].metadata) => j for j in (nclusters+1):length(beliefs))
end
function init_messageresidual(beliefs, nclusters)
    messageresidual = Dict{Tuple{Symbol,Symbol},Union{Missing,AbstractResidual}}()
    for j in (nclusters+1):length(beliefs)
        (clustlab1, clustlab2) = beliefs[j].metadata
        messageresidual[(clustlab1, clustlab2)] = missing
        messageresidual[(clustlab2, clustlab1)] = missing
    end
    return messageresidual
end

"""
    init_beliefs_reset!(beliefs::ClusterGraphBelief)

Reset cluster beliefs to factors, which can be re-initialized with different
model parameters, and sepset beliefs to h=0, J=0, g=0.
"""
function init_beliefs_reset!(beliefs::ClusterGraphBelief)
    nc, nb = nclusters(beliefs), length(beliefs)
    b, f = beliefs.belief, beliefs.factors
    for i in 1:nc
        b[i].h   .= f[i].h
        b[i].J   .= f[i].J
        b[i].g[1] = f[i].g[1]
    end
    for i in (nc+1):nb
        b[i].h   .= 0.0
        b[i].J   .= 0.0
        b[i].g[1] = 0.0
    end
end

"""
    integratebelief!(obj, beliefindex)
    integratebelief!(obj)
    integratebelief!(obj::ClusterGraphBelief, clustergraph, nodevector_preordered)

(μ,g) from fully integrating the object belief indexed `beliefindex`.
The second form uses the first sepset containing a single node. This is valid
if the beliefs are fully calibrated (including a pre-order traversal), but
invalid otherwise.
The third form uses the default cluster containing the root,
see [`default_rootcluster`](@ref). This is valid if the same cluster was used
as the root of the cluster graph, if this graph is a clique tree, and after
a post-order traversal to start the calibration.
"""
function integratebelief!(obj::ClusterGraphBelief, cgraph::MetaGraph, prenodes)
    integratebelief!(obj, default_rootcluster(cgraph, prenodes))
end
integratebelief!(b::ClusterGraphBelief) = integratebelief!(b, default_sepset1(b))
integratebelief!(b::ClusterGraphBelief, j::Integer) = integratebelief!(b.belief[j])

# first sepset containing a single node
default_sepset1(b::ClusterGraphBelief) = default_sepset1(b.belief, nclusters(b)+1)
function default_sepset1(beliefs::AbstractVector, n::Integer)
    j = findnext(b -> length(nodelabels(b)) == 1, beliefs, n)
    isnothing(j) && error("no sepset with a single node") # should not occur: degree-1 taxa
    return j
end

"""
    mod_beliefs_bethe!(beliefs::ClusterGraphBelief, traitdimension,
        net, ridgeconstant::Float=1.0)

Modify naively initialized beliefs (see [`init_beliefs_assignfactors!`](@ref))
of a Bethe cluster graph so that:
1. messages sent/received between neighbor clusters are well-defined, and
2. messages sent from a hybrid cluster are non-degenerate.

For each hybrid cluster belief, add `ridgeconstant` to the diagonal elements of 
its precision matrix that correspond to the parent nodes in the cluster, so that
the affected principal submatrix is stably invertible (the first `traitdimension`
rows/columns of the precision matrix correspond to the hybrid node).
For the edge beliefs associated with the parent nodes in a hybrid cluster, add
`ridgeconstant` to the diagonal elements of its precision matrix so as to
preserve the cluster graph invariant (i.e. the product of cluster beliefs
divided by the product of edge beliefs is invariant throughout belief
propagation).

Send a message along each affected edge from hybrid cluster to variable cluster,
so that all subsequent messages received by these hybrid clusters are valid
Gaussians (i.e. with positive semi-definite variance/precision).
"""
function mod_beliefs_bethe!(beliefs::ClusterGraphBelief,
    numt::Integer, net::HybridNetwork, ϵ::Float64=1.0)
    # fixit: to remove? Redundant if we can send default messages on the fly
    # fixit: set ϵ adaptively
    prenodes = net.nodes_changed
    b = beliefs.belief
    # modify beliefs of hybrid clusters and their incident sepsets
    for n in net.hybrid
        o = sort!(indexin(getparents(n), prenodes), rev=true)
        parentnames = [pn.name for pn in prenodes[o]]
        clustlabel = Symbol(n.name, parentnames...)
        cbi = clusterindex(clustlabel, beliefs) # cluster belief index
        sb_idx = [sepsetindex(clustlabel, clustlabel2, beliefs) for clustlabel2
            in Symbol.(parentnames)] # sepset belief indices for parent nodes
        #= Add ϵ to diagonal entries of principal submatrix (for parent nodes)
        of cluster belief precision. The first `numt` coordinates are for the
        hybrid node. =#
        b[cbi].J[(numt+1):end, (numt+1):end] .+= ϵ*LA.I(length(sb_idx)*numt)
        for (i, sbi) in enumerate(sb_idx)
            #= Add ϵ to diagonal entries of sepset belief precision to preserve
            the cluster graph invariant. =#
            b[sbi].J .+= ϵ*LA.I(numt)
            #= Send non-degenerate message from hybrid cluster to neighbor
            variable clusters for each parent node. =#
            propagate_belief!(b[clusterindex(Symbol(parentnames[i]), beliefs)],
                b[sbi], b[cbi])
        end
    end
end

"""
    calibrate!(beliefs::ClusterGraphBelief, schedule, niterations=1, auto=false)

Propagate messages for each tree in the `schedule` list, in postorder then in
preorder, and repeat this for `niterations`. `true` **only if** `beliefs` are
calibrated after all messages have been propagated, `false` otherwise (i.e.
`beliefs` may be calibrated even if `false`, more explanation below).
Each schedule "tree" should be a tuple of 4 vectors as output by
[`spanningtree_clusterlist`](@ref), where each vector provides the parent/child
label/index of an edge along which to pass a message, and where these edges are
listed in preorder. For example, the parent of the first edge is taken to be the
root of the schedule tree.

Calibration is flagged if, after a schedule "tree" is executed, it is found that
each possible message sent in the cluster graph was last equal to its moderating
sepset belief (within some tolerance).
This condition is sufficient but not necessary for calibration (e.g. the default
of 1 iteration is sufficient for exact calibration if the schedule tree is a
clique tree for the graphical model, however calibration will not be flagged).
If `auto` is true, then return `true` whenever calibration is flagged before
`niterations` have been completed.

See also: [`iscalibrated_canon`](@ref)
"""
function calibrate!(beliefs::ClusterGraphBelief, schedule::AbstractVector,
    niter::Integer=1, auto::Bool=false)
    # fixit: input checks?
    i = 0
    while i < niter
        # spt = spanningtree_clusterlist(cgraph, prenodes)
        i += 1
        for (j, spt) in enumerate(schedule)
            if calibrate!(beliefs, spt) && auto
                # stop automatically once calibration is detected
                # fixit: print more info when calibration is detected early?
                println("Calibrated after: iter $i, sch $j")
                return true
            end
        end
    end
    # fixit: check calibration properly at the end?
    return false
end
function calibrate!(beliefs::ClusterGraphBelief, spt::Tuple)
    propagate_1traversal_postorder!(beliefs, spt...)
    propagate_1traversal_preorder!(beliefs, spt...)
    return iscalibrated_canon(beliefs)
end

"""
    iscalibrated(beliefs::ClusterGraphBelief, edge_labels, rtol::Float64=1e-2)
    iscalibrated(residual::Tuple, atol::Float64=1e-5)

`true` if each edge belief is *marginally consistent* with the beliefs of the
pair of clusters that it spans (i.e. their marginal means and variances are
approximately equal with relative tolerance `rtol`), `false` otherwise.

Mean vectors are compared by their 2-norm and variance matrices are compared by
the Frobenius norm.

The second form checks if the residual (in terms of canonical parameters: h, J)
between a new message from a cluster through an edge, and the current edge
belief is within `atol` of 0, elementwise.
"""
function iscalibrated(beliefs::ClusterGraphBelief,
        edgelabs::Vector{Tuple{Symbol, Symbol}}, rtol=1e-2)
    # fixit: discuss tolerance for comparison
    #= fixit: this will probably be moved to `test_calibration.jl` since it is
    an inefficient way to check if the cluster graph is calibrated on the fly. =#
    b = beliefs.belief
    belief2meanvar = Dict{Symbol, Tuple{AbstractVector, AbstractMatrix}}()
    for (clustlab1, clustlab2) in edgelabs
        clust1 = b[clusterindex(clustlab1, beliefs)]
        clust2 = b[clusterindex(clustlab2, beliefs)]
        if haskey(belief2meanvar, clustlab1)
            clustmean1, clustvar1 = belief2meanvar[clustlab1]
        else
            clustmean1, clustvar1 = integratebelief!(clust1)[1], clust1.J \ LA.I
            belief2meanvar[clustlab1] = (clustmean1, clustvar1)
        end
        if haskey(belief2meanvar, clustlab2)
            clustmean2, clustvar2 = belief2meanvar[clustlab2]
        else
            clustmean2, clustvar2 = integratebelief!(clust2)[1], clust2.J \ LA.I
            belief2meanvar[clustlab2] = (clustmean2, clustvar2)
        end
        sepset = b[sepsetindex(clustlab1, clustlab2, beliefs)]
        sepsetmean, sepsetvar = integratebelief!(sepset)[1], sepset.J \ LA.I
        ind1 = scopeindex(sepset, clust1) # indices to be compared
        sepsetmean .== clustmean1[ind1]
        sepsetvar .== clustvar1[ind1, ind1]
        ind2 = scopeindex(sepset, clust2)
        sepsetmean .== clustmean2[ind2]
        sepsetvar .== clustvar2[ind2, ind2]
        # check the agreement between cluster and sepset beliefs
        isapprox(sepsetmean, clustmean1[ind1], rtol=rtol) &&
        isapprox(sepsetmean, clustmean2[ind2], rtol=rtol) &&
        isapprox(sepsetvar, clustvar1[ind1, ind1], rtol=rtol) &&
        isapprox(sepsetvar, clustvar2[ind2, ind2], rtol=rtol) || return false
    end
    return true
end

"""
    iscalibrated_canonical(beliefs::ClusterGraphBelief)
    iscalibrated_kl(beliefs::ClusterGraphBelief)

True if for each possible message that can be sent in the cluster graph, its
most recent residual (in terms of canonical parameters: h, J) with the receiving
sepset's belief is zero (within some tolerance). False otherwise. This condition
is sufficient but not necessary for calibration.

See also: [`iscalibrated(residual, atol)`](@ref)
"""
function iscalibrated_canon(beliefs::ClusterGraphBelief)
    # fixit: review
    all(x -> !ismissing(x) && x.iscalibrated_resid[1],
        values(beliefs.messageresidual))
end

"""
    iscalibrated_kl(beliefs::ClusterGraphBelief)

True if for each possible message that can be sent in the cluster graph, its
most recent KL divergence with the receiving sepset's belief is zero (within
some tolerance). False otherwise. This condition is sufficient but not
necessary for calibration.
"""
function iscalibrated_KL(beliefs::ClusterGraphBelief)
    # fixit: review
    all(x -> !ismissing(x) && x.iscalibrated_kl[1],
        values(beliefs.messageresidual))
end

"""
    iscalibrated_canon!(res::AbstractResidual, atol=1e-5)

True if the canonical parameters of the message residual (`res.Δh` and `res.ΔJ`)
are within `atol` of 0, elementwise. False otherwise.
"""
function iscalibrated_canon!(res::AbstractResidual, atol=1e-5)
    # fixit: review
    res.iscalibrated_resid[1] = all(isapprox.(res.Δh, 0.0, atol=atol)) &&
        all(isapprox.(res.ΔJ, 0, atol=atol))
end

"""
    iscalibrated_kl!(res::AbstractResidual, atol=1e-5)

True if the KL divergence between the message (whose most recent residual
information is stored in `res`) received by a sepset and its belief prior to
receiving that message is within `atol` of 0. False otherwise.
"""
function iscalibrated_kl!(res::AbstractResidual, atol=1e-5)
    # fixit: review
    res.iscalibrated_kl[1] = isapprox(res.kldiv[1], 0.0, atol=atol)
end

"""
    propagate_1traversal_postorder!(beliefs::ClusterGraphBelief, spanningtree...)
    propagate_1traversal_preorder!(beliefs::ClusterGraphBelief,  spanningtree...)

Messages are propagated from the tips to the root of the tree by default,
or from the root to the tips if `postorder` is false.

The "spanning tree" should be a tuple of 4 vectors as output by
[`spanningtree_clusterlist`](@ref), meant to list edges in preorder.
Its nodes (resp. edges) should correspond to clusters (resp. sepsets) in
`beliefs`: labels and indices in the spanning tree information
should correspond to indices in `beliefs`.
This condition holds if beliefs are produced on a given cluster graph and if the
tree is produced by [`spanningtree_clusterlist`](@ref) on the same graph.
"""
function propagate_1traversal_postorder!(beliefs::ClusterGraphBelief,
            pa_lab, ch_lab, pa_j, ch_j)
    b = beliefs.belief
    mr = beliefs.messageresidual
    # (parent <- sepset <- child) in postorder
    for i in reverse(1:length(pa_lab))
        ss_j = sepsetindex(pa_lab[i], ch_lab[i], beliefs)
        sepset, residual = propagate_belief!(b[pa_j[i]], b[ss_j], b[ch_j[i]])
        if !ismissing(mr[(pa_lab[i], ch_lab[i])])
            mr[(pa_lab[i], ch_lab[i])].ΔJ .= residual[1]
            mr[(pa_lab[i], ch_lab[i])].Δh .= residual[2]
            iscalibrated_canon!(mr[(pa_lab[i], ch_lab[i])])
        else
            mr[(pa_lab[i], ch_lab[i])] = MessageResidual(residual...)
        end
        # KL div. between message received by sepset and its previous belief
        # !!note: `isposdef` returns true for size (0,0) MMatrices and the [0.0] MMatrix
        if LA.isposdef(sepset.J) && size(sepset.J)[1] > 0 && (size(sepset.J)[1] > 1 || sepset.J[1] > 0)
            # fixit: debug
            mr[(pa_lab[i], ch_lab[i])].kldiv[1] = -average_energy(sepset, residual)
            iscalibrated_kl!(mr[(pa_lab[i], ch_lab[i])])
        end
    end
end

function propagate_1traversal_preorder!(beliefs::ClusterGraphBelief,
            pa_lab, ch_lab, pa_j, ch_j)
    b = beliefs.belief
    mr = beliefs.messageresidual
    # (child <- sepset <- parent) in preorder
    for i in 1:length(pa_lab)
        ss_j = sepsetindex(pa_lab[i], ch_lab[i], beliefs)
        sepset, residual = propagate_belief!(b[ch_j[i]], b[ss_j], b[pa_j[i]])
        if !ismissing(mr[(ch_lab[i], pa_lab[i])])
            mr[(ch_lab[i], pa_lab[i])].ΔJ .= residual[1]
            mr[(ch_lab[i], pa_lab[i])].Δh .= residual[2]
            iscalibrated_canon!(mr[(ch_lab[i], pa_lab[i])])
        else
            mr[(ch_lab[i], pa_lab[i])] = MessageResidual(residual...)
        end
        # !!note: `isposdef` returns true for size (0,0) MMatrices and the [0.0] MMatrix
        if LA.isposdef(sepset.J) && size(sepset.J)[1] > 0 && (size(sepset.J)[1] > 1 || sepset.J[1] > 0)
            #= fixit: introduce a second method for `average_energy` that ignores
            the `g` parameter of the target distribution (here, the sepset belief).
            This second method should replace the first one here. =#
            mr[(ch_lab[i], pa_lab[i])].kldiv[1] = -average_energy(sepset, residual)
            iscalibrated_kl!(mr[(ch_lab[i], pa_lab[i])])
        end
    end
end

#------ parameter optimization. fixit: place in some other file? ------#
"""
    calibrate_optimize_cliquetree!(beliefs::ClusterGraphBelief, clustergraph,
        nodevector_preordered, tbl::Tables.ColumnTable, taxa::AbstractVector,
        evolutionarymodel_name, evolutionarymodel_startingparameters)

Optimize model parameters using belief propagation along `clustergraph`,
assumed to be a clique tree for the input network, whose nodes in preorder are
`nodevector_preordered`. Optimization aims to maximize the likelihood
of the data in `tbl` at leaves in the network. The taxon names in `taxa`
should appear in the same order as they come in `tbl`.
The parameters being optimized are the variance rate(s) and prior mean(s)
at the root. The prior variance at the root is fixed.

The calibration does a postorder of the clique tree only, to get the likelihood
at the root *without* the conditional distribution at all nodes, modifying
`beliefs` in place. Therefore, if the distribution of ancestral states is sought,
an extra preorder calibration would be required.
Warning: there is *no* check that the cluster graph is in fact a clique tree.
"""
function calibrate_optimize_cliquetree!(beliefs::ClusterGraphBelief,
        cgraph, prenodes::Vector{PN.Node},
        tbl::Tables.ColumnTable, taxa::AbstractVector,
        evomodelfun, # constructor function
        evomodelparams)
    spt = spanningtree_clusterlist(cgraph, prenodes)
    rootj = spt[3][1] # spt[3] = indices of parents. parent 1 = root
    mod = evomodelfun(evomodelparams...) # model with starting values
    function score(θ) # θ: unconstrained parameters, e.g. log(σ2)
        model = evomodelfun(params_original(mod, θ)...)
        init_beliefs_reset!(beliefs.belief)
        init_beliefs_assignfactors!(beliefs.belief, model, tbl, taxa, prenodes)
        propagate_1traversal_postorder!(beliefs, spt...)
        _, res = integratebelief!(beliefs, rootj) # drop conditional mean
        return -res # score to be minimized (not maximized)
    end
    # autodiff does not currently work with ForwardDiff, ReverseDiff of Zygote,
    # because they cannot differentiate array mutation, as in: view(be.h, factorind) .+= h
    opt = Optim.optimize(score, params_optimize(mod), Optim.LBFGS())
    # fixit: if BM and fixed root, avoid optimization bc there exists an exact alternative
    loglikscore = - Optim.minimum(opt)
    bestθ = Optim.minimizer(opt)
    bestmodel = evomodelfun(params_original(mod, bestθ)...)
    return bestmodel, loglikscore, opt
end