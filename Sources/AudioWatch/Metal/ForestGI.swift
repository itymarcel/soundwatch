// MSL for the Forest's global illumination rays (appended to the Forest's library, after forestShaderSource; the
// shared LandGI core is pasted into it). The world the GI rays see, rebuilt every frame around the camera:
// - `giForestTrees`: the trees of 256 × 256 tree cells (±512 m), placed exactly as forestScatter places them
//   (but not culled to the view: trees behind the camera block and bounce light too);
// - `giForestField`: a 512 × 512 field of 2 m texels: ground height (6 octaves) and, from the trees around each
//   texel, the canopy as a volume (bottom, top, leaf density) + the leaves' colour and their Band light glow;
// - `giForestTrace`: one ray per 4 × 4 pixels from the depth buffer, marched over that field (sky light lost in the
//   canopy, sunlit leaves and ground bouncing, the river mirroring the sky), split over the cascades (LandGI).
let forestGIShaderSource = #"""

constexpr sampler fieldS(filter::linear, address::clamp_to_edge);

kernel void giForestTrees(uint2 gid [[thread_position_in_grid]], constant ForestU& U [[buffer(10)]],
                          device float4* trees [[buffer(11)]], texture2d<float> T [[texture(0)]]) {
    if (gid.x >= 256u || gid.y >= 256u) return;
    uint idx = (gid.y * 256u + gid.x) * 2u;
    trees[idx] = float4(0.0);
    int2 c = U.cell.xy + int2(gid) - 128;
    int cells = int(WP / U.cfg.z);
    int2 hc = int2(c.x, ((c.y % cells) + cells) % cells);
    float h1 = fh(hc, 1u), h2 = fh(hc, 2u), h3 = fh(hc, 3u);
    float2 xz = (float2(c) + 0.5 + (float2(h1, h2) - 0.5) * 0.85) * U.cfg.z;
    float width; float2 dg;
    float ae = riverDist(T, xz, width, dg);
    float start = width * 1.6 + 3.0;
    if (ae < start) return;
    float dn = nz(T, xz / 64.0 + 5.3).w;
    float dens = smoothstep(-0.35, 0.15, dn) * smoothstep(start, start + 8.0, ae) * U.cfg.x;
    if (h3 > dens) return;
    float3 t = terrain(T, xz, 8);
    if (length(t.yz) > 1.0 || t.x > 235.0) return;
    float h4 = fh(hc, 4u), h5 = fh(hc, 5u);
    float conifer = mix(0.3, 0.97, smoothstep(5.0, 90.0, t.x));
    float sp = h4 < conifer ? 0.0 : 1.0;
    float H = (sp < 0.5 ? 17.0 : 13.0) * (0.55 + 0.9 * h5 * h5) * mix(1.0, 0.55, smoothstep(140.0, 235.0, t.x));
    int bnd = min(int(U.cfg.w) - 1, int(fh(hc, 7u) * U.cfg.w));
    trees[idx] = float4(xz, t.x - 0.25, H);
    trees[idx + 1u] = float4(sp, float(bnd), h1, 0.0);
}

/// Leaf colour of a tree for the GI (close to leafFrag's averages, with the season).
static float3 giLeafAlb(float sp, float r, constant ForestU& U) {
    float3 c = sp < 0.5 ? mix(float3(0.018, 0.045, 0.03), float3(0.035, 0.065, 0.032), r)
                        : mix(float3(0.06, 0.12, 0.022), float3(0.12, 0.15, 0.03), r);
    if (sp > 0.5) {
        c = mix(c, float3(0.12, 0.2, 0.03), U.seasonA.w * 0.6);
        c = mix(c, mix(float3(0.36, 0.22, 0.02), float3(0.34, 0.06, 0.02), fract(r * 7.13)), U.seasonA.z);
    }
    return mix(c, SNOW * 0.85, U.seasonA.x * (sp < 0.5 ? 0.6 : 0.4));
}

