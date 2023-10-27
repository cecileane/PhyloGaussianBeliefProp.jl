"""
    ClusterGraphBelief{B<:Belief}
    ClusterGraphBelief(belief_vector::Vector{B})

Structure to hold a vector of beliefs, with cluster beliefs coming first and
sepset beliefs coming last. Fields:
- `belief`: vector of beliefs
- `factor`: vector of initial cluster beliefs after factor assignment
- `nclusters`: number of clusters
- `cdict`: dictionary to get the index of a cluster belief from its node labels
- `sdict`: dictionary to get the index of a sepset belief from the labels of
   its two incident clusters.
- `messageresidual`: dictionary to log information about sepset messages,
  which can be used to track calibration or help adaptive scheduling with
  residual BP. See [`MessageResidual`](@ref).
  The keys of `messageresidual` are tuples of cluster labels, similarly to a
  sepset's metadata. Each edge in the cluster graph has 2 messages corresponding
  to the 2 directions in which a message can be passed, with keys:
  `(label1, label2)` and `(label2, label1)`.
  The cluster receiving the message is the first label in the tuple,
  and the sending cluster is the second.

Assumptions:
- For a cluster belief, the cluster's nodes are stored in the belief's `metadata`.
- For a sepset belief, its incident clusters' nodes are in the belief's metadata.
"""
struct ClusterGraphBelief{B<:Belief, M<:MessageResidual}
    "vector of beliefs, cluster beliefs first and sepset beliefs last"
    belief::Vector{B}
    "vector of factors from the graphical model, used to initialize cluster beliefs"
    factors::Vector{B} # fixit: review
    "number of clusters"
    nclusters::Int
    "dictionary: cluster label => cluster index"
    cdict::Dict{Symbol,Int}
    "dictionary: cluster neighbor labels => sepset index"
    sdict::Dict{Set{Symbol},Int}
    "dictionary: message labels (cluster_to, cluster_from) => residual information"
    messageresidual::Dict{Tuple{Symbol,Symbol}, M}
end
nbeliefs(obj::ClusterGraphBelief) = length(obj.belief)
nclusters(obj::ClusterGraphBelief) = obj.nclusters
nsepsets(obj::ClusterGraphBelief) = nbeliefs(obj) - nclusters(obj)
function Base.show(io::IO, b::ClusterGraphBelief)
    disp = "beliefs for $(nclusters(b)) clusters and $(nsepsets(b)) sepsets.\nclusters:\n"
    for (k, v) in b.cdict
        disp *= "  $(rpad(k,10)) => $v\n"
    end
    disp *= "sepsets:\n"
    for (k, v) in b.sdict
        disp *= "  $(rpad(join(k,", "),20)) => $v\n"
    end
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
function ClusterGraphBelief(beliefs::Vector{B}) where B<:Belief
    i = findfirst(b -> b.type == bsepsettype, beliefs)
    nc = (isnothing(i) ? length(beliefs) : i - 1)
    all(beliefs[i].type == bclustertype for i in 1:nc) ||
        error("clusters are not consecutive")
    all(beliefs[i].type == bsepsettype for i in (nc+1):length(beliefs)) ||
        error("sepsets are not consecutive")
    cdict = get_clusterindexdictionary(beliefs, nc)
    sdict = get_sepsetindexdictionary(beliefs, nc)
    mr = init_messageresidual(beliefs, nc)
    factors = [deepcopy(beliefs[i]) for i in 1:nc] # beliefs[1:nc] makes a copy, but not deep
    return ClusterGraphBelief{B,eltype(mr)}(beliefs,factors,nc,cdict,sdict,mr)
end
function get_clusterindexdictionary(beliefs, nclusters)
    Dict(beliefs[j].metadata => j for j in 1:nclusters)
end
function get_sepsetindexdictionary(beliefs, nclusters)
    Dict(Set(beliefs[j].metadata) => j for j in (nclusters+1):length(beliefs))
