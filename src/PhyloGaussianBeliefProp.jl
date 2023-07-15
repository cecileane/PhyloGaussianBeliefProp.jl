module PhyloGaussianBeliefProp

import Base: show
using Graphs
using MetaGraphsNext
using Distributions: MvNormalCanon, MvNormal, AbstractMvNormal
import LinearAlgebra as LA
using PDMats
using StaticArrays
using StatsFuns
using Tables

import PhyloNetworks as PN
using PhyloNetworks: HybridNetwork, getparents, getparent, getparentedge,
        getchild, getchildren, getchildedge, hassinglechild


include("utils.jl")
include("clustergraph.jl")
include("evomodels.jl")
include("canonicalnormal.jl")
include("beliefupdates.jl")
include("calibration.jl")

end
