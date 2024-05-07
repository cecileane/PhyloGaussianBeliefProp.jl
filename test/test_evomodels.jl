@testset "evolutionary models parameters" begin
m = PGBP.MvDiagBrownianMotion([1,0.5], [-1,1]) # default 0 root variance
m = PGBP.MvDiagBrownianMotion([1,0.5], [-1,1], [0,1])
par = PGBP.params_optimize(m)
oripar = PGBP.params_original(m, par)
@test oripar == PGBP.params(m)
@test PGBP.dimension(m) == 2
m = PGBP.MvFullBrownianMotion([1.0, .5, 0.8660254037844386], [-1,1]) # default 0 root variance
@test PGBP.varianceparam(m) ≈ [1 0.5; 0.5 1]
@test PGBP.rootpriorvariance(m) == [0 0; 0 0]
m = PGBP.MvFullBrownianMotion([1 0.5; 0.5 1], [-1,1], [10^10 0; 0 10^10])
@test PGBP.dimension(m) == 2
m = PGBP.UnivariateBrownianMotion(2, 3)
par = PGBP.params_optimize(m)
oripar = PGBP.params_original(m, par)
@test oripar[1] ≈ PGBP.params(m)[1]
@test oripar[2] ≈ PGBP.params(m)[2]
h,J,g = PGBP.factor_treeedge(m, 1)
@test h == [0.0,0]
@test J == [.5 -.5; -.5 .5]
@test g ≈ -1.2655121234846454
m2 = PGBP.UnivariateBrownianMotion(2, 3, 0)
@test m == m2
m2 = PGBP.UnivariateBrownianMotion(2.0, 3, 0)
@test m == m2
m2 = PGBP.UnivariateBrownianMotion([2], [3])
@test m == m2
m2 = PGBP.UnivariateBrownianMotion([2], [3.0])
@test m == m2
m2 = PGBP.UnivariateBrownianMotion([2], 3)
@test m == m2
m2 = PGBP.UnivariateBrownianMotion([2], 3.0)
@test m == m2
m2 = PGBP.UnivariateBrownianMotion([2], 3, 0)
@test m == m2
m2 = PGBP.UnivariateBrownianMotion([2.0], 3, 0)
@test m == m2
m2 = PGBP.UnivariateBrownianMotion([2], 3, [0])
@test m == m2
m2 = PGBP.UnivariateBrownianMotion([2], 3.0, [0])
@test m == m2
@test_throws "scalars" PGBP.UnivariateBrownianMotion([2,2], [3], [0])
@test_throws "scalars" PGBP.UnivariateBrownianMotion([2,2], 3, 0)
@test_throws "scalars" PGBP.UnivariateBrownianMotion([2], [3,3])
@test_throws "scalars" PGBP.UnivariateBrownianMotion([2], 3, [0,0])
end