end
function init_messageresidual(
        beliefs::Vector{B},
        nclusters) where B<:Belief{V,T} where {V<:AbstractVector, T<:Real}
    messageresidual = Dict{Tuple{Symbol,Symbol}, Vector{MessageResidual{T}}}()
    for j in (nclusters+1):length(beliefs)
        ssbe = beliefs[j] # sepset belief
        (clustlab1, clustlab2) = ssbe.metadata
        messageresidual[(clustlab1, clustlab2)] = MessageResidual(ssbe.J, ssbe.h)
        messageresidual[(clustlab2, clustlab1)] = MessageResidual(ssbe.J, ssbe.h)
    end
    return messageresidual
end

"""
    init_beliefs_reset!(beliefs::ClusterGraphBelief)

Reset cluster beliefs to factors and sepset beliefs to h=0, J=0, g=0.
"""
function init_beliefs_reset!(beliefs::ClusterGraphBelief)
    # fixit: change name of method?
    nc, nb = nclusters(beliefs), length(beliefs.belief)
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
    factors_reset!(beliefs::ClusterGraphBelief)

Reset factors to initial cluster beliefs for a different instantiation of model
parameters (i.e. after [`init_beliefs_reset!`](@ref) and
[`init_beliefs_assignfactors!`](@ref) are run for different parameter values).
"""
function factors_reset!(beliefs::ClusterGraphBelief)
    b, f = beliefs.belief, beliefs.factors
    for i in 1:nclusters(beliefs)
        f[i].h   .= b[i].h
        f[i].J   .= b[i].J
        f[i].g[1] = b[i].g[1]
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
default_sepset1(b::ClusterGraphBelief) = default_sepset1(b.belief, nclusters(b) + 1)
function default_sepset1(beliefs::AbstractVector, n::Integer)
    j = findnext(b -> length(nodelabels(b)) == 1, beliefs, n)
    isnothing(j) && error("no sepset with a single node") # should not occur: degree-1 taxa
    return j
end

# """
#     mod_beliefs_bethe!(beliefs::ClusterGraphBelief, traitdimension,
#         net, ridgeconstant::Float=1.0)

# Modify naively initialized beliefs (see [`init_beliefs_assignfactors!`](@ref))
# of a Bethe cluster graph so that:
# 1. messages sent/received between neighbor clusters are well-defined, and
# 2. messages sent from a hybrid cluster are non-degenerate.

# For each hybrid cluster belief, add `ridgeconstant` to the diagonal elements of 
# its precision matrix that correspond to the parent nodes in the cluster, so that
# the affected principal submatrix is stably invertible (the first `traitdimension`
# rows/columns of the precision matrix correspond to the hybrid node).
# For the edge beliefs associated with the parent nodes in a hybrid cluster, add
# `ridgeconstant` to the diagonal elements of its precision matrix so as to
# preserve the cluster graph invariant (i.e. the product of cluster beliefs
# divided by the product of edge beliefs is invariant throughout belief
# propagation).

# Send a message along each affected edge from hybrid cluster to variable cluster,
# so that all subsequent messages received by these hybrid clusters are valid
# Gaussians (i.e. with positive semi-definite variance/precision).
# """
# function mod_beliefs_bethe!(beliefs::ClusterGraphBelief,
#     numt::Integer, net::HybridNetwork, ϵ::Float64=1.0)
#     # fixit: to remove? Redundant if we can send default messages on the fly
#     # fixit: set ϵ adaptively
#     prenodes = net.nodes_changed
#     b = beliefs.belief
#     # modify beliefs of hybrid clusters and their incident sepsets
#     for n in net.hybrid
#         o = sort!(indexin(getparents(n), prenodes), rev=true)
#         parentnames = [pn.name for pn in prenodes[o]]
#         clustlabel = Symbol(n.name, parentnames...)
#         cbi = clusterindex(clustlabel, beliefs) # cluster belief index
#         sb_idx = [sepsetindex(clustlabel, clustlabel2, beliefs) for clustlabel2
#             in Symbol.(parentnames)] # sepset belief indices for parent nodes
#         #= Add ϵ to diagonal entries of principal submatrix (for parent nodes)
#         of cluster belief precision. The first `numt` coordinates are for the
#         hybrid node. =#
#         b[cbi].J[(numt+1):end, (numt+1):end] .+= ϵ*LA.I(length(sb_idx)*numt)
#         for (i, sbi) in enumerate(sb_idx)
#             #= Add ϵ to diagonal entries of sepset belief precision to preserve
#             the cluster graph invariant. =#
#             b[sbi].J .+= ϵ*LA.I(numt)
#             #= Send non-degenerate message from hybrid cluster to neighbor
#             variable clusters for each parent node. =#
#             propagate_belief!(b[clusterindex(Symbol(parentnames[i]), beliefs)],
#                 b[sbi], b[cbi])
#         end
#     end
# end

