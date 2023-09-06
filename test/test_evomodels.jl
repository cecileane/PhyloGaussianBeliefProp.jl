@testset "evolutionary models" begin
m = PGBP.MvDiagBrownianMotion([1,0.5], [-1,1]) # default 0 root variance
m = PGBP.MvDiagBrownianMotion([1,0.5], [-1,1], [0,1])
@test PGBP.dimension(m) == 2
m = PGBP.MvFullBrownianMotion([1 0.5; 0.5 1], [-1,1]) # default 0 root variance
m = PGBP.MvFullBrownianMotion([1 0.5; 0.5 1], [-1,1], [10^10 0; 0 10^10])
@test PGBP.dimension(m) == 2
m = PGBP.UnivariateBrownianMotion(2, 3)
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
