// MSL for the Landscape's City scene (CityGPU), compiled at runtime into its own library.
// One full-screen pass ray-traces an endless night city: rays walk a 2D grid of 16 m lots (DDA), every lot holds one
// building of up to three stacked boxes (+ a spire) defined by hashes of its world cell, so the hit is exact and the
// same walk gives real shadows from any light (light drones, lightning). Blocks are 4 × 4 lots with a 16 m street
// between them. Positions are relative to the camera's cell (`U.cell`), so floats stay small however far it flies.
let cityShaderSource = #"""
#include <metal_stdlib>
using namespace metal;

// Must match CityUniforms in CityGPU.swift.
struct CityU {
    float4 right;      // xyz, w = tan(fov x / 2)
    float4 up;         // xyz, w = tan(fov y / 2)
    float4 fwd;        // xyz, w = radians per pixel
    float4 cam;        // camera position relative to its cell's corner, time
    int4 cell;         // camera cell (x, z) in lots
    float4 cfg;        // towers, wet, traffic, haze
    float4 cfg2;       // band light, drones, beams, palette tint
    float4 music;      // bass, mid, treble shimmer, beat
    float4 music2;     // level, kick flash, crown pulse, share of lit windows (loudness)
    float4 traffic;    // lane offsets (mod 3072 m): +z lanes, −z lanes, +x lanes, −x lanes
    float4 flash;      // lightning direction, intensity
    float4 colA;       // palette colours (neon, drones, meters)
    float4 colB;
    float4 colC;       // haze / window tint colour, w = exposure
    float4 bands[2];   // 8 band levels
    float4 cfg3;       // gloom, debug, window reflections, reflection blur
};
// light buffer: [0..3] kick waves (x, z, radius, strength), [4..23] drones incl. fly-bys (pos, radius ; colour, intensity),
// [24..31] searchlights (origin, width ; direction, intensity). Keep CityGPU.lightCount / CityViz.maxDrones in step.
constant int WAVES = 0, DRONES = 4, BEAMS = 24;

constant float C = 16.0;              // lot size (m)
constant int PER = 5;                 // lots per block period: 4 lots + 1 street

struct VOut { float4 pos [[position]]; float2 uv; };
vertex VOut cityVert(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2) * 2.0 - 1.0;
    VOut o; o.pos = float4(p, 0.0, 1.0); o.uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5); return o;
}