"""
    init_messages!(beliefs::ClusterGraphBelief, clustergraph)

Modify naively assigned beliefs (see [`init_beliefs_assignfactors!`](@ref)) of a
cluster graph (while preserving the cluster graph invariant) so that all cluster
beliefs are non-degenerate, and for any subsequent schedule of messages:

        (1) cluster/sepset beliefs stay non-degenerate (i.e. positive definite)
        (2) all received messages are well-defined (i.e. positive semi-definite)

## Algorithm
1. All clusters are considered unprocessed and no messages have been sent.
2. Pick an arbitary unprocessed cluster and let it receive default messages from
all neighbor clusters that have not sent it a message.
3. Compute and send a message from this cluster to any neighbor cluster that has
not received a message from it. The selected cluster is now marked as processed.
4. Repeat steps 2-3 until all clustes have been processed.

Step 2 (the receipt of non-degenerate messages from all neighbors) guarantees
that all cluster beliefs will be non-degenerate, while step 3 (the use, where
possible, of messages that can be computed instead of default messages)
guarantees that all subsequent received messages are well-defined.
"""
function init_messages!(beliefs::ClusterGraphBelief, cgraph::MetaGraph)
    # (clust1, clust2) ∈ messagesent => clust1 has sent a message to clust2
    messagesent = Set{NTuple{2,Symbol}}()
    b = beliefs.belief
    for clusterlab in labels(cgraph)
        tosend = NTuple{3,Int}[] # track messages to send after updating belief
        from = clusterindex(clusterlab, beliefs) # sending-cluster index
        for nblab in neighbor_labels(cgraph, clusterlab)
            to = clusterindex(nblab, beliefs) # receiving-cluster index
            by = sepsetindex(clusterlab, nblab, beliefs) # sepset index
            if (nblab, clusterlab) ∉ messagesent
                propagate_belief!(b[from], b[by]) # receive default message
                push!(messagesent, (nblab, clusterlab))
            end
            if (clusterlab, nblab) ∉ messagesent
                push!(tosend, (to, by, from))
                push!(messagesent, (clusterlab, nblab))
            end
        end
        for (to, by, from) in tosend
            #= `false`: raise error if message is ill-defined instead of
            handling it by sending a default message =#
            propagate_belief!(b[to], b[by], b[from], false)
        end
    end
end

"""
    calibrate!(beliefs::ClusterGraphBelief, schedule, niterations=1;
        auto::Bool=false, info::Bool=true)

Propagate messages in postorder then preorder for each tree in the `schedule`
list, and loop through for `niterations`. Each schedule "tree" should be a tuple
of 4 vectors as output by [`spanningtree_clusterlist`](@ref), where each vector
provides the parent/child label/index of an edge along which to pass a message,
and where these edges are listed in preorder. For example, the parent of the
first edge is taken to be the root of the schedule tree.

Calibration is flagged when after a schedule "tree" is run, it is found that each
possible message sent in the cluster graph was last equal to its moderating
sepset belief (within some tolerance). If `info=true`, then prints the
iteration number and tree index when calibration is flagged, or that `niterations`
have passed without calibration being flagged.

If `auto=true`, then `true` if calibration is flagged within `niterations`
(returns upon detection) and `false` otherwise.

The conditions for flagging calibration are sufficient but not necessary (e.g.
the default of 1 iteration is sufficient for exact calibration if the schedule
tree is a clique tree for the graphical model, but an additional iteration is
required to detect that all messages have not changed).

See also: [`iscalibrated_canon`](@ref)
"""
function calibrate!(beliefs::ClusterGraphBelief, schedule::AbstractVector,
    niter::Integer=1; auto::Bool=false, info::Bool=false)
    # fixit: input checks?
    i = 0
    iscal = false
    while i < niter
        i += 1
        for (j, spt) in enumerate(schedule)
            if calibrate!(beliefs, spt) && (iscal = true)
                info && @info "Calibration detected: iter $i, sch $j"
                auto && return true # stop if calibration is detected
            end
        end
    end
    iscal || info && @info "`niter` reached before calibration detected"
    # fixit: check calibration properly at the end?
    auto && return false
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
    approximate_kl!(residual::AbstractResidual, sepset::AbstractBelief,
        canonicalparams::Tuple)