/// F = (field origin x, z in the world, texel size, texels).
kernel void giForestField(uint2 gid [[thread_position_in_grid]], constant ForestU& U [[buffer(10)]],
                          const device float4* trees [[buffer(11)]], constant float4& F [[buffer(12)]],
                          const device float* B [[buffer(13)]], texture2d<float> T [[texture(0)]],
                          texture2d<float, access::write> f0 [[texture(1)]], texture2d<float, access::write> f1 [[texture(2)]]) {
    if (gid.x >= uint(F.w) || gid.y >= uint(F.w)) return;
    float2 xz = F.xy + (float2(gid) + 0.5) * F.z;
    float h = terrain(T, xz, 6).x;
    int2 tc = int2(floor(xz / U.cfg.z)) - (U.cell.xy - 128);
    float y0 = 1e9, y1 = -1e9, sig = 0.0, best = 0.0, em = 0.0;
    float3 alb = float3(0.0);
    float foliage = U.seasonA.y;
    for (int dz = -2; dz <= 2; dz++) {
        for (int dx = -2; dx <= 2; dx++) {
            int2 q = tc + int2(dx, dz);
            if (any(q < 0) || any(q > 255)) continue;
            uint k = uint(q.y * 256 + q.x) * 2u;
            float4 a = trees[k];
            if (a.w <= 0.0) continue;
            float4 b = trees[k + 1u];
            float d = length(xz - a.xy), H = a.w;
            float lo, hi, s;
            if (b.x < 0.5) {            // spruce: a cone of fronds from 10 % of the height to the top
                float R = 0.33 * H + 0.4;
                if (d > R) continue;
                lo = a.z + 0.1 * H; hi = a.z + H * (1.0 - 0.9 * d / R); s = 0.55;
            } else {                     // broadleaf: an ellipsoid crown (thin when bare)
                float R = 0.36 * H;
                if (d > R) continue;
                float c = a.z + 0.64 * H, hh = 0.32 * H * sqrt(1.0 - (d / R) * (d / R));
                lo = c - hh; hi = c + hh; s = 0.05 + 0.45 * foliage;
            }
            if (hi <= lo) continue;
            y0 = min(y0, lo); y1 = max(y1, hi); sig = max(sig, s);
            if (hi - lo > best) {
                best = hi - lo;
                alb = giLeafAlb(b.x, b.z, U);
                em = B[int(b.y)] * U.music.w * (b.x < 0.5 || foliage > 0.3 ? 1.0 : 0.2);
            }
        }
    }
    f0.write(float4(h, best > 0.0 ? y0 : 0.0, best > 0.0 ? y1 : 0.0, best > 0.0 ? sig : 0.0), gid);
    f1.write(float4(alb, em), gid);
}

struct GIForestR { float4x4 invVP; float4 field; uint4 misc; };   // misc = target width, height, ray step

/// The sky as the GI sees it: no sun disc (direct sunlight is drawn by the scene itself), no clouds or stars.
static float3 giSkyF(float3 V, constant ForestU& U) {
    float y = V.y;
    float3 c = mix(U.horizon.rgb, U.zenith.rgb, pow(clamp(y, 0.0, 1.0), 0.45));
    if (y < 0.0) c = U.horizon.rgb * mix(1.0, 0.75, clamp(-y * 4.0, 0.0, 1.0));
    float s = max(dot(V, U.sun.xyz), 0.0);
    c += U.sunCol.rgb * pow(s, 6.0) * 0.25;
    return mix(c, U.horizon.rgb * 0.9, 0.4 * U.horizon.w * smoothstep(0.0, 0.3, y));   // overcast
}

static float3 giUnproject(uint2 px, float d, constant GIForestR& R) {
    float2 ndc = float2((float(px.x) + 0.5) / float(R.misc.x) * 2.0 - 1.0, 1.0 - (float(px.y) + 0.5) / float(R.misc.y) * 2.0);
    float4 w = R.invVP * float4(ndc, d, 1.0);
    return w.xyz / w.w;
}

static float2 giFieldUV(float3 q, constant ForestU& U, constant GIForestR& R) {
    return (U.cam.xz + q.xz - R.field.xy) / (R.field.z * R.field.w);
}

