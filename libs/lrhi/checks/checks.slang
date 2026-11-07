/// `counts`: rays cast at each triangle, candidates that reached the shader
/// for each, and hits committed on each.
struct Push {
    uint64_t scene;
    uint* counts;
    uint rays_per_triangle;
};

[[vk::push_constant]] Push push;

/// Ray `index` of triangle `triangle`: a point of a grid over the triangle
/// at (2 * triangle, 0), (2 * triangle + 1, 0), (2 * triangle, 1), kept
/// clear of its edges; false for grid points outside it.
bool rayAt(uint index, out float2 at) {
    uint side = uint(sqrt(float(push.rays_per_triangle)));
    uint triangle = index / push.rays_per_triangle;
    uint local = index % push.rays_per_triangle;
    float2 uv = (float2(local % side, local / side) + 0.5) / float(side);
    at = float2(2.0 * float(triangle), 0.0) + uv;
    return uv.x > 0.02 && uv.y > 0.02 && uv.x + uv.y < 0.98;
}

/// Rays straight down onto the two triangles, counting what reaches the
/// candidate test and what traversal commits. Commits nothing itself, so
/// only hardware-settled opaque parts are ever hit.
[shader("compute")]
[numthreads(64, 1, 1)]
void candidatesMain(uint3 id : SV_DispatchThreadID) {
    if (id.x >= 2u * push.rays_per_triangle) return;
    float2 at;
    if (!rayAt(id.x, at)) return;
    uint triangle = id.x / push.rays_per_triangle;
    InterlockedAdd(push.counts[triangle], 1u);
    RayDesc ray;
    ray.Origin = float3(at, 1.0);
    ray.Direction = float3(0.0, 0.0, -1.0);
    ray.TMin = 0.0;
    ray.TMax = 2.0;
    RayQuery<RAY_FLAG_NONE> query;
    query.TraceRayInline(RaytracingAccelerationStructure(push.scene), RAY_FLAG_NONE, 0xff, ray);
    while (query.Proceed()) {
        if (query.CandidateType() == CANDIDATE_NON_OPAQUE_TRIANGLE)
            InterlockedAdd(push.counts[2u + query.CandidatePrimitiveIndex()], 1u);
    }
    if (query.CommittedStatus() == COMMITTED_TRIANGLE_HIT)
        InterlockedAdd(push.counts[4u + query.CommittedPrimitiveIndex()], 1u);
}