Update `residual` information with an approximation to the KL divergence between
a message (specified by `canonicalparams`) sent through a sepset, and the sepset
belief before the belief-update, given its belief after (`sepset`).
This approximation computes the negative average energy of the residual canonical
parameters, with the `g` parameter set to 0, with respect to the message
canonical parameters.

## Calculation:
    message sent: f(x) = C(Jₘ, hₘ, _) ≡ x ~ 𝒩(μ=Jₘ⁻¹hₘ, Σ=Jₘ⁻¹)
    sepset (before belief-update): C(Jₛ, hₛ, gₛ)
    sepset (after belief-update): C(Jₘ, hₘ, gₘ)
    residual: C(ΔJ = Jₘ - Jₛ, Δh = hₘ - hₛ, Δg = gₘ - gₛ)

        KL(C(Jₘ, hₘ, gₘ) || C(Jₛ, hₛ, gₛ))
    = E[log C(Jₘ, hₘ, gₘ)/C(Jₛ, hₛ, gₛ)] where x ∼ C(Jₘ, hₘ, gₘ)
    = E[-(1/2)x'*ΔJ*x + Δh'x + Δg)]
    ≈ E[-(1/2)x'*ΔJ*x + Δh'x], Δg dropped
    = -average_energy(C(Jₘ, hₘ, _), C(ΔJ, Δh, 0))