/// One GI ray of the pixel block `gid`: false if there is none (sky, off the edge). Fills the split (see giSplatSimd).
static bool giForestRay(uint2 gid, constant GIView& V, constant ForestU& U, constant GIForestR& R,
                        depth2d<float> depth, texture2d<float> T, depth2d_array<float> S, texture2d<float> F0, texture2d<float> F1,
                        texture3d<float> gi0, texture3d<float> gi1, texture3d<float> gi2, texture3d<float> gi3,
                        thread float3& rel, thread int& L, thread float3& dir, thread float4* iv, thread float* P, thread int& n) {
    uint W = R.misc.x, H = R.misc.y, st = R.misc.z;
    uint frame = uint(V.anchor.w);
    uint seed = giHash(gid.x * 7919u + gid.y * 104729u + frame * 2654435761u);
    uint2 px = gid * st + uint2(min(uint(giRand(seed) * float(st)), st - 1u), min(uint(giRand(seed) * float(st)), st - 1u));
    if (px.x < 1u || px.y < 1u || px.x + 1u >= W || px.y + 1u >= H) return false;
    float d = depth.read(px);
    if (d <= 0.0) return false;                              // sky
    rel = giUnproject(px, d, R);
    // the surface normal from the depth buffer (the smaller step on each axis: no smearing over silhouettes)
    float3 pr = giUnproject(px + uint2(1, 0), depth.read(px + uint2(1, 0)), R), pl = giUnproject(px - uint2(1, 0), depth.read(px - uint2(1, 0)), R);
    float3 pd = giUnproject(px + uint2(0, 1), depth.read(px + uint2(0, 1)), R), pu = giUnproject(px - uint2(0, 1), depth.read(px - uint2(0, 1)), R);
    float3 ddx = length_squared(pr - rel) < length_squared(rel - pl) ? pr - rel : rel - pl;
    float3 ddy = length_squared(pd - rel) < length_squared(rel - pu) ? pd - rel : rel - pu;
    float3 N = cross(ddy, ddx);
    if (!(length_squared(N) > 1e-12)) return false;
    N = normalize(N);
    if (dot(N, rel) > 0.0) N = -N;
    L = giPickLevel(rel, giRand(seed));
    if (L < 0) return false;
    dir = giCosDir(N, giRand(seed), giRand(seed));

    for (int c = 0; c < 4; c++) { iv[c] = float4(0.0, 0.0, 0.0, 1.0); P[c] = 0.0; }
    P[0] = 1.0;
    int ci = 0;
    float3 rad = float3(0.0);
    float Tl = 1.0;
    float bnd[3] = { giBound(0, L), giBound(1, L), giBound(2, L) };
    float3 o = rel + N * 0.08;
    // the field's ground (2 m texels) can lie a little above the drawn one: start on top of it
    float hf0 = F0.sample(fieldS, giFieldUV(o, U, R), level(0.0)).x;
    if (o.y + U.cam.y < hf0 + 0.05 && o.y + U.cam.y > hf0 - 2.0) o.y = hf0 - U.cam.y + 0.05;
    float t = 0.0, dtPrev = 0.0;
    bool ended = false;
    for (int i = 0; i < 110; i++) {
        while (ci < 3 && t > bnd[ci]) { iv[ci] = float4(rad, Tl); P[ci + 1] = P[ci] * Tl; ci++; rad = float3(0.0); Tl = 1.0; }
        float3 q = o + dir * t;
        float2 fu = giFieldUV(q, U, R);
        if (any(fu < 0.002) || any(fu > 0.998) || t > 420.0) break;
        float4 f = F0.sample(fieldS, fu, level(0.0));
        float y = q.y + U.cam.y;
        if (y < f.x) {
            // the ground: back to the crossing, then shade it (sun + shadow map, sky / bounce from last frame's GI)
            float ta = t - dtPrev, tb = t;
            for (int k = 0; k < 4; k++) {
                float tm = 0.5 * (ta + tb);
                float3 qm = o + dir * tm;
                if (qm.y + U.cam.y < F0.sample(fieldS, giFieldUV(qm, U, R), level(0.0)).x) tb = tm; else ta = tm;
            }
            t = tb; q = o + dir * t; fu = giFieldUV(q, U, R);
            float tx = 1.0 / R.field.w;
            float hl = F0.sample(fieldS, fu - float2(tx, 0.0), level(0.0)).x, hr = F0.sample(fieldS, fu + float2(tx, 0.0), level(0.0)).x;
            float hd = F0.sample(fieldS, fu - float2(0.0, tx), level(0.0)).x, hu = F0.sample(fieldS, fu + float2(0.0, tx), level(0.0)).x;
            float3 Ng = normalize(float3(hl - hr, 2.0 * R.field.z, hd - hu));
            float yy = q.y + U.cam.y;
            float3 alb = f.w > 0.0 ? float3(0.06, 0.065, 0.03) : float3(0.11, 0.15, 0.045);
            alb = mix(alb, float3(0.2, 0.16, 0.085), U.seasonB.z * 0.6);
            alb = mix(alb, float3(0.3, 0.28, 0.25), smoothstep(0.82, 0.65, Ng.y));
            alb = mix(alb, float3(0.08, 0.07, 0.055), smoothstep(0.4, 0.0, yy - WATER));
            alb = mix(alb, SNOW, U.seasonA.x * smoothstep(0.6, 0.8, Ng.y) * 0.8);
            alb *= 1.0 - 0.3 * U.seasonC.z;
            float sh = shadowAt(q, Ng, U, S, true);
            float3 amb = ambient(Ng, U);
            float4 e = giIrradiance(giWorld(q, U), q, Ng, V, gi0, gi1, gi2, gi3);
            amb = mix(amb, e.rgb * V.horizon.w, e.a);
            float3 c = alb * (U.sunCol.rgb * U.sun.w * max(dot(Ng, U.sun.xyz), 0.0) * sh + amb);
            rad += Tl * applyMist(c, dir * t, U);
            Tl = 0.0; ended = true; break;
        }
        if (f.x < WATER - 0.1 && y < WATER) {
            // the river: mostly the sky it mirrors
            float F = 0.02 + 0.98 * pow(1.0 - abs(dir.y), 5.0);
            float3 c = giSkyF(reflect(dir, float3(0, 1, 0)), U) * F + float3(0.01, 0.012, 0.01) * (1.0 - F);
            rad += Tl * applyMist(c, dir * t, U);
            Tl = 0.0; ended = true; break;
        }
        float dt;
        if (f.w > 0.0 && y > f.y && y < f.z && t > 0.5) {     // (crowns have gaps: a leaf's own surroundings don't count)
            // inside a crown: leaves lit by the sun (shadow map) and the sky above them, glowing with their band
            dt = 0.3 + 0.015 * t;
            float4 f1 = F1.sample(fieldS, fu, level(0.0));
            float a = 1.0 - exp(-f.w * dt);
            float sh = shadowAt(q, float3(0.0, 1.0, 0.0), U, S, true);
            float skyV = exp(-f.w * 0.6 * (f.z - y));
            float3 Ll = f1.rgb * (U.sunCol.rgb * U.sun.w * 0.7 * sh + ambient(float3(0.0, 1.0, 0.0), U) * (0.3 + 0.7 * skyV))
                      + f1.rgb * U.sunCol.rgb * f1.a * 2.5 * (0.4 + 0.6 * sh);
            rad += Tl * a * applyMist(Ll, dir * t, U);
            Tl *= 1.0 - a;
            if (Tl * P[ci] < 0.02) { Tl = 0.0; ended = true; break; }
        } else {
            float top = f.w > 0.0 ? f.z : f.x;
            float clear = y > top ? y - top : (f.w > 0.0 && y < f.y ? min(y - f.x, f.y - y) : y - f.x);
            dt = clamp(clear * 0.6, 0.25 + 0.015 * t, 3.0 + 0.04 * t);
        }
        if (ci < 3 && t < bnd[ci]) dt = min(dt, bnd[ci] - t + 0.01);   // short intervals near the surface: don't skip them
        dtPrev = dt;
        t += dt;
    }
    if (ended) {
        iv[ci] = float4(rad, 0.0);
        n = ci + 1;
    } else {
        // out into the sky (or out of the field / steps): the rest belongs to the top cascade
        while (ci < 3) { iv[ci] = float4(rad, Tl); P[ci + 1] = P[ci] * Tl; ci++; rad = float3(0.0); Tl = 1.0; }
        iv[3] = float4(rad + Tl * giSkyF(dir, U), 0.0);
        n = 4;
    }
    return true;
}

kernel void giForestTrace(uint2 gid [[thread_position_in_grid]], uint lane [[thread_index_in_simdgroup]],
                          constant GIView& V [[buffer(0)]], GI_BUF_PARAMS,
                          constant ForestU& U [[buffer(10)]], constant GIForestR& R [[buffer(11)]],
                          depth2d<float> depth [[texture(0)]], texture2d<float> T [[texture(1)]],
                          depth2d_array<float> S [[texture(2)]], texture2d<float> F0 [[texture(3)]], texture2d<float> F1 [[texture(4)]],
                          texture3d<float> gi0 [[texture(5)]], texture3d<float> gi1 [[texture(6)]],
                          texture3d<float> gi2 [[texture(7)]], texture3d<float> gi3 [[texture(8)]]) {
    float3 rel = float3(0.0), dir = float3(0.0, 1.0, 0.0);
    int L = 0, n = 0;
    float4 iv[4]; float P[4];
    bool ok = giForestRay(gid, V, U, R, depth, T, S, F0, F1, gi0, gi1, gi2, gi3, rel, L, dir, iv, P, n);
    giSplatSimd(GI_BUFS, ok, giWorld(rel, U), int3(0), L, dir, iv, P, n, uint(V.anchor.w), lane);
}
"""#