@testset "evolutionary models likelihood" begin
    netstr = "(((A:4.0,((B1:1.0,B2:1.0)i6:0.6)#H5:1.1::0.9)i4:0.5,(#H5:2.0::0.1,C:0.1)i2:1.0)i1:3.0);"
    net = readTopology(netstr)
    df = DataFrame(taxon=["A","B1","B2","C"], x=[10,10,missing,0], y=[1.0,.9,1,-1])
    df_var = select(df, Not(:taxon))
    tbl = columntable(df_var)
    tbl_y = columntable(select(df, :y)) # 1 trait, for univariate models
    tbl_x = columntable(select(df, :x))

    ct = PGBP.clustergraph!(net, PGBP.Cliquetree())
    spt = PGBP.spanningtree_clusterlist(ct, net.nodes_changed)
    rootclusterindex = spt[3][1]
    # allocate beliefs to avoid re-allocation of same sizes for multiple tests
    m_uniBM_fixedroot = PGBP.UnivariateBrownianMotion(2, 3, 0)
    b_y_fixedroot = PGBP.init_beliefs_allocate(tbl_y, df.taxon, net, ct, m_uniBM_fixedroot)
    m_uniBM_randroot = PGBP.UnivariateBrownianMotion(2, 3, Inf)
    b_y_randroot = PGBP.init_beliefs_allocate(tbl_y, df.taxon, net, ct, m_uniBM_randroot)
    m_biBM_fixedroot = PGBP.MvDiagBrownianMotion((2,1), (3,-3), (0,0))
    b_xy_fixedroot = PGBP.init_beliefs_allocate(tbl, df.taxon, net, ct, m_biBM_fixedroot)
    m_biBM_randroot = PGBP.MvDiagBrownianMotion((2,1), (3,-3), (0.1,10))
    b_xy_randroot = PGBP.init_beliefs_allocate(tbl, df.taxon, net, ct, m_biBM_randroot)

    @testset "homogeneous univariate BM" begin
        @testset "Fixed Root, no missing" begin
        # y no missing, fixed root
        show(devnull, m_uniBM_fixedroot)
        PGBP.init_beliefs_assignfactors!(b_y_fixedroot, m_uniBM_fixedroot, tbl_y, df.taxon, net.nodes_changed);
        ctb = PGBP.ClusterGraphBelief(b_y_fixedroot)
        PGBP.propagate_1traversal_postorder!(ctb, spt...)
        _, tmp = PGBP.integratebelief!(ctb, rootclusterindex)
        @test tmp ≈ -10.732857817537196
        end
        @testset "Infinite Root, no missing" begin
        # y no missing, infinite root variance
        PGBP.init_beliefs_assignfactors!(b_y_randroot, m_uniBM_randroot, tbl_y, df.taxon, net.nodes_changed);
        ctb = PGBP.ClusterGraphBelief(b_y_randroot)
        PGBP.propagate_1traversal_postorder!(ctb, spt...)
        _, tmp = PGBP.integratebelief!(ctb, rootclusterindex)
        @test tmp ≈ -5.899094849099194
        end
        @testset "Random Root, with missing" begin
        # x with missing, random root
        m = PGBP.UnivariateBrownianMotion(2, 3, 0.4)
        b = (@test_logs (:error,"tip B2 in network without any data") PGBP.init_beliefs_allocate(tbl_x, df.taxon, net, ct, m);)
        PGBP.init_beliefs_assignfactors!(b, m, tbl_x, df.taxon, net.nodes_changed);
        ctb = PGBP.ClusterGraphBelief(b)
        PGBP.propagate_1traversal_postorder!(ctb, spt...)
        _, tmp = PGBP.integratebelief!(ctb, rootclusterindex)
        @test tmp ≈ -13.75408386332493
        end
    end
    @testset "homogeneous univariate OU" begin
        @testset "Random Root, no missing" begin
        m = PGBP.UnivariateOrnsteinUhlenbeck(2, 3, -2, 0.0, 0.4)
        show(devnull, m)
        PGBP.init_beliefs_assignfactors!(b_y_randroot, m, tbl_y, df.taxon, net.nodes_changed);
        ctb = PGBP.ClusterGraphBelief(b_y_randroot)
        PGBP.propagate_1traversal_postorder!(ctb, spt...)
        _, tmp = PGBP.integratebelief!(ctb, rootclusterindex)
        @test_broken (prinln("Need to compute OU likelihood on a network."); tmp ≈ 0.0)
        end
    end
    @testset "Diagonal BM" begin
        @testset "homogeneous, fixed root" begin
        PGBP.init_beliefs_assignfactors!(b_xy_fixedroot, m_biBM_fixedroot, tbl, df.taxon, net.nodes_changed);
        ctb = PGBP.ClusterGraphBelief(b_xy_fixedroot)
        PGBP.propagate_1traversal_postorder!(ctb, spt...)
        _, tmp = PGBP.integratebelief!(ctb, rootclusterindex)
        @test tmp ≈ -24.8958130127972
        end
        @testset "homogeneous, random root" begin
        PGBP.init_beliefs_assignfactors!(b_xy_randroot, m_biBM_randroot, tbl, df.taxon, net.nodes_changed);
        ctb = PGBP.ClusterGraphBelief(b_xy_randroot)
        PGBP.propagate_1traversal_postorder!(ctb, spt...)
        _, tmp = PGBP.integratebelief!(ctb, rootclusterindex)
        @test tmp ≈ -21.347496753649892
        end
        @testset "homogeneous, improper root" begin
        m = PGBP.MvDiagBrownianMotion((2,1), (1,-3), (Inf,Inf))
        PGBP.init_beliefs_assignfactors!(b_xy_randroot, m, tbl, df.taxon, net.nodes_changed);
        ctb = PGBP.ClusterGraphBelief(b_xy_randroot)
        PGBP.propagate_1traversal_postorder!(ctb, spt...)
        _, tmp = PGBP.integratebelief!(ctb, rootclusterindex)
        @test tmp ≈ -17.66791635814575
        end
    end
    @testset "Full BM" begin
        @testset "homogeneous, fixed root" begin
        m = PGBP.MvFullBrownianMotion([2.0 0.5; 0.5 1.0], [3.0,-3.0])
        PGBP.init_beliefs_assignfactors!(b_xy_fixedroot, m, tbl, df.taxon, net.nodes_changed);
        ctb = PGBP.ClusterGraphBelief(b_xy_fixedroot)
        PGBP.propagate_1traversal_postorder!(ctb, spt...)
        _, tmp = PGBP.integratebelief!(ctb, rootclusterindex)
        @test tmp ≈ -24.312323855394055
        end
        @testset "homogeneous, random root" begin
        m = PGBP.MvFullBrownianMotion([2.0 0.5; 0.5 1.0], [3.0,-3.0],
                [0.1 0.01; 0.01 0.2])
        PGBP.init_beliefs_assignfactors!(b_xy_randroot, m, tbl, df.taxon, net.nodes_changed);
        ctb = PGBP.ClusterGraphBelief(b_xy_randroot)
        PGBP.propagate_1traversal_postorder!(ctb, spt...)
        _, tmp = PGBP.integratebelief!(ctb, rootclusterindex)
        @test tmp ≈ -23.16482738327936
        end
        @testset "homogeneous, improper root" begin
        m = PGBP.MvFullBrownianMotion([2.0 0.5; 0.5 1.0], [3.0,-3.0],
                [Inf 0; 0 Inf])
        PGBP.init_beliefs_assignfactors!(b_xy_randroot, m, tbl, df.taxon, net.nodes_changed);
        ctb = PGBP.ClusterGraphBelief(b_xy_randroot)
        PGBP.propagate_1traversal_postorder!(ctb, spt...)
        _, tmp = PGBP.integratebelief!(ctb, rootclusterindex)
        @test tmp ≈ -16.9626044836951
        end
    end
    @testset "heterogeneous BM" begin
        @testset "Fixed Root one mv rate" begin
        m = PGBP.HeterogeneousBrownianMotion([2.0 0.5; 0.5 1.0], [3.0, -3.0])
        show(devnull, m)
        PGBP.init_beliefs_assignfactors!(b_xy_fixedroot, m, tbl, df.taxon, net.nodes_changed);
        ctb = PGBP.ClusterGraphBelief(b_xy_fixedroot)
        PGBP.propagate_1traversal_postorder!(ctb, spt...)
        _, tmp = PGBP.integratebelief!(ctb, rootclusterindex)
        @test tmp ≈ -24.312323855394055
        end
        @testset "Random root several mv rates" begin
        rates = [[2.0 0.5; 0.5 1.0], [2.0 0.5; 0.5 1.0]]
        colors = Dict(9 => 2, 7 => 2, 8 => 2) # includes one hybrid edge
        pp = PGBP.PaintedParameter(rates, colors)
        show(devnull, pp)
        m = PGBP.HeterogeneousBrownianMotion(pp, [3.0, -3.0], [0.1 0.01; 0.01 0.2])
        show(devnull, m)
        PGBP.init_beliefs_assignfactors!(b_xy_randroot, m, tbl, df.taxon, net.nodes_changed);
        ctb = PGBP.ClusterGraphBelief(b_xy_randroot)
        PGBP.propagate_1traversal_postorder!(ctb, spt...)
        _, tmp = PGBP.integratebelief!(ctb, rootclusterindex)
        @test tmp ≈ -23.16482738327936
        end
    end
    #= likelihood using PN.vcv and matrix inversion
    using Distributions
    Σnet = Matrix(vcv(net)[!,Symbol.(df.taxon)])
    ## univariate y
    loglikelihood(MvNormal(repeat([3.0],4), Σnet), tbl.y) # -10.732857817537196
    ## univariate x
    xind = [1,2,4]; n = length(xind); i = ones(n) # intercept
    Σ = 2.0 * Σnet[xind,xind] .+ 0.4
    loglikelihood(MvNormal(repeat([3.0],3), Σ), Vector{Float64}(tbl.x[xind])) # -13.75408386332493
    ## Univariate y, REML
    ll(μ) = loglikelihood(MvNormal(repeat([μ],4), Σnet), tbl.y)
    using Integrals
    log(solve(IntegralProblem((x,p) -> exp(ll(x)), -Inf, Inf), QuadGKJL()).u) # -5.899094849099194
    ## Diagonal x, y
    loglikelihood(MvNormal(repeat([3],3), 2 .* Σnet[xind,xind]), Vector{Float64}(tbl.x[xind])) + 
    loglikelihood(MvNormal(repeat([-3],4), 1 .* Σnet), tbl.y) 
    ## Diagonal x y random root
    loglikelihood(MvNormal(repeat([3],3), 2 .* Σnet[xind,xind] .+ 0.1), Vector{Float64}(tbl.x[xind])) + 
    loglikelihood(MvNormal(repeat([-3],4), 1 .* Σnet .+ 10), tbl.y) 
    # Diagonal x y REML
    ll(μ) = loglikelihood(MvNormal(repeat([μ[1]],3), 2 .* Σnet[xind,xind]), Vector{Float64}(tbl.x[xind])) + loglikelihood(MvNormal(repeat([μ[2]],4), 1 .* Σnet), tbl.y) 
    using Integrals
    log(solve(IntegralProblem((x,p) -> exp(ll(x)), [-Inf, -Inf], [Inf, Inf]), HCubatureJL(), reltol = 1e-16, abstol = 1e-16).u) # -17.66791635814575
    # Full x y fixed root
    R = [2.0 0.5; 0.5 1.0]
    varxy = kron(R, Σnet)
    xyind = vcat(xind, 4 .+ [1,2,3,4])
    varxy = varxy[xyind, xyind]
    meanxy = vcat(repeat([3.0],3), repeat([-3.0],4))
    datxy = Vector{Float64}(vcat(tbl.x[xind], tbl.y))
    loglikelihood(MvNormal(meanxy, varxy), datxy) # -24.312323855394055
    # Full x y random root
    R = [2.0 0.5; 0.5 1.0]
    V = [0.1 0.01; 0.01 0.2]
    varxy = kron(R, Σnet) + kron(V, ones(4, 4))
    xyind = vcat(xind, 4 .+ [1,2,3,4])
    varxy = varxy[xyind, xyind]
    meanxy = vcat(repeat([3.0],3), repeat([-3.0],4))
    datxy = Vector{Float64}(vcat(tbl.x[xind], tbl.y))
    loglikelihood(MvNormal(meanxy, varxy), datxy) # -23.16482738327936
    # Full x y improper root
    R = [2.0 0.5; 0.5 1.0]
    varxy = kron(R, Σnet)
    xyind = vcat(xind, 4 .+ [1,2,3,4])
    varxy = varxy[xyind, xyind]
    meanxy = vcat(repeat([3.0],3), repeat([-3.0],4))
    datxy = Vector{Float64}(vcat(tbl.x[xind], tbl.y))
    ll(μ) = loglikelihood(MvNormal(vcat(repeat([μ[1]],3),repeat([μ[2]],4)), varxy), datxy)
    using Integrals
    log(solve(IntegralProblem((x,p) -> exp(ll(x)), [-Inf, -Inf], [Inf, Inf]),
        HCubatureJL(), reltol = 1e-16, abstol = 1e-16).u) # -16.9626044836951
    =#
end