See also: [`average_energy`](@ref)
"""
function approximate_kl!(res::AbstractResidual, sepset::AbstractBelief,
    residcanon::Tuple{AbstractMatrix{T}, AbstractVector{T}, T}) where {T <: Real}
    # TODO: For ForwardDiff to work well with GeneralLazyBufferCache, type T must be specified.
    #=
    isposdef(C::Union{Cholesky,CholeskyPivoted}) = C.info == 0
    There is a bug in StaticArrays.jl
    =#
    # note: `isposdef` returns true for size (0,0) MMatrices and the [0.0] MMatrix
    if LA.isposdef(sepset.J) && size(sepset.J)[1] > 0 &&
        (size(sepset.J)[1] > 1 || sepset.J[1] > 0)
        res.kldiv[1] = -average_energy(sepset, residcanon, true)
        iscalibrated_kl!(res)
    end
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
        mr[(pa_lab[i], ch_lab[i])].ΔJ .= residual[1]
        mr[(pa_lab[i], ch_lab[i])].Δh .= residual[2]
        iscalibrated_canon!(mr[(pa_lab[i], ch_lab[i])])
        # compute KL div. between message and sepset
        approximate_kl!(mr[(pa_lab[i], ch_lab[i])], sepset, residual)
    end
end

function propagate_1traversal_preorder!(beliefs::ClusterGraphBelief,
                                        pa_lab, ch_lab, pa_j, ch_j)
    b = beliefs.belief
    mr = beliefs.messageresidual
    # (child <- sepset <- parent) in preorder
    for i in eachindex(pa_lab)
        ss_j = sepsetindex(pa_lab[i], ch_lab[i], beliefs)
        sepset, residual = propagate_belief!(b[ch_j[i]], b[ss_j], b[pa_j[i]])
        mr[(ch_lab[i], pa_lab[i])].ΔJ .= residual[1]
        mr[(ch_lab[i], pa_lab[i])].Δh .= residual[2]
        iscalibrated_canon!(mr[(ch_lab[i], pa_lab[i])])
        approximate_kl!(mr[(ch_lab[i], pa_lab[i])], sepset, residual)
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
        factors_reset!(beliefs) # reset factors each time θ changes
        propagate_1traversal_postorder!(beliefs, spt...)
        _, res = integratebelief!(beliefs, rootj) # drop conditional mean
        return -res # score to be minimized (not maximized)
    end
    # autodiff does not currently work with ForwardDiff, ReverseDiff of Zygote,
    # because they cannot differentiate array mutation, as in: view(be.h, factorind) .+= h
    # consider solutions suggested here: https://fluxml.ai/Zygote.jl/latest/limitations/
    # Could this cache technique be used ?
    # https://github.com/JuliaDiff/ForwardDiff.jl/issues/136#issuecomment-237941790
    # https://juliadiff.org/ForwardDiff.jl/dev/user/limitations/
    # See PreallocationTools.jl package (below)
    opt = Optim.optimize(score, params_optimize(mod), Optim.LBFGS())
    # fixit: if BM and fixed root, avoid optimization bc there exists an exact alternative
    loglikscore = -Optim.minimum(opt)
    bestθ = Optim.minimizer(opt)
    bestmodel = evomodelfun(params_original(mod, bestθ)...)
    return bestmodel, loglikscore, opt
end

function calibrate_optimize_cliquetree_autodiff!(bufferbeliefs::GeneralLazyBufferCache,
        cgraph, prenodes::Vector{PN.Node},
        tbl::Tables.ColumnTable, taxa::AbstractVector,
        evomodelfun, # constructor function
        evomodelparams)
    spt = spanningtree_clusterlist(cgraph, prenodes)
    rootj = spt[3][1] # spt[3] = indices of parents. parent 1 = root
    mod = evomodelfun(evomodelparams...) # model with starting values
    #= 
    TODO: externalize the cache to avoid re-alocation (as done here) ?
    Or define cache inside of the function ?
    Note that the second option needs net in the arguments.
    lbc = PreallocationTools.GeneralLazyBufferCache(function (paramOriginal)
         model = evomodelfun(paramOriginal...)
         belief = init_beliefs_allocate(tbl, taxa, net, cgraph, model);
         return ClusterGraphBelief(belief)
     end)
    =#
    #= 
    TODO: GeneralLazyBufferCache is the "laziest" solution from PreallocationTools
    there might be more efficient solutions using lower level caches. 
    =#
    # score function using cache
    function score(θ) # θ: unconstrained parameters, e.g. log(σ2)
        paramOriginal = params_original(mod, θ)
        model = evomodelfun(paramOriginal...)
        dualBeliefs = bufferbeliefs[paramOriginal]
        init_beliefs_reset!(dualBeliefs.belief)
        init_beliefs_assignfactors!(dualBeliefs.belief, model, tbl, taxa, prenodes)
        factors_reset!(dualBeliefs) # reset factors each time θ changes
        propagate_1traversal_postorder!(dualBeliefs, spt...)
        _, res = integratebelief!(dualBeliefs, rootj) # drop conditional mean
        return -res # score to be minimized (not maximized)
    end
    # optim using autodiff
    od = OnceDifferentiable(score, params_optimize(mod); autodiff = :forward);
    opt = Optim.optimize(od, params_optimize(mod), Optim.LBFGS())
    # fixit: if BM and fixed root, avoid optimization bc there exists an exact alternative
    loglikscore = -Optim.minimum(opt)
    bestθ = Optim.minimizer(opt)
    bestmodel = evomodelfun(params_original(mod, bestθ)...)
    return bestmodel, loglikscore, opt
end

"""
    calibrate_optimize_clustergraph!(beliefs::ClusterGraphBelief, clustergraph,
        nodevector_preordered, tbl::Tables.ColumnTable, taxa::AbstractVector,
        evolutionarymodel_name, evolutionarymodel_startingparameters,
        max_iterations)

Same as [`calibrate_optimize_cliquetree!`](@ref) above, except that the user can
supply an arbitrary `clustergraph` (including a clique tree) for the input
network. Optimization aims to maximize a free energy approximation (the negative
Bethe [`free_energy`](@ref)) to the ELBO for the log-likelihood of the data.
When `clustergraph` is a clique tree, the free energy approximation is exactly
equal to the ELBO and the log-likelihood.

