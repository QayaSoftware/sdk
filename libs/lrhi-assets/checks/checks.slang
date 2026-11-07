/// `outcomes`: for each ray, 0 when it passed, 1 when it reached the
/// candidate test, 2 when traversal committed a hit without one.
struct Push {
    uint64_t scene;
    uint* outcomes;
    uint side;
};

[[vk::push_constant]] Push push;

/// Rays straight down onto the triangle (0, 0), (1, 0), (0, 1) at the
/// centers of a `side` x `side` grid; grid points outside it are skipped.
[shader("compute")]
[numthreads(64, 1, 1)]
void outcomesMain(uint3 id : SV_DispatchThreadID) {
    if (id.x >= push.side * push.side) return;
    float2 at = (float2(id.x % push.side, id.x / push.side) + 0.5) / float(push.side);
    push.outcomes[id.x] = 0u;
    if (at.x + at.y >= 1.0) return;
    RayDesc ray;
    ray.Origin = float3(at, 1.0);
    ray.Direction = float3(0.0, 0.0, -1.0);
    ray.TMin = 0.0;
    ray.TMax = 2.0;
    RayQuery<RAY_FLAG_NONE> query;
    query.TraceRayInline(RaytracingAccelerationStructure(push.scene), RAY_FLAG_NONE, 0xff, ray);
    uint outcome = 0u;
    while (query.Proceed()) {
        if (query.CandidateType() == CANDIDATE_NON_OPAQUE_TRIANGLE) outcome = 1u;
    }
    if (query.CommittedStatus() == COMMITTED_TRIANGLE_HIT) outcome = 2u;
    push.outcomes[id.x] = outcome;
}