static uint hashI(int2 c, uint s) {
    uint h = uint(c.x) * 0x8da6b343u + uint(c.y) * 0xd8163841u + s * 0x9e3779b9u;
    h = (h ^ (h >> 16)) * 0x7feb352du;
    h ^= h >> 15;
    return h;
}
static float h01(int2 c, uint s) { return float(hashI(c, s) & 0xffffffu) / 16777216.0; }
static int fdiv(int a, int b) { return (a >= 0 ? a : a - b + 1) / b; }
/// Block of a world cell (floor(c / 5)) without integer division (slow on GPUs); exact for |c| < 2²².
static int2 blockOf(int2 c) { return int2(floor((float2(c) + 0.5) * (1.0 / float(PER)))); }
static float h11(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
static float vnoise(float2 p) {
    float2 i = floor(p), f = p - i; f = f * f * (3.0 - 2.0 * f);
    return mix(mix(h11(i), h11(i + float2(1, 0)), f.x), mix(h11(i + float2(0, 1)), h11(i + float2(1, 1)), f.x), f.y);
}

/// Downtown clusters: smooth noise over blocks (≈ 6 blocks across), 0…1.
static float district(int2 blk) {
    float2 p = float2(blk) / 6.0;
    int2 i = int2(floor(p)); float2 f = p - floor(p); f = f * f * (3.0 - 2.0 * f);
    float v = mix(mix(h01(i, 7), h01(i + int2(1, 0), 7), f.x), mix(h01(i + int2(0, 1), 7), h01(i + int2(1, 1), 7), f.x), f.y);
    return smoothstep(0.15, 0.95, v);
}

struct Bld {
    float4 fp;       // footprint (camera-cell relative metres): x0, z0, x1, z1
    float3 h;        // tops of the three stacked boxes (h.x ≤ h.y ≤ h.z)
    float2 inset;    // insets of box 1 and box 2
    float spire;     // spire top (0 = none)
    float top;       // highest point (< 0 = empty lot)
    int2 owner;      // world cell whose hashes define the building
    float id, style;
    int band;
};

static float maxHeight(float towers) { return 30.0 + 330.0 * (0.3 + 1.2 * towers) + 60.0; }

/// The highest any building of a block with district value D can reach.
static float blockBound(float D, float towers) {
    float tf = 0.3 + 1.2 * towers;
    return max(18.0 + (20.0 + 300.0 * D * D) * tf + 47.0, 5.0 + (6.0 + 40.0 * D) * (0.5 + 0.5 * tf)) + 0.5;
}

/// The building standing on lot `rc` (relative to the camera cell). Streets and parks: top < 0.
/// Only the geometry; `bldLook` adds id / style / band for shading.
static Bld building(int2 rc, constant CityU& U, thread int2& lastBlk, thread float& lastD) {
    Bld b; b.top = -1.0;
    int2 wc = U.cell.xy + rc;
    int2 blk = blockOf(wc);
    int2 k = wc - blk * PER;
    if (k.x == PER - 1 || k.y == PER - 1) return b;           // street
    if (any(blk != lastBlk)) { lastBlk = blk; lastD = district(blk); }
    float D = lastD;
    int2 qo = blk * PER + (k / 2) * 2;                          // the 2 × 2 lot quadrant
    bool merged = h01(qo, 11) < 0.2 + 0.55 * D;
    int2 owner = merged ? qo : wc;
    float r1 = h01(owner, 1), r4 = h01(owner, 4);
    if (!merged && r4 < 0.05) return b;                         // a small park
    float r2 = h01(owner, 2), r3 = h01(owner, 3);
    float size = merged ? 2.0 * C : C;
    float2 o = float2(owner - U.cell.xy) * C;
    float m = merged ? 1.5 + 2.5 * r2 : 0.8 + 1.6 * r2;
    b.fp = float4(o.x + m, o.y + m, o.x + size - m, o.y + size - m);
    float tf = 0.3 + 1.2 * U.cfg.x;
    float hgt = merged ? 18.0 + (20.0 + 300.0 * D * D) * (0.35 + 0.65 * r1 * r1) * tf
                       : 5.0 + (6.0 + 40.0 * D) * r1 * (0.5 + 0.5 * tf);
    if (hgt > 45.0) {
        b.h = float3(hgt * (0.22 + 0.3 * r3), hgt * (0.6 + 0.25 * r2), hgt);
        b.inset = size * float2(0.07 + 0.05 * r3, 0.14 + 0.08 * r1);
    } else {
        b.h = float3(hgt); b.inset = float2(0.0);
    }
    b.spire = merged && hgt > 110.0 && r4 < 0.45 ? hgt + 12.0 + 35.0 * r4 : 0.0;
    b.top = max(hgt, b.spire);
    b.owner = owner;
    return b;
}

static void bldLook(thread Bld& b) {
    b.id = h01(b.owner, 6); b.style = h01(b.owner, 8);
    b.band = int(h01(b.owner, 5) * 8.0) & 7;
}

struct Hit {
    float t;
    float3 n;
    int kind;        // 0 sky, 1 ground, 2 building
    int2 cell;
    float boxTop;    // top of the box that was hit
    float4 box;      // its footprint
};

static bool boxRay(float3 ro, float3 ird, float3 lo, float3 hi, thread float& tn, thread float3& n) {
    float3 a = (lo - ro) * ird, c = (hi - ro) * ird;
    float3 mn = min(a, c), mx = max(a, c);
    tn = max(max(mn.x, mn.y), mn.z);
    float tf = min(min(mx.x, mx.y), mx.z);
    if (tn > tf || tn < 1e-3) return false;
    n = mn.x >= tn ? float3(-sign(ird.x), 0, 0) : mn.z >= tn ? float3(0, 0, -sign(ird.z)) : float3(0, -sign(ird.y), 0);
    return true;
}

/// Tests the boxes of one building; returns the nearest hit before `tLim`.
static bool hitBld(Bld b, float3 ro, float3 ird, float tLim, thread Hit& h) {
    bool any = false;
    float tn; float3 n;
    float4 f = b.fp;
    for (int k = 0; k < 3; k++) {
        if (k > 0 && b.h[k] <= b.h[k - 1] + 0.01) continue;
        float s = k == 0 ? 0.0 : b.inset[k - 1];
        float4 g = f + float4(s, s, -s, -s);
        if (boxRay(ro, ird, float3(g.x, 0, g.y), float3(g.z, b.h[k], g.w), tn, n) && tn < tLim) {
            tLim = tn; any = true; h.t = tn; h.n = n; h.boxTop = b.h[k]; h.box = g;
        }
    }
    if (b.spire > 0.0) {
        float2 c = 0.5 * (f.xy + f.zw);
        if (boxRay(ro, ird, float3(c.x - 0.7, 0, c.y - 0.7), float3(c.x + 0.7, b.spire, c.y + 0.7), tn, n) && tn < tLim) {
            any = true; h.t = tn; h.n = n; h.boxTop = b.spire; h.box = float4(c - 0.7, c + 0.7);
        }
    }
    return any;
}

/// Street lamps: one on each side of every street, at each lot's middle. Returns the glow of the lamp heads of
/// street cell `rc` near the ray (for the primary ray).
static float lampHeads(int2 rc, constant CityU& U, float3 ro, float3 rd, float tEnd, float fp) {
    int2 wc = U.cell.xy + rc;
    int2 k = int2(wc.x - fdiv(wc.x, PER) * PER, wc.y - fdiv(wc.y, PER) * PER);
    float g = 0.0;
    float2 o = float2(rc) * C;
    for (int s = 0; s < 2; s++) {
        float3 L;
        if (k.x == PER - 1 && k.y != PER - 1) L = float3(o.x + (s == 0 ? 1.4 : C - 1.4), 7.5, o.y + 0.5 * C);
        else if (k.y == PER - 1 && k.x != PER - 1) L = float3(o.x + 0.5 * C, 7.5, o.y + (s == 0 ? 1.4 : C - 1.4));
        else continue;
        float3 d = L - ro;
        float tc = clamp(dot(d, rd), 0.0, tEnd);
        float3 q = ro + rd * tc - L;
        float r = 0.25 + fp * tc;
        g += 0.25 / (r * r) * exp(-dot(q, q) / (r * r) * 3.0) * min(1.0, 0.0625 / (r * r) * 4.0);
    }
    return g;
}

/// Grid walk state: the cell, the distances to the next x / z cell boundary, and the block being crossed.
struct Walk {
    int2 c; int2 st; float2 tNext, tDelta;
    int2 blk; float tBlk; float hBlk;      // current block, where the ray leaves it, its height bound
};

static void walkInit(thread Walk& w, float3 ro, float3 rd, float3 ird, float t) {
    float2 q = ro.xz + rd.xz * t;
    w.c = int2(floor(q / C));
    w.st = int2(rd.x >= 0.0 ? 1 : -1, rd.z >= 0.0 ? 1 : -1);
    w.tDelta = abs(C * ird.xz);
    w.tNext = (float2(w.c + max(w.st, int2(0))) * C - ro.xz) * ird.xz;
    w.blk = int2(1 << 30);
}

/// Called when the walk may have entered a new block: its bound and exit distance. Returns true if the ray stays
/// above everything in the block (between t0 and the block's exit, or `tStop`), so the whole block can be skipped.
static bool blockAbove(thread Walk& w, float3 ro, float3 rd, float3 ird, float t0, float tStop, constant CityU& U,
                       thread int2& lb, thread float& lD) {
    int2 wc = U.cell.xy + w.c;
    int2 blk = blockOf(wc);
    if (all(blk == w.blk)) return false;
    w.blk = blk;
    if (any(blk != lb)) { lb = blk; lD = district(blk); }
    w.hBlk = blockBound(lD, U.cfg.x);
    float2 lo = float2(blk * PER - U.cell.xy) * C, hi = lo + float(PER) * C;
    float2 te = (select(lo, hi, rd.xz >= 0.0) - ro.xz) * ird.xz;
    w.tBlk = min(te.x, te.y);
    float yLow = ro.y + rd.y * (rd.y < 0.0 ? min(w.tBlk, tStop) : t0);
    return yLow > w.hBlk;
}

/// Walks the lot grid. `lamps` accumulates the glow of street lamp heads passed on the way (primary ray only).
static Hit trace(float3 ro, float3 rd, int maxSteps, float tMax, constant CityU& U, bool wantLamps, thread float& lamps, float fpAng) {
    Hit h; h.kind = 0; h.t = tMax; h.n = float3(0, 1, 0); h.cell = int2(0); h.boxTop = 0; h.box = float4(0);
    float3 ird = 1.0 / float3(abs(rd.x) < 1e-6 ? 1e-6 : rd.x, abs(rd.y) < 1e-6 ? 1e-6 : rd.y, abs(rd.z) < 1e-6 ? 1e-6 : rd.z);
    float tg = rd.y < 0.0 ? -ro.y / rd.y : 1e9;
    float hMax = maxHeight(U.cfg.x);
    Walk w; walkInit(w, ro, rd, ird, 0.0);
    float t0 = 0.0;
    int2 lb = int2(1 << 30); float lD = 0.0;
    for (int i = 0; i < maxSteps; i++) {
        if (blockAbove(w, ro, rd, ird, t0, tg, U, lb, lD)) {
            // over the whole block: jump to where the ray leaves it
            t0 = w.tBlk;
            if (t0 > tMax || (rd.y >= 0.0 && ro.y + rd.y * t0 > hMax)) break;
            walkInit(w, ro, rd, ird, t0 + 1e-3);
            continue;
        }
        float t1 = min(w.tNext.x, w.tNext.y);
        float yLow = ro.y + rd.y * (rd.y < 0.0 ? min(t1, tg) : t0);
        Bld b = building(w.c, U, lb, lD);
        if (b.top > 0.0) {
            if (yLow < b.top) {
                Hit bh;
                if (hitBld(b, ro, ird, min(t1, tg) + 1e-3, bh)) { bh.kind = 2; bh.cell = w.c; return bh; }
            }
        } else if (wantLamps && t0 < 400.0 && yLow < 12.0) {
            lamps += lampHeads(w.c, U, ro, rd, min(t1, tg), fpAng);
        }
        if (tg <= t1) { h.kind = 1; h.t = tg; h.cell = w.c; h.n = float3(0, 1, 0); return h; }
        if (rd.y >= 0.0 && ro.y + rd.y * t1 > hMax) break;
        if (t1 > tMax) break;
        t0 = t1;
        if (w.tNext.x < w.tNext.y) { w.tNext.x += w.tDelta.x; w.c.x += w.st.x; } else { w.tNext.y += w.tDelta.y; w.c.y += w.st.y; }
    }
    return h;
}

/// 1 = the light at distance `dist` along `dir` reaches p, 0 = a building is in the way.
static float shadow(float3 ro, float3 rd, float dist, int maxSteps, constant CityU& U) {
    float3 ird = 1.0 / float3(abs(rd.x) < 1e-6 ? 1e-6 : rd.x, abs(rd.y) < 1e-6 ? 1e-6 : rd.y, abs(rd.z) < 1e-6 ? 1e-6 : rd.z);
    float hMax = maxHeight(U.cfg.x);
    Walk w; walkInit(w, ro, rd, ird, 0.0);
    float t0 = 0.0;
    int2 lb = int2(1 << 30); float lD = 0.0;
    for (int i = 0; i < maxSteps; i++) {
        if (blockAbove(w, ro, rd, ird, t0, dist, U, lb, lD)) {
            t0 = w.tBlk;
            if (t0 >= dist || (rd.y >= 0.0 && ro.y + rd.y * t0 > hMax)) return 1.0;
            walkInit(w, ro, rd, ird, t0 + 1e-3);
            continue;
        }
        float t1 = min(w.tNext.x, w.tNext.y);
        float yLow = ro.y + rd.y * (rd.y < 0.0 ? min(t1, dist) : t0);
        Bld b = building(w.c, U, lb, lD);
        if (b.top > yLow) {
            Hit bh;
            if (hitBld(b, ro, ird, min(t1, dist), bh)) return 0.0;
        }
        if (t1 >= dist) return 1.0;
        if (rd.y >= 0.0 && ro.y + rd.y * t1 > hMax) return 1.0;
        t0 = t1;
        if (w.tNext.x < w.tNext.y) { w.tNext.x += w.tDelta.x; w.c.x += w.st.x; } else { w.tNext.y += w.tDelta.y; w.c.y += w.st.y; }
    }
    return 1.0;
}

static float band(constant CityU& U, int i) { return U.bands[i >> 2][i & 3]; }
static float3 bandCol(constant CityU& U, int i) { return mix(U.colA.rgb, U.colB.rgb, float(i) / 7.0); }

/// The night sky: light pollution at the horizon, clouds lit from below, a few stars; lightning brightens it.
/// `stars` < 1 fades the stars (blurred reflections: jittered rays would pick single stars as speckles).
static float3 sky(float3 rd, constant CityU& U, float stars = 1.0) {
    float y = max(rd.y, 0.0);
    float3 pol = mix(float3(0.05, 0.028, 0.045), U.colC.rgb * 0.06, U.cfg2.w * 0.6);
    float3 c = mix(pol, float3(0.004, 0.004, 0.01), smoothstep(0.0, 0.35, y));
    float2 cp = rd.xz / max(rd.y, 0.04) * 1.3 + float2(U.cam.w * 0.01, 0.0);
    float gl = U.cfg3.x;
    float cl = smoothstep(0.45 - 0.4 * gl, 0.85 - 0.25 * gl, vnoise(cp) * 0.65 + vnoise(cp * 2.7) * 0.35);
    c += cl * (pol * (0.6 + 1.6 * gl) + float3(0.7, 0.75, 1.0) * U.flash.w * 0.6) * smoothstep(0.02, 0.15, y) * (1.0 - smoothstep(0.4, 0.9, y));
    float2 sp = floor(rd.xz / max(rd.y, 0.05) * 90.0);
    float s = h11(sp);
    c += step(0.995, s) * 0.5 * stars * smoothstep(0.2, 0.6, y) * (1.0 - cl) * (1.0 - gl);
    c += float3(0.12, 0.13, 0.18) * U.flash.w * (0.3 + 0.7 * y);
    return c;
}

/// The colour of the night haze (lit from below by the city).
static float3 fogTint(constant CityU& U) {
    float3 base = mix(float3(0.05, 0.03, 0.048), float3(0.026, 0.027, 0.032), U.cfg3.x);
    return mix(base, U.colC.rgb * 0.07, U.cfg2.w * 0.6);
}

/// Light on a surface from the street lamps of the nearest avenue and cross street (no shadows: they light the
/// street side of the buildings), the light drones (with shadows), lightning (with shadows) and the kick waves.
static float3 lighting(float3 p, float3 n, constant CityU& U, const device float4* L, bool cheap) {
    float3 acc = float3(0.0);
    if (U.cfg3.y == 2.0) return float3(0.05);
    float tint = U.cfg2.w;
    // lamps
    float3 lampCol = mix(float3(1.0, 0.62, 0.3), U.colC.rgb * 1.2, tint * 0.5);
    int2 wc = U.cell.xy + int2(floor(p.xz / C));
    for (int ax = 0; ax < 2; ax++) {
        int w = ax == 0 ? wc.x : wc.y;
        int blk = fdiv(w, PER);
        float pa = ax == 0 ? p.x : p.z;
        // the two streets around this block: columns blk*5 − 1 and blk*5 + 4; take the nearer one
        float s0 = (float(blk * PER - 1 - (ax == 0 ? U.cell.x : U.cell.y)) + 0.5) * C;
        float s1 = (float(blk * PER + PER - 1 - (ax == 0 ? U.cell.x : U.cell.y)) + 0.5) * C;
        float sc = abs(pa - s0) < abs(pa - s1) ? s0 : s1;
        if (abs(pa - sc) > 40.0) continue;
        float pb = ax == 0 ? p.z : p.x;
        float base = (floor(pb / C) + 0.5) * C;
        for (int side = 0; side < 2; side++) {
            for (int j = -1; j <= 1; j++) {
                float a = sc + (side == 0 ? -1.0 : 1.0) * (0.5 * C - 1.4);
                float b2 = base + float(j) * C;
                float3 lp = ax == 0 ? float3(a, 7.5, b2) : float3(b2, 7.5, a);
                float3 d = lp - p;
                float d2 = dot(d, d);
                if (d2 > 900.0) continue;
                float ndl = max(dot(n, d * rsqrt(d2)), 0.0);
                float f = 1.0 - d2 / 900.0;
                acc += lampCol * 9.0 * ndl * f * f / (d2 + 2.0);
            }
        }
    }
    // light drones
    int nd = int(U.cfg2.y);
    for (int i = 0; i < nd; i++) {
        float4 a = L[DRONES + 2 * i], b = L[DRONES + 2 * i + 1];
        float3 d = a.xyz - p;
        float d2 = dot(d, d);
        float R = a.w;
        if (d2 > R * R || b.w <= 0.0) continue;
        float dl = sqrt(d2);
        float ndl = dot(n, d / dl);
        if (ndl <= 0.0) continue;
        float f = 1.0 - d2 / (R * R);
        float3 c = b.rgb * b.w * 2.5 * ndl * f * f / (d2 + 6.0);
        if (max(c.r, max(c.g, c.b)) < 0.004) continue;
        float sh = cheap ? 1.0 : shadow(p + n * 0.05, d / dl, dl, 24, U);
        acc += c * sh;
    }
    // lightning
    if (U.flash.w > 0.01) {
        float ndl = dot(n, U.flash.xyz);
        if (ndl > 0.0) {
            float sh = cheap ? 1.0 : shadow(p + n * 0.05, U.flash.xyz, 3000.0, 48, U);
            acc += float3(0.75, 0.8, 1.0) * 1.6 * U.flash.w * ndl * sh;
        }
    }
    // kick waves: a ring of light running along the ground lights the lower facades
    for (int i = 0; i < 4; i++) {
        float4 w = L[WAVES + i];
        if (w.w <= 0.0) continue;
        float dh = length(p.xz - w.xy);
        float r = (dh - w.z) / 6.0;
        acc += mix(U.colA.rgb, U.colB.rgb, float(i) / 3.0) * w.w * 1.2 * exp(-r * r) * exp(-p.y / 9.0) * (0.4 + 0.6 * max(-dot(n.xz, normalize(p.xz - w.xy + 1e-4)), 0.0) + n.y);
    }
    // night sky light
    acc += float3(0.006, 0.006, 0.011) * (0.6 + 0.4 * n.y);
    return acc;
}

/// How a building's facade is made, from hashes of its owner cell: window type (portrait / landscape / square /
/// curtain wall), bay and floor size, frames and mullions, solid piers, mechanical floors, shop fronts, wall
/// material and glass tint.
struct Look {
    int kind;        // 0 portrait, 1 landscape, 2 square, 3 curtain wall
    int nb;          // bays per 16 m lot
    float fh;        // floor height
    float mu, sill, head;  // window margins as fractions of the bay / floor
    int mull;        // 0 none, 1 centre bar, 2 three panes, 3 cross
    int pier;        // every pier-th bay is solid (0 = none)
    int mech;        // every mech-th floor is a louvred plant floor (0 = none)
    float slab;      // how much the floor slab / spandrel band stands out
    float shop;      // shop front height at the bottom (0 = none)
    float3 wall;     // wall albedo
    float3 tint;     // glass reflection tint
    float refl;      // how mirror-like its glass is
};

static Look lookOf(Bld b) {
    Look k;
    float r1 = h01(b.owner, 21), r2 = h01(b.owner, 22), r3 = h01(b.owner, 23), r4 = h01(b.owner, 24), r5 = h01(b.owner, 25);
    k.pier = 0; k.mech = 0; k.mull = 0;
    if (b.style > 0.62) {
        k.kind = 3;
        k.nb = r1 < 0.4 ? 30 : (r1 < 0.75 ? 24 : 20);
        k.fh = 3.3 + 0.6 * r2;
        k.mu = 0.05; k.sill = 0.18 + 0.1 * r3; k.head = 0.06;
        k.slab = 0.4 + 0.5 * r4;
        k.mech = b.top > 120.0 ? 12 + int(r5 * 10.0) : 0;
        k.wall = float3(0.05, 0.058, 0.072) * (0.8 + 0.5 * r2);
        k.tint = r3 < 0.35 ? float3(0.65, 0.82, 1.0) : (r3 < 0.55 ? float3(1.0, 0.8, 0.55) : (r3 < 0.7 ? float3(0.7, 1.0, 0.85) : float3(0.9, 0.92, 0.95)));
        k.refl = 0.85 + 0.15 * r5;
    } else {
        float kt = h01(b.owner, 9);
        if (kt < 0.45) {            // portrait: narrow, tall punched windows
            k.kind = 0; k.nb = 10 + int(r1 * 4.0);
            k.fh = 2.6 + 0.4 * r2;
            k.mu = 0.2 + 0.08 * r3; k.sill = 0.24 + 0.08 * r4; k.head = 0.1 + 0.05 * r2;
            k.mull = r5 < 0.35 ? 1 : (r5 < 0.5 ? 3 : 0);
            k.slab = 0.15 * r4;
        } else if (kt < 0.8) {      // landscape: wide, low windows, often split into panes
            k.kind = 1; k.nb = 5 + int(r1 * 3.0);
            k.fh = 2.9 + 0.5 * r2;
            k.mu = 0.05 + 0.05 * r3; k.sill = 0.34 + 0.08 * r4; k.head = 0.18 + 0.06 * r2;
            k.mull = r5 < 0.5 ? 2 : (r5 < 0.75 ? 1 : 0);
            k.slab = 0.3 + 0.5 * r4;
        } else {                    // square
            k.kind = 2; k.nb = 7 + int(r1 * 3.0);
            k.fh = 2.7 + 0.3 * r2;
            k.mu = 0.16 + 0.06 * r3; k.sill = 0.24 + 0.06 * r4; k.head = 0.2;
            k.mull = r5 < 0.3 ? 3 : 0;
            k.slab = 0.1;
        }
        k.pier = r4 < 0.35 ? 3 + int(r2 * 3.0) : 0;
        k.mech = b.top > 150.0 && r3 < 0.5 ? 16 + int(r5 * 8.0) : 0;
        float m = h01(b.owner, 26);
        k.wall = m < 0.3 ? float3(0.13, 0.068, 0.05) : (m < 0.6 ? float3(0.11, 0.105, 0.1) : (m < 0.8 ? float3(0.16, 0.15, 0.135) : float3(0.06, 0.06, 0.066)));
        k.wall *= 0.8 + 0.4 * fract(b.id * 31.7);
        k.tint = float3(0.9, 0.93, 1.0);
        k.refl = k.kind == 1 ? 0.75 : 0.55;
    }
    k.shop = h01(b.owner, 27) < 0.7 ? 4.2 + 1.3 * h01(b.owner, 28) : 0.0;
    return k;
}

static float lineMask(float d, float w, float a) { return 1.0 - smoothstep(w - a, w + a, d); }

/// Windows (and neon, crowns, shop fronts) of a building facade: emission. `fp` = metres per pixel (antialiasing:
/// fine window grids fade to their average). Outputs: `glass` = how much of the pixel is reflecting glass, `spill`
/// = average window light (bounce), `wallMul` = albedo detail, `jit` = the pane's small tilt (broken-up mirror).
static float3 facade(float3 p, float3 n, Hit h, Bld b, Look k, constant CityU& U, float fp,
                     thread float& glass, thread float3& spill, thread float& wallMul, thread float2& jit) {
    bool xFace = abs(n.x) > 0.5;
    float uRel = xFace ? p.z : p.x;
    int cellU = xFace ? U.cell.y : U.cell.x;
    bool curtain = k.kind == 3;
    float bay = C / float(k.nb);
    float cu = uRel / bay;
    int colL = int(floor(cu)) + cellU * k.nb;
    int col = colL + (xFace ? 7919 : 0) + (n.x + n.z > 0.0 ? 104729 : 0);
    float yy = p.y - k.shop;
    int row = int(floor(yy / k.fh));
    float fu = fract(cu), fv = fract(yy / k.fh);
    float aa = fp / bay, aav = fp / k.fh;
    float lvl = band(U, b.band);
    float frac = p.y / max(b.top, 1.0);
    float meter = min(1.0, U.cfg2.x * 1.4) * sqrt(U.music2.w) * (1.0 - smoothstep(lvl * 1.1 - 0.04, lvl * 1.1, frac)) * min(1.0, lvl * 3.0);
    float occ = (curtain ? 0.22 : 0.3) * (1.0 - 0.35 * U.cfg3.x) * U.music2.w;   // music2.w: loudness → share of lit windows
    float tint = U.cfg2.w;
    float3 warm = mix(float3(1.0, 0.55, 0.22), U.colC.rgb, tint * 0.4);
    float3 cool = mix(float3(0.45, 0.7, 1.0), U.colC.rgb, tint * 0.4);
    float3 bc = bandCol(U, b.band);
    float far = smoothstep(0.2, 0.7, max(aa, aav));
    wallMul = 1.0; jit = float2(0.0);
    float3 e = float3(0.0);

    // solid piers and plant floors
    bool pierBay = k.pier > 0 && (colL - k.pier * int(floor(float(colL) / float(k.pier)))) == 0;
    bool mech = k.mech > 0 && row > 0 && (row % k.mech) == k.mech - 1;
    float coverPier = k.pier > 0 ? 1.0 - 1.0 / float(k.pier) : 1.0;
    float coverMech = k.mech > 0 ? 1.0 - 1.0 / float(k.mech) : 1.0;
    // the window itself
    float wm = smoothstep(k.mu - aa, k.mu + aa, fu) * smoothstep(k.mu - aa, k.mu + aa, 1.0 - fu)
             * smoothstep(k.sill - aav, k.sill + aav, fv) * smoothstep(k.head - aav, k.head + aav, 1.0 - fv);
    if (pierBay || mech) wm = 0.0;
    // mullions / transoms: thin dark bars (6 cm) across the pane
    float mw = 0.03 / bay, mwv = 0.03 / k.fh;
    float bars = 0.0;
    if (k.mull == 1 || k.mull == 3) bars = max(bars, lineMask(abs(fu - 0.5), mw, aa));
    if (k.mull == 2) bars = max(bars, max(lineMask(abs(fu - (k.mu + (1.0 - 2.0 * k.mu) / 3.0)), mw, aa),
                                          lineMask(abs(fu - (1.0 - k.mu - (1.0 - 2.0 * k.mu) / 3.0)), mw, aa)));
    if (k.mull == 3) bars = max(bars, lineMask(abs(fv - (k.sill + 0.62 * (1.0 - k.sill - k.head))), mwv, aav));
    float pane = wm * (1.0 - bars);
    float wh = h01(int2(col, row), uint(b.id * 1000.0));
    float wh2 = h01(int2(col, row), 77u);
    float wh3 = h01(int2(col, row), 91u);
    // lights go on in zones (a flat, an office floor): ~6 bays of one floor share a dark / normal / busy state
    float zf = h01(int2(int(floor(float(col) / 6.0)), row), uint(b.id * 997.0) + 57u);
    float occZ = min(0.95, occ * (zf < 0.35 ? 0.15 : (zf < 0.8 ? 1.0 : 2.4)));
    float lit = step(wh, occZ);
    float3 wc = mix(warm, cool, step(curtain ? 0.45 : 0.8, wh2));
    float bright = (0.22 + 0.6 * wh2 * wh2) * (1.0 - 0.25 * U.cfg3.x);
    // blinds: some lit windows are only lit below a pulled-down blind (the blind glows dimly)
    float wv = (fv - k.sill) / max(0.05, 1.0 - k.sill - k.head);
    float blind = wh3 < 0.35 ? 1.0 - smoothstep(0.25 + 0.6 * fract(wh3 * 7.0) - aav, 0.25 + 0.6 * fract(wh3 * 7.0) + aav, 1.0 - wv) : 0.0;
    float tw = step(0.93, fract(wh * 13.7)) * U.music.z * (0.5 + 0.5 * sin(U.cam.w * 23.0 + wh * 60.0));
    float litM = max(lit, step(wh, occZ + 0.12) * meter);
    float3 lc = mix(wc * bright, bc * (0.7 + bright), meter * 0.6);
    e = (lc * litM * (1.0 - 0.7 * blind) + bc * 0.9 * tw + float3(0.012, 0.014, 0.02) * (1.0 - litM)) * pane;
    // the average of the same, for windows smaller than a pixel or two
    float area = (1.0 - 2.0 * k.mu) * (1.0 - k.sill - k.head) * coverPier * coverMech * (k.mull > 0 ? 0.95 : 1.0);
    float3 avg = (mix(mix(warm, cool, curtain ? 0.55 : 0.2) * 0.45, bc * 0.95, meter * 0.6) * (occ + 0.12 * meter) * 0.88
                + bc * 0.9 * 0.07 * U.music.z * 0.5) * area;
    spill = avg;
    // bays too small to see but floors still visible: each floor's zone at its average (keeps the floor striping)
    float farU = smoothstep(0.2, 0.7, aa), farV = smoothstep(0.2, 0.7, aav);
    float wmV = (pierBay && k.pier > 0 ? 0.0 : 1.0) * (mech ? 0.0 : 1.0)
              * smoothstep(k.sill - aav, k.sill + aav, fv) * smoothstep(k.head - aav, k.head + aav, 1.0 - fv);
    float3 eRow = mix(mix(warm, cool, curtain ? 0.55 : 0.2) * 0.45, bc * 0.95, meter * 0.6) * (occZ + 0.12 * meter) * 0.88
                * (1.0 - 2.0 * k.mu) * wmV + float3(0.012, 0.014, 0.02) * (1.0 - 2.0 * k.mu) * wmV * (1.0 - occZ);
    e = mix(mix(e, eRow, farU), avg, farV);
    // glass: unlit panes mirror fully, lit ones (light from inside) less; a curtain wall's spandrels are glass too
    float g = pane * (1.0 - 0.6 * litM);
    if (curtain && !mech) g = max(g, 0.75 * (1.0 - bars) * smoothstep(k.mu - aa, k.mu + aa, fu) * smoothstep(k.mu - aa, k.mu + aa, 1.0 - fu));
    float gAvg = curtain ? 0.75 + 0.15 * area : area * (1.0 - 0.6 * occ);
    glass = mix(g, gAvg, far);
    // every pane sits a little differently: the mirror image breaks up from pane to pane
    jit = (float2(h01(int2(col, row), 93u), h01(int2(col, row), 94u)) - 0.5) * (curtain ? 0.035 : 0.05) * (1.0 - far);
    // wall detail: the floor slab / spandrel band, a frame around punched windows, louvres on plant floors
    float slabB = 1.0 - smoothstep(0.0, 0.35 * k.sill + aav, fv);
    float frame = curtain ? 0.0 : max(0.0, smoothstep(k.mu - 0.06 / bay - aa, k.mu - aa, fu) * smoothstep(k.mu - 0.06 / bay - aa, k.mu - aa, 1.0 - fu)
                  * smoothstep(k.sill - 0.08 / k.fh - aav, k.sill - aav, fv) * smoothstep(k.head - 0.06 / k.fh - aav, k.head - aav, 1.0 - fv) - wm);
    float louv = mech ? 0.5 + 0.5 * mix(sin(p.y * 2.0 * M_PI_F / 0.3), 0.0, smoothstep(0.1, 0.3, aav * k.fh / 0.3)) : 0.0;
    wallMul = mix(1.0 + k.slab * slabB * (1.0 - wm) + 0.6 * frame + 0.5 * louv, 1.0 + 0.3 * k.slab * k.sill, far);

    // shop fronts on the ground floor: big lit windows, a sign band above them, piers between the shops
    if (k.shop > 0.0 && p.y < k.shop && b.h.x >= k.shop) {
        float ns = h01(b.owner, 29) < 0.5 ? 2.0 : 3.0;
        float sw = C / ns;
        float su = uRel / sw;
        int si = int(floor(su)) + cellU * 3 + (xFace ? 5003 : 0);
        float fs = fract(su);
        float sh = h01(int2(si, 0), 41u), sh2 = h01(int2(si, 0), 42u);
        float pa = 0.25 / sw, pa2 = fp / sw;
        float win = smoothstep(pa - pa2, pa + pa2, fs) * smoothstep(pa - pa2, pa + pa2, 1.0 - fs)
            * smoothstep(0.3 - fp, 0.3 + fp, p.y) * (1.0 - smoothstep(k.shop - 1.1 - fp, k.shop - 1.1 + fp, p.y));
        float sign = smoothstep(pa - pa2, pa + pa2, fs) * smoothstep(pa - pa2, pa + pa2, 1.0 - fs)
                   * smoothstep(k.shop - 0.95 - fp, k.shop - 0.95 + fp, p.y) * (1.0 - smoothstep(k.shop - 0.35 - fp, k.shop - 0.35 + fp, p.y));
        float open = step(sh, 0.55 * U.music2.w);
        float3 shopC = sh2 < 0.5 ? float3(1.0, 0.75, 0.45) : (sh2 < 0.8 ? float3(0.85, 0.92, 1.0) : mix(U.colA.rgb, U.colB.rgb, sh));
        // inside: ceiling lights (bright under the ceiling, dim at the floor), shelves / counters as dark bands
        float sy = (p.y - 0.3) / max(0.5, k.shop - 1.4);
        float inside = 0.25 + 0.75 * sy * sy;
        float shelves = sy < 0.55 ? 0.55 + 0.45 * mix(step(0.5, fract(p.y / 0.55 + sh * 3.0)), 0.5, smoothstep(0.1, 0.25, fp)) : 1.0;
        float ceilL = 1.0 - smoothstep(0.0, 0.08 + fp, abs(sy - 0.97));
        // window bars every ~1.8 m and a door in the middle (its frame is a bar too)
        float xs = fs * sw;
        float nPanes = max(2.0, floor(sw / 1.8));
        float bar = lineMask(abs(fract(fs * nPanes + 0.5) - 0.5) * sw / nPanes, 0.05, fp);
        bar = max(bar, lineMask(abs(abs(xs - 0.5 * sw) - 0.75), 0.06, fp) * step(p.y, 2.5));
        bar = max(bar, lineMask(abs(p.y - 2.5), 0.05, fp));
        float pane2 = win * (1.0 - bar);
        float3 inC = shopC * (0.05 + 0.08 * sh2) * inside * shelves + shopC * 0.25 * ceilL;
        // closed shops: some have their rolling shutter down (grey slats lit by the street), others are just dark
        float shutter = (1.0 - open) * step(0.5, fract(sh * 9.1));
        e = inC * pane2 * open * (1.0 - 0.3 * U.cfg3.x) + float3(0.01, 0.012, 0.016) * pane2 * (1.0 - open) * (1.0 - shutter);
        float3 signC = mix(U.colA.rgb, U.colB.rgb, fract(sh * 5.3));
        e += signC * sign * step(0.45, sh2) * (0.25 + 0.8 * band(U, int(sh * 8.0) & 7));
        glass = pane2 * (1.0 - 0.6 * open) * (1.0 - shutter);
        jit = float2(0.0);
        float slats = 0.75 + 0.25 * mix(step(0.5, fract(p.y / 0.12)), 0.5, smoothstep(0.02, 0.06, fp));
        wallMul = mix(1.0 - 0.3 * win, 1.4 * slats, shutter * win);
        spill = shopC * 0.08 * open;
    }

    // crown light on tall buildings: the top of each tier glows, flashing on the beat
    if (b.top > 55.0 && h.boxTop >= b.h.z - 0.01 && fract(b.id * 7.3) < 0.55) {
        float d = h.boxTop - p.y;
        float cb = smoothstep(2.2 + fp, 2.2 - fp, d) * smoothstep(0.4 - fp, 0.4 + fp, d);
        float3 cc = b.id < 0.5 ? U.colA.rgb : (b.id < 0.8 ? U.colB.rgb : float3(1.0, 0.95, 0.9));
        e += cc * cb * (1.2 + 3.0 * U.music2.z * step(0.4, b.style));
    }
    float lo = xFace ? h.box.y : h.box.x, hi = xFace ? h.box.w : h.box.z;
    float dc = min(uRel - lo, hi - uRel);
    // neon edges on some buildings: the corners light up with the overall level
    if (b.style > 0.3 && b.style < 0.38) {
        float w = 0.35 + fp;
        e += bc * smoothstep(w, 0.0, dc) * (0.6 + 2.5 * U.music2.x);
    }
    // red aircraft warning lights at the top corners of tall towers, blinking slowly
    if (b.top > 80.0 && h.boxTop >= b.h.z - 0.01) {
        float d = h.boxTop - p.y;
        float r = 0.45 + fp;
        float spot = exp(-(dc * dc + (d - 0.6) * (d - 0.6)) / (r * r)) * min(1.0, 0.2 / (r * r));
        float blink = pow(max(0.0, sin(U.cam.w * 2.1 + b.id * 40.0)), 6.0);
        e += float3(1.0, 0.06, 0.03) * spot * (0.4 + 5.0 * blink);
    }
    // vertical blade sign on some mid-size buildings' corners
    if (k.shop > 0.0 && b.top > 20.0 && b.top < 90.0 && h01(b.owner, 30) < 0.25 && dc < 0.9 && p.y > k.shop && p.y < k.shop + 9.0) {
        float3 sc = mix(U.colA.rgb, U.colB.rgb, h01(b.owner, 31));
        float letters = step(0.35, fract((p.y - k.shop) / 0.9)) * step(0.15, dc) * step(dc, 0.75);
        e += sc * letters * (1.0 + 2.0 * band(U, b.band)) * (1.0 - far * 0.5);
    }
    // spire tip
    if (b.spire > 0.0 && h.boxTop == b.spire && p.y > b.spire - 6.0) e += float3(1.0, 0.25, 0.2) * (2.0 + 4.0 * U.music.w);
    return e;
}

/// Roofs: gravel with darker plant boxes, a lit parapet edge, skylights, the odd helipad ring.
static float3 roof(float3 p, Hit h, Bld b, constant CityU& U, float fp, thread float3& alb) {
    float3 e = float3(0.0);
    float2 q = p.xz;
    float dEdge = min(min(q.x - h.box.x, h.box.z - q.x), min(q.y - h.box.y, h.box.w - q.y));
    alb = float3(0.085, 0.085, 0.09) * (0.8 + 0.4 * fract(b.id * 13.1));
    // terraces (lower tiers) are sometimes gardens
    if (h.boxTop < b.h.z - 0.01 && fract(b.id * 3.7) < 0.4) alb = float3(0.04, 0.075, 0.04);
    // plant boxes on a 4 m grid
    float2 gc = floor(q / 4.0), gf = q / 4.0 - gc;
    float hb = h11(gc + float2(U.cell.xy) * 4.0);
    float boxM = step(hb, 0.3) * step(0.2, gf.x) * step(gf.x, 0.8) * step(0.25, gf.y) * step(gf.y, 0.75) * step(1.5, dEdge);
    alb = mix(alb, float3(0.05), boxM * (1.0 - smoothstep(0.1, 0.5, fp)));
    // skylights
    e += float3(1.0, 0.7, 0.4) * 0.15 * step(0.93, hb) * step(0.3, gf.x) * step(gf.x, 0.7) * step(0.3, gf.y) * step(gf.y, 0.7) * step(1.5, dEdge);
    // parapet
    alb = mix(alb, float3(0.14), 1.0 - smoothstep(0.3 - fp, 0.3 + fp, dEdge));
    // helipad on some tall towers
    if (b.top > 120.0 && h.boxTop >= b.h.z - 0.01 && b.id > 0.72) {
        float2 c = 0.5 * (h.box.xy + h.box.zw);
        float r = length(q - c);
        float ring = 1.0 - smoothstep(0.15 + fp, 0.15 + 2.0 * fp, abs(r - 6.0));
        e += mix(U.colA.rgb, float3(1.0), 0.4) * ring * (0.8 + 2.0 * U.music.w);
    }
    return e;
}

/// Cars: pairs of head lights (white, coming towards the camera's start) and tail lights (red) in four lanes per
/// street, as glowing spots on the road, stretched by speed (and towards the viewer when the street is wet).
static float3 traffic(float3 p, int2 k, float2 cellO, constant CityU& U, float fp, float3 rd) {
    float3 e = float3(0.0);
    float dens = U.cfg.z;
    if (dens <= 0.0) return e;
    float wet = U.cfg.y;
    for (int ax = 0; ax < 2; ax++) {
        bool along = ax == 0;                      // ax 0: avenue running in z (k.x == 4)
        if (along ? (k.x != PER - 1 || k.y == PER - 1) : (k.y != PER - 1 || k.x == PER - 1)) continue;
        float across = along ? p.x - cellO.x - 0.5 * C : p.z - cellO.y - 0.5 * C;
        float lenRel = along ? p.z : p.x;
        int street = along ? (U.cell.x + int(floor(p.x / C))) : (U.cell.y + int(floor(p.z / C)));
        for (int lane = 0; lane < 4; lane++) {
            float lc = float(lane) * 2.7 - 4.05;            // lanes at −4.05, −1.35, 1.35, 4.05
            if (abs(across - lc) > 1.6 + fp) continue;
            bool pos = lane >= 2;                           // direction of travel
            float base = along ? (pos ? U.traffic.x : U.traffic.y) : (pos ? U.traffic.z : U.traffic.w);
            float s = lenRel + base;
            float slot = floor(s / 14.0);
            for (int j = -1; j <= 1; j++) {
                float sl = slot + float(j);
                int si = int(sl - 256.0 * floor(sl / 256.0));
                float r = h01(int2(si, street * 4 + lane), 31u);
                if (r > dens * 0.85) continue;
                float carC = sl * 14.0 + 3.0 + 8.0 * fract(r * 17.0);
                float dirS = pos ? 1.0 : -1.0;
                for (int end = 0; end < 2; end++) {
                    // front (head lights) / back (tail lights)
                    float at = carC + (end == 0 ? 2.2 : -2.2) * dirS;
                    float3 lc3 = end == 0 ? float3(1.0, 0.92, 0.8) * 5.0 : float3(1.0, 0.08, 0.04) * 4.0;
                    for (int sd = -1; sd <= 1; sd += 2) {
                        float dl = (s - at), da = across - (lc + 0.75 * float(sd));
                        float sigL = 0.28 + 0.4 * U.music.y + fp * 0.6, sigA = 0.24 + fp * 0.6;
                        float norm = (0.28 * 0.24) / (sigL * sigA);
                        // wet: the reflection smears the light towards the viewer
                        float2 vd = normalize(rd.xz + 1e-4);
                        float vAlong = along ? vd.y : vd.x;
                        sigL += wet * 0.8 * abs(vAlong); sigA += wet * 0.8 * sqrt(max(0.0, 1.0 - vAlong * vAlong));
                        float g = exp(-(dl * dl) / (sigL * sigL) - (da * da) / (sigA * sigA));
                        e += lc3 * g * norm * (1.0 - 0.4 * wet);
                    }
                    // head light pool on the road ahead
                    if (end == 0) {
                        float dl = (s - (at + 5.0 * dirS)) / 5.0, da = (across - lc) / 1.6;
                        e += float3(1.0, 0.9, 0.75) * 0.05 * exp(-dl * dl - da * da);
                    }
                }
            }
        }
    }
    return e;
}

/// The ground: streets (asphalt, lane marks, cross walks, cars, lamp light pools), sidewalks, alleys and parks.
static float3 ground(float3 p, Hit h, float3 rd, constant CityU& U, const device float4* L, float fp, thread float& wetOut, bool cheap) {
    int2 wc = U.cell.xy + h.cell;
    int2 blk = blockOf(wc);
    int2 k = wc - blk * PER;
    float2 o = float2(h.cell) * C;
    float2 lp = p.xz - o;          // 0…16 inside the lot
    bool street = k.x == PER - 1 || k.y == PER - 1;
    float3 alb = float3(0.07, 0.068, 0.075);
    float3 e = float3(0.0);
    float wetMask = U.cfg.y * (0.3 + 0.7 * smoothstep(0.42, 0.62, vnoise(p.xz * 0.11) * 0.7 + vnoise(p.xz * 0.43) * 0.3));
    if (street) {
        // sidewalks along the blocks (2.5 m), the road in between
        float side = min(k.x == PER - 1 ? min(lp.x, C - lp.x) : 1e3, k.y == PER - 1 ? min(lp.y, C - lp.y) : 1e3);
        bool inter = k.x == PER - 1 && k.y == PER - 1;
        if (!inter && side < 2.5) { alb = float3(0.14, 0.135, 0.14); wetMask *= 0.6; }
        else {
            // lane marks: dashed lines between lanes, a double yellow line in the middle
            float across = k.x == PER - 1 ? lp.x : lp.y, along = k.x == PER - 1 ? p.z : p.x;
            if (!inter) {
                float mid = abs(across - 0.5 * C);
                float w = 0.08 + fp * 0.5;
                float dbl = smoothstep(w, 0.0, abs(mid - 0.15));
                float dash = smoothstep(w, 0.0, abs(mid - 2.7)) * step(0.5, fract(along / 6.0));
                e += float3(0.9, 0.7, 0.2) * dbl * 0.025 + float3(0.6) * dash * 0.02;
            } else {
                // cross walks just inside the intersection
                float2 q = lp;
                float edge = min(min(q.x, C - q.x), min(q.y, C - q.y));
                float stripes = step(0.5, fract((edge == min(q.x, C - q.x) ? q.y : q.x) / 1.0));
                if (edge < 2.4 && edge > 0.6) e += float3(0.7) * stripes * 0.018;
            }
            e += traffic(p, k, o, U, fp, rd);
        }
    } else {
        // alleys and parks (empty lots): a darker green park, concrete elsewhere
        float r4 = h01(wc, 4);
        alb = r4 < 0.05 ? float3(0.04, 0.08, 0.04) : float3(0.1, 0.1, 0.11);
    }
    wetOut = wetMask;
    // kick waves: rings of light running out along the streets
    for (int i = 0; i < 4; i++) {
        float4 w = L[WAVES + i];
        if (w.w <= 0.0) continue;
        float d = length(p.xz - w.xy);
        float r = (d - w.z) / (1.2 + 0.01 * w.z + fp);
        e += mix(U.colA.rgb, U.colB.rgb, float(i) / 3.0) * w.w * 0.9 * exp(-r * r) * (street ? 1.0 : 0.4);
    }
    float3 lit = lighting(p, float3(0, 1, 0), U, L, cheap);
    // bounce light from the lit facades down into the canyon; darker where the ground meets the walls
    float edge = street ? min(k.x == PER - 1 ? min(lp.x, C - lp.x) : 1e3, k.y == PER - 1 ? min(lp.y, C - lp.y) : 1e3) : 0.6;
    float ao = 0.45 + 0.55 * smoothstep(0.0, 4.0, edge);
    lit += (float3(0.03, 0.024, 0.02) + fogTint(U) * 0.15) * (0.5 + U.cfg3.x) * ao;
    return alb * (1.0 - 0.5 * wetMask) * lit * ao + e;
}

/// Glow of the drones and searchlights along a ray up to `tEnd` (cores + their halo in the haze).
static float3 rayGlow(float3 ro, float3 rd, float tEnd, constant CityU& U, const device float4* L, float fpAng) {
    float3 g = float3(0.0);
    float haze = U.cfg.w;
    int nd = int(U.cfg2.y);
    for (int i = 0; i < nd; i++) {
        float4 a = L[DRONES + 2 * i], b = L[DRONES + 2 * i + 1];
        if (b.w <= 0.0) continue;
        float3 d = a.xyz - ro;
        float bb = dot(d, rd);
        float h2 = max(dot(d, d) - bb * bb, 1e-4);
        float hh = sqrt(h2);
        // core (only if in front of the surface)
        if (bb > 0.0 && bb < tEnd) {
            float r = 0.9 + fpAng * bb;
            g += b.rgb * b.w * 0.02 * exp(-h2 / (r * r)) * min(1.0, 0.81 / (r * r));
        }
        // in-scattering in the haze: ∫ 1 / (h² + (t − b)²) dt from 0 to tEnd
        float sc = (atan((tEnd - bb) / hh) - atan(-bb / hh)) / hh;
        g += b.rgb * b.w * sc * (0.00005 + 0.0003 * haze) * (1.0 + 1.5 * U.cfg3.x);
    }
    int nb = int(U.cfg2.z);
    for (int i = 0; i < nb; i++) {
        float4 a = L[BEAMS + 2 * i], b = L[BEAMS + 2 * i + 1];
        if (b.w <= 0.0) continue;
        // closest approach of the ray (0…tEnd) and the beam (s ≥ 0)
        float3 w0 = ro - a.xyz;
        float A = dot(rd, rd), B = dot(rd, b.xyz), Cc = dot(b.xyz, b.xyz), D = dot(rd, w0), E = dot(b.xyz, w0);
        float den = max(A * Cc - B * B, 1e-5);
        float t = (B * E - Cc * D) / den;
        if (t < 0.0 || t > tEnd) continue;           // the beam's nearest point is behind the camera or a building
        float s = max(0.0, dot(ro + rd * t - a.xyz, b.xyz));
        float3 q = ro + rd * t - (a.xyz + b.xyz * s);
        float wdt = a.w + 0.045 * s;
        float along = sqrt(max(1.0 - B * B, 0.02));   // looking along the beam: brighter (longer path through it)
        g += mix(float3(0.85, 0.9, 1.0), U.colA.rgb, 0.3) * b.w * (0.02 + 0.06 * haze) * exp(-dot(q, q) / (wdt * wdt))
           * exp(-s / 900.0) / along * min(1.0, a.w * 3.0 / wdt);
    }
    return g;
}

static float3 aces(float3 x) { return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0); }