The calibration repeatedly loops through a minimal set of spanning trees (see
[`spanningtrees_cover_clusterlist`](@ref)) that covers all edges in the cluster
graph, and does a postorder-preorder traversal for each tree. The loop runs till
calibration is detected or till `max_iterations` have passed, whichever occurs
first.
"""
function calibrate_optimize_clustergraph!(beliefs::ClusterGraphBelief,
        cgraph, prenodes::Vector{PN.Node},
        tbl::Tables.ColumnTable, taxa::AbstractVector,
        evomodelfun, # constructor function
        evomodelparams, maxiter::Integer=100)
    sch = spanningtrees_cover_clusterlist(cgraph, prenodes)
    mod = evomodelfun(evomodelparams...) # model with starting values
    function score(θ)
        model = evomodelfun(params_original(mod, θ)...)
        init_beliefs_reset!(beliefs.belief)
        init_beliefs_assignfactors!(beliefs.belief, model, tbl, taxa, prenodes)
        factors_reset!(beliefs)
        # fixit: raise warning if calibration is not attained within `maxiter`?
        init_messages!(beliefs, cgraph)
        calibrate!(beliefs, sch, maxiter, auto=true)
        return free_energy(beliefs)[3] # minimize Bethe free energy
    end
    opt = Optim.optimize(score, params_optimize(mod), Optim.LBFGS())
    fenergy = Optim.minimum(opt) 
    bestθ = Optim.minimizer(opt)
    bestmodel = evomodelfun(params_original(mod, bestθ)...)
    return bestmodel, fenergy, opt
end

"""
    calibrate_exact_cliquetree!(beliefs::ClusterGraphBelief, clustergraph,
        nodevector_preordered, tbl::Tables.ColumnTable, taxa::AbstractVector,
        evolutionarymodel_name)

For a Brownian Motion with a fixed root, compute the exact maximum likelihood
parameters using closed form formulas relying on belief propagation.
The  `clustergraph` is assumed to be a clique tree for the input tree,
whose nodes in preorder are `nodevector_preordered`.
Optimization aims to maximize the likelihood
of the data in `tbl` at leaves in the network.
The taxon names in `taxa` should appear in the same order as they come in `tbl`.
The parameters being optimized are the variance rate(s) and prior mean(s)
at the root. The prior variance at the root is fixed to zero.

