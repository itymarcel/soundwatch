// MSL for the City's global illumination rays (appended to the City's library, after cityShaderSource; the shared
// LandGI core is pasted into it). One ray per 8 × 8 pixels from the primary hits (the walk of `cityWalk`), traced
// through the same lot grid as everything else, the hit shaded like a reflection (lit windows, neon, shop fronts,
// lamp-lit streets, cars, the drones' light), the haze on the way; split over the cascades (LandGI).
let cityGIShaderSource = #"""

/// Radiance coming back along a GI ray: the hit shaded like cityReflShade does (cheap lighting, details faded out).
static float3 giCityShade(Hit h2, float3 rO, float3 rD, float fp2, constant CityU& U, constant float4* L) {
    int2 lb = int2(1 << 30); float lD = 0.0;
    float3 p2 = rO + rD * h2.t;
    float gloom = U.cfg3.x;
    float3 rc;
    if (h2.kind == 2) {
        Bld b2 = building(h2.cell, U, lb, lD, -1e9, false);
        bldLook(b2);
        Look k2 = lookOf(b2, U.cfg4.x);
        float g2, wm2; float3 sp2; float2 j2;
        if (h2.sub == 2 || h2.n.y < -0.5) {
            float3 a2 = k2.wall * 0.6; float gg;
            rc = h2.sub == 2 ? balconyShade(p2, h2, b2, k2, U, fp2, a2, gg) : float3(0.0);
            rc += a2 * lighting(p2, h2.n, U, L, true);
        } else if (h2.part == 4) {
            float3 a2;
            rc = roofBox(p2, h2, b2, U, fp2, a2);
            rc += a2 * lighting(p2, h2.n, U, L, true);
        } else if (h2.n.y > 0.5) {
            float3 a2;
            rc = roof(p2, h2, b2, U, fp2, a2) + a2 * lighting(p2, h2.n, U, L, true);
        } else {
            float3 n2; float4 ov2;
            rc = facade(p2, h2.n, rD, h2, b2, k2, U, fp2, g2, sp2, wm2, j2, n2, ov2);
            rc += mix(k2.wall * wm2, ov2.rgb, ov2.a) * (lighting(p2, n2, U, L, true) + (sp2 * 1.6 + fogTint(U) * 0.15) * (0.5 + gloom))
                  * (0.4 + 0.6 * smoothstep(0.0, 14.0, p2.y));
        }
    } else if (h2.kind == 3) {
        rc = carShade(p2, h2, U, fp2);
    } else if (h2.kind == 1) {
        float w2;
        rc = ground(p2, h2, rD, U, L, fp2, w2, true, float4(0.0));
    } else {
        rc = sky(rD, U, 0.0);
    }
    float d2 = (0.00025 + 0.0022 * U.cfg.w) * (1.0 + 4.0 * gloom) * exp(-max(1.0, rO.y + rD.y * min(h2.t, 1500.0) * 0.5) / (260.0 + 200.0 * gloom));
    return mix(rc, fogTint(U), 1.0 - exp(-min(h2.t, 3000.0) * d2 * (h2.kind == 0 ? 0.6 : 1.0)));
}

/// R = target width, height, ray step, unused.
static bool giCityRay(uint2 gid, constant GIView& V, constant CityU& U, constant float4* L, uint4 R, texture2d<float> walkTex,
                      thread float3& p, thread int& lev, thread float3& dir, thread float4* iv, thread float* P, thread int& n) {
    uint W = R.x, H = R.y, st = R.z;
    uint frame = uint(V.anchor.w);
    uint seed = giHash(gid.x * 7919u + gid.y * 104729u + frame * 2654435761u);
    uint2 px = gid * st + uint2(min(uint(giRand(seed) * float(st)), st - 1u), min(uint(giRand(seed) * float(st)), st - 1u));
    if (px.x >= W || px.y >= H) return false;
    float2 uv = (float2(px) + 0.5) / float2(W, H);
    float3 rd = primaryDir(uv, U), ro = U.cam.xyz;
    Hit h = primaryHit(walkTex.read(px), ro, rd, U, false);
    if (h.kind == 0 || h.kind == 3) return false;            // sky, cars
    p = ro + rd * h.t;
    float3 N = h.kind == 1 ? float3(0.0, 1.0, 0.0) : h.n;
    lev = giPickLevel(p - ro, giRand(seed));
    if (lev < 0) return false;
    dir = giCosDir(N, giRand(seed), giRand(seed));
    float3 o = p + N * 0.05;
    float lamps = 0.0;
    Hit h2 = trace(o, dir, 40, min(500.0, hazeFar(o, U)), U, false, lamps, U.fwd.w, false);
    float fp2 = max(0.3, (h.t + h2.t) * U.fwd.w * 6.0);       // seen blurred: windows and details at their averages
    float3 rc = giCityShade(h2, o, dir, fp2, U, L);
    int hc = h2.kind == 0 ? 3 : giCascadeOf(h2.t, lev);
    for (int c = 0; c < 4; c++) { iv[c] = float4(0.0, 0.0, 0.0, 1.0); P[c] = 1.0; }
    iv[hc] = float4(rc, 0.0);
    n = hc + 1;
    return true;
}

kernel void giCityTrace(uint2 gid [[thread_position_in_grid]], uint lane [[thread_index_in_simdgroup]],
                        constant GIView& V [[buffer(0)]], GI_BUF_PARAMS,
                        constant CityU& U [[buffer(10)]], constant float4* L [[buffer(14)]], constant uint4& R [[buffer(15)]],
                        texture2d<float> walkTex [[texture(0)]]) {
    float3 p = float3(0.0), dir = float3(0.0, 1.0, 0.0);
    int lev = 0, n = 0;
    float4 iv[4]; float P[4];
    bool ok = giCityRay(gid, V, U, L, R, walkTex, p, lev, dir, iv, P, n);
    giSplatSimd(GI_BUFS, ok, p, V.anchor.xyz, lev, dir, iv, P, n, uint(V.anchor.w), lane);
}
"""#