fragment float4 cityFrag(VOut in [[stage_in]], constant CityU& U [[buffer(0)]], const device float4* L [[buffer(1)]]) {
    float2 ndc = float2(in.uv.x * 2.0 - 1.0, 1.0 - in.uv.y * 2.0);
    float3 rd = normalize(U.fwd.xyz + U.right.xyz * ndc.x * U.right.w + U.up.xyz * ndc.y * U.up.w);
    float3 ro = U.cam.xyz;
    float fpAng = U.fwd.w;
    float haze = U.cfg.w;
    float lamps = 0.0;
    // stop the walk where the haze has (almost) hidden everything
    float densE = (0.00025 + 0.0022 * haze) * (1.0 + 4.0 * U.cfg3.x) * exp(-max(1.0, ro.y) / (260.0 + 200.0 * U.cfg3.x));
    float tFar = clamp(3.2 / densE, 400.0, 2600.0);
    Hit h = trace(ro, rd, 220, tFar, U, true, lamps, fpAng);
    if (U.cfg3.y == 1.0) return float4(float3(h.kind == 2 ? 0.5 : h.kind == 1 ? 0.2 : 0.0) * exp(-h.t / 500.0), 1.0);
    float3 col;
    float t = h.t;
    float3 p = ro + rd * t;
    float fp = t * fpAng;
    int2 lb = int2(1 << 30); float lD = 0.0;
    // one reflection ray, shared by window glass and wet streets
    float3 rW = float3(0.0);      // its weight (Fresnel × coverage × tint)
    float3 rO = float3(0.0), rD = float3(0.0, 1.0, 0.0);
    float rFp = 0.0, rMax = 700.0, rNear = 1e9, rCone = 0.0;
    int rSteps = 56;
    float gloom = U.cfg3.x;
    float reflAmt = U.cfg3.z;
    if (h.kind == 2) {
        Bld b = building(h.cell, U, lb, lD);
        bldLook(b);
        Look k = lookOf(b);
        float glass, wallMul;
        float3 spill;
        float2 jit;
        float3 alb;
        float3 e;
        bool isRoof = h.n.y > 0.5;
        if (isRoof) { e = roof(p, h, b, U, fp, alb); glass = 0.0; spill = float3(0.0); jit = float2(0.0); }
        else { e = facade(p, h.n, h, b, k, U, fp, glass, spill, wallMul, jit); alb = k.wall * wallMul; }
        float3 lit = lighting(p, h.n, U, L, false);
        // soft bounce light (a cheap stand-in for global illumination): light spilling out of the windows onto the
        // wall around them, the warm glow of the lit street rising up the lower floors, the haze's own glow
        float ao = 0.35 + 0.65 * smoothstep(0.0, 18.0, p.y);
        float3 streetGlow = mix(float3(1.0, 0.6, 0.32), U.colC.rgb, U.cfg2.w * 0.5) * 0.05 * exp(-p.y / 22.0);
        lit += (spill * 1.6 + streetGlow + fogTint(U) * 0.15) * (0.5 + gloom) * ao;
        col = alb * lit * (0.4 + 0.6 * smoothstep(0.0, 14.0, p.y)) + e;
        if (glass > 0.0) {
            // the glass mirrors the city: each pane tilted a little (jit) so the image breaks up like real glass
            float3 tU = abs(h.n.x) > 0.5 ? float3(0, 0, 1) : float3(1, 0, 0);
            // Reflection blur: everything the ray hits is shaded with a cone's footprint (window grids and lights fade to
            // soft averages), the panes tilt more, and a small per-pixel jitter softens the edges (a bigger one only
            // made speckles: one ray per pixel)
            float blur = U.cfg3.w;
            jit *= 1.0 + 2.5 * blur;
            float3 nP = normalize(h.n + tU * jit.x + float3(0, 1, 0) * jit.y);
            float3 r = reflect(rd, nP);
            if (blur > 0.0) {
                float2 q = in.pos.xy;
                float n1 = fract(52.9829189 * fract(dot(q, float2(0.06711056, 0.00583715))));
                float n2 = fract(52.9829189 * fract(dot(q + float2(17.0, 31.0), float2(0.06711056, 0.00583715))));
                float3 bU = normalize(cross(r, float3(0, 1, 0)) + float3(1e-4, 0, 0));
                float3 bV = cross(bU, r);
                float a = 6.2831853 * n1, rr = sqrt(n2) * 0.04 * blur;
                r = normalize(r + (bU * cos(a) + bV * sin(a)) * rr);
                rCone = 0.3 * blur;
            }
            float dn = dot(r, h.n);
            if (dn < 0.02) r = normalize(r + h.n * (0.02 - dn));
            float cosT = max(dot(-rd, nP), 0.0);
            float F0 = 0.04 + 0.4 * reflAmt * k.refl;
            float F = F0 + (1.0 - F0) * pow(1.0 - cosT, 5.0);
            if (reflAmt <= 0.0) {
                col += glass * F * sky(r, U) * 0.8;
            } else {
                rW = glass * F * k.tint * (0.5 + 0.9 * reflAmt);
                rO = p + h.n * 0.05; rD = r; rFp = t * fpAng; rMax = 350.0; rSteps = 18; rNear = 220.0;
            }
        }
    } else if (h.kind == 1) {
        float wet;
        col = ground(p, h, rd, U, L, fp, wet, false);
        if (wet > 0.01) {
            // wet streets: puddle ripples with the treble
            float2 rp = p.xz * 3.0 + float2(U.cam.w * 0.6, 0.0);
            float3 n = normalize(float3((vnoise(rp) - 0.5) * (0.01 + 0.04 * U.music.z), 1.0, (vnoise(rp + 17.0) - 0.5) * (0.01 + 0.04 * U.music.z)));
            float F = 0.04 + 0.96 * pow(1.0 - max(dot(-rd, n), 0.0), 5.0);
            rW = float3(wet * (0.12 + 0.88 * F));
            rO = p + float3(0, 0.02, 0); rD = reflect(rd, n); rFp = 10.0; rMax = 700.0; rSteps = 56;
        }
    } else {
        col = sky(rd, U);
    }
    float rWm = max(rW.r, max(rW.g, rW.b));
    if (rWm > 0.004) {
        // too faint or too far to be worth a ray: the sky and the haze (window reflections fade to it from 220 m)
        float starR = 1.0 - 3.3 * rCone;
        float3 rc = rD.y > 0.0 ? mix(sky(rD, U, starR), fogTint(U), 0.5) : fogTint(U) * 0.6;   // looking down: the dark city in its haze
        float farW = rNear < 1e8 ? smoothstep(rNear, rNear * 1.4, t) : 0.0;
        if (rWm >= 0.015 && farW < 1.0 && t < 900.0) {
            float3 rcFar = rc;
            float lamps2 = 0.0;
            Hit h2 = trace(rO, rD, rSteps, min(rMax, tFar), U, false, lamps2, fpAng);
            if (h2.kind == 0 && rD.y < 0.25) h2.t = max(h2.t, rMax);   // ran out: the haze hides the rest
            float3 p2 = rO + rD * h2.t;
            float fp2 = max(rFp, (t + h2.t) * fpAng + h2.t * rCone);
            if (h2.kind == 2) {
                Bld b2 = building(h2.cell, U, lb, lD);
                bldLook(b2);
                Look k2 = lookOf(b2);
                float g2, wm2; float3 sp2; float2 j2;
                if (h2.n.y > 0.5) {
                    float3 a2;
                    rc = roof(p2, h2, b2, U, fp2, a2) + a2 * lighting(p2, h2.n, U, L, true);
                } else {
                    rc = facade(p2, h2.n, h2, b2, k2, U, fp2, g2, sp2, wm2, j2);
                    rc += k2.wall * wm2 * (lighting(p2, h2.n, U, L, true) + (sp2 * 1.6 + fogTint(U) * 0.15) * (0.5 + gloom))
                          * (0.4 + 0.6 * smoothstep(0.0, 14.0, p2.y));
                }
            } else if (h2.kind == 1) {
                float w2;
                rc = ground(p2, h2, rD, U, L, fp2, w2, true);
            } else {
                rc = sky(rD, U, starR);
            }
            rc += float3(1.0, 0.7, 0.4) * lamps2;
            float d2 = (0.00025 + 0.0022 * haze) * (1.0 + 4.0 * gloom) * exp(-max(1.0, rO.y + rD.y * min(h2.t, 1500.0) * 0.5) / (260.0 + 200.0 * gloom));
            rc = mix(rc, fogTint(U), 1.0 - exp(-min(h2.t, 3000.0) * d2 * (h2.kind == 0 ? 0.6 : 1.0)));
            rc += rayGlow(rO, rD, h2.t, U, L, fpAng * 3.0 + rCone);
            rc = mix(rc, rcFar, farW);
        }
        col += rc * rW;
    }
    // street lamp heads seen on the way
    col += float3(1.0, 0.7, 0.4) * lamps;
    // night haze: thicker low down, glowing with the city's light pollution
    float dens = (0.00025 + 0.0022 * haze) * (1.0 + 4.0 * gloom);
    float yAvg = max(1.0, ro.y + rd.y * min(t, 1500.0) * 0.5);
    float fog = 1.0 - exp(-min(t, 3000.0) * dens * exp(-yAvg / (260.0 + 200.0 * gloom)) * (h.kind == 0 ? 0.6 : 1.0));
    float3 fogC = fogTint(U) * (1.0 + 0.4 * U.music2.y) + float3(0.05, 0.055, 0.075) * U.flash.w;
    fogC *= 0.6 + 0.4 * (1.0 - smoothstep(0.0, 0.5, rd.y));
    col = mix(col, fogC, fog);
    col += rayGlow(ro, rd, t, U, L, fpAng);
    // gloom: muted colours, slightly lifted, cool shadows
    float lum = dot(col, float3(0.25, 0.6, 0.15));
    col = mix(col, lum * float3(0.95, 0.98, 1.05), 0.35 * gloom) * (1.0 - 0.25 * gloom);
    col = aces(col * U.colC.w * (1.0 - 0.3 * gloom));
    col = pow(col, float3(1.0 / 2.2));
    return float4(col, 1.0);
}
"""#