The calibration does a postorder of the clique tree only, using the optimal parameters,
to get the likelihood
at the root *without* the conditional distribution at all nodes, modifying
`beliefs` in place. Therefore, if the distribution of ancestral states is sought,
an extra preorder calibration would be required.
Warning: there is *no* check that the cluster graph is in fact a clique tree.
"""
# TODO deal with missing values (only completelly missing tips)
# TODO network case
function calibrate_exact_cliquetree!(beliefs::ClusterGraphBelief,
    cgraph, prenodes::Vector{PN.Node},
    tbl::Tables.ColumnTable, taxa::AbstractVector,
    evomodelfun, # constructor function
    evomodelparams
)
    evomodelfun == UnivariateBrownianMotion || evomodelfun == MvFullBrownianMotion || error("Exact optimization is only implemented for the univariate or full Brownian Motion.")
    model = evomodelfun(evomodelparams...)
    isrootfixed(model) || error("Exact optimization is only implemented for the BM with fixed root.")
    ## TODO: check that the tree was calibrated with the right model MvDiagBrownianMotion((1,1), (0,0), (Inf,Inf)) ?
    ## TODO: or do this first calibration directly in the function ? (API change)
    p = dimension(model)

    ## Compute mu_hat from root belief
    ## Root is the last node of the root cluster
    spt = spanningtree_clusterlist(cgraph, prenodes)
    rootj = spt[3][1] # spt[3] = indices of parents. parent 1 = root
    exp_root, _ = integratebelief!(beliefs, rootj)
    mu_hat = exp_root[(end-p+1):end]

    ## Compute sigma2_hat from conditional moments
    tmp_num = zeros(p, p)
    tmp_den = 0
    # loop over all nodes
    for i in eachindex(prenodes)
        # TODO: is it the correct way to iterate over the graph ?
        # remove the root which is first in pre-order
        i == 1 && continue
        # find associated cluster
        nodechild = prenodes[i]
        clusterindex = findClusterIndex(nodechild, beliefs.belief)
        b = beliefs.belief[clusterindex]
        dimclus = length(b.nodelabel)
        # child ind in the cluster
        childind = findfirst(b.nodelabel .== i)
        # find parents: assumes that a cluster has all the parents of a node, which should be the case thanks to findClusterIndex
        parind = findall([PN.isconnected(prenodes[nl], nodechild) && nl != i for nl in b.nodelabel])
        all_parent_edges = [PN.getConnectingEdge(prenodes[b.nodelabel[d]], nodechild) for d in parind]
        all_gammas = zeros(dimclus)
        all_gammas[parind] = [ee.gamma for ee in all_parent_edges]
        # parent(s) edge length
        edge_length = 0.0
        for ee in all_parent_edges
            edge_length += ee.gamma * ee.gamma * ee.length
        end
        edge_length == 0.0 && continue # if edge has length zero, then the parameter R does not occur in the factor
        # moments
        exp_be, _ = integratebelief!(b)
        vv = inv(b.J)
        # tip node
        if (nodechild.leaf) # tip node
            # TODO: deal with missing data
            # TODO: is there a more simple way to do that ? Record of data in belief object ?
            size(vv, 1) == p || error("A leaf node should have only on non-degenerate factor.")
            # find tip data
            nodelab = nodechild.name
            i_row = findfirst(isequal(nodelab), taxa)
            !isnothing(i_row) || error("A node with data does not match any taxon")
            tipvalue = [tbl[v][i_row] for v in eachindex(tbl)]
            # parent node moments are the p first
            indpar = 1:p
            diffExp = view(exp_be, indpar) - tipvalue
            tmp_num += diffExp * transpose(diffExp) ./ edge_length
            # assumes that vv is a scalar times R_test
            tmp_den += 1 - vv[1, 1] / edge_length
        else # internal node
            # init with child node
            begic = (childind - 1) * p + 1
            endic = childind * p
            diffExp = view(exp_be, begic:endic)
            diffVar = vv[begic, begic]
            # sum over parent nodes
            for d in parind
                # indexes
                begi = (d - 1) * p + 1
                endi = d * p
                # exp and covar with child
                diffExp -= all_gammas[d] .* view(exp_be, begi:endi)
                diffVar -= 2 * all_gammas[d] * vv[begic, begi]
                # parents var covar
                for d2 in parind
                    begi2 = (d2 - 1) * p + 1
                    diffVar += all_gammas[d] * all_gammas[d2] * vv[begi, begi2]
                end
            end
            tmp_num += diffExp * transpose(diffExp) ./ edge_length
            tmp_den += 1 - diffVar / edge_length
        end
    end
    sigma2_hat = tmp_num ./ tmp_den
    ## TODO: This is the REML estimate. Should we get ML instead ?

    ## Get optimal paramters
    bestθ = (sigma2_hat, mu_hat, zeros(p, p))
    bestmodel = evomodelfun(bestθ...)
    ## Get associated likelihood
    ## TODO: likelihood for the full BM (not implemented)
    loglikscore = NaN
    if (evomodelfun == UnivariateBrownianMotion)
        init_beliefs_reset!(beliefs.belief)
        update_root_inscope!(beliefs.belief, model)
        init_beliefs_assignfactors!(beliefs.belief, bestmodel, tbl, taxa, prenodes)
        propagate_1traversal_postorder!(beliefs, spt...)
        _, loglikscore = integratebelief!(beliefs, rootj)
    end

    return bestmodel, loglikscore
end

"""
    findClusterIndex(node::PN.Node, belief_vector)

In the belief in the vector that contains both the node and all its parents.
Throws an error if this cluster does not ex

"""
function findClusterIndex(node::PN.Node, belief_vector)
    nodelab = node.name
    for i in eachindex(belief_vector)
        b = belief_vector[i]
        # only cluster beliefs
        b.type == bclustertype || continue
        # label should match
        occursin(nodelab, String(b.metadata)) || continue
        # node should be in a cluster with all its parents
        parentlabels = [nn.name for nn in PN.getparents(node)]
        all([occursin(ll, String(b.metadata)) for ll in parentlabels]) || continue
        # if still here, we found the cluster
        return i
    end
    error("Could not find a cluster with the node and all its parents.")
end