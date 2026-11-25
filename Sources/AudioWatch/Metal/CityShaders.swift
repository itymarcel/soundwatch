// MSL for the Landscape's City scene (CityGPU), compiled at runtime into its own library.
// One full-screen pass ray-traces an endless night city: rays walk a 2D grid of 16 m lots (DDA), every lot holds one
// building of up to three stacked boxes (+ a spire) defined by hashes of its world cell, so the hit is exact and the
// same walk gives real shadows from any light (light drones, lightning). Blocks are 4 × 4 lots with a 16 m street
// between them. Positions are relative to the camera's cell (`U.cell`), so floats stay small however far it flies.
let cityShaderSource = #"""
#include <metal_stdlib>
using namespace metal;
//@GI_CORE@

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
    float4 cfg4;       // architectural detail, GI intensity (0 = off), -, -
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
static float lineMask(float d, float w, float a) { return 1.0 - smoothstep(w - a, w + a, d); }
static float h11(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
/// Value noise whose lattice repeats every `per` cells (integer hash: exact for large coordinates).
static float vnoiseP(float2 p, int per) {
    float2 fi = floor(p), f = p - fi; f = f * f * (3.0 - 2.0 * f);
    int2 i = int2(fi);
    int2 a = int2(((i.x % per) + per) % per, ((i.y % per) + per) % per);
    int2 b = int2((a.x + 1) % per, (a.y + 1) % per);
    return mix(mix(h01(a, 3u), h01(int2(b.x, a.y), 3u), f.x), mix(h01(int2(a.x, b.y), 3u), h01(b, 3u), f.x), f.y);
}
/// World position on the ground, wrapped every 4096 m (256 lots), for textures that must stay put while the camera's
/// cell changes (positions are relative to that cell). Noise frequencies times 4096 must be whole numbers.
/// The same with a power-of-two period (`mask` = period − 1): a bit mask instead of integer modulo (slow on GPUs).
static float vnoiseM(float2 p, int mask) {
    float2 fi = floor(p), f = p - fi; f = f * f * (3.0 - 2.0 * f);
    int2 a = int2(fi) & mask, b = (a + 1) & mask;
    return mix(mix(h01(a, 3u), h01(int2(b.x, a.y), 3u), f.x), mix(h01(int2(a.x, b.y), 3u), h01(b, 3u), f.x), f.y);
}
static float2 worldXZ(float3 p, constant CityU& U) {
    int2 c = int2(((U.cell.x % 256) + 256) % 256, ((U.cell.y % 256) + 256) % 256);
    return p.xz + float2(c) * C;
}
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
    float top;       // highest point of the building itself (< 0 = empty lot)
    float bound;     // highest point incl. rooftop structures (what the walk tests against)
    int rk;          // rooftop structure: 0 none, 1 penthouse / plant room (box), 2 water tank (cylinder on a base)
    float4 rb;       // its centre x, z and half sizes x, z (tank: radius in z)
    float2 ry;       // its bottom and top
    int2 owner;      // world cell whose hashes define the building
    float id, style;
    int band;
    // real architectural geometry (Architecture): a cornice box at every tier top, balcony strips on tier 0
    float2 corn;     // cornice height, how far it sticks out (0 = none)
    float4 bal;      // balconies: depth (< 0: on the z faces, > 0: on the x faces; 0 = none), floor height, first floor base, number of floors
};

constant float BAL_SLAB = 0.18, BAL_RAIL = 1.05;   // balcony slab thickness, balustrade height above the slab

/// Cornice and balcony geometry of a building (the same hashes `lookOf` used for the painted versions).
static void bldDetails(thread Bld& b, float m, float arch) {
    int2 o = b.owner;
    float style = h01(o, 8);
    bool curtain = style > 0.62;
    float a2 = h01(o, 33);
    if (!curtain && h01(o, 32) < arch * 0.9) b.corn = float2(0.7 + 0.8 * a2, min(0.3 + 0.35 * a2, m - 0.1));
    float kt = h01(o, 9);
    bool punched = !curtain && (kt < 0.45 || kt >= 0.8);
    if (punched && b.top < 75.0 && h01(o, 36) < arch * 0.6) {
        float d = min(1.25, m - 0.1);
        if (d >= 0.6) {
            float r2 = h01(o, 22);
            float fh = kt < 0.45 ? 2.6 + 0.4 * r2 : 2.7 + 0.3 * r2;
            float shop = h01(o, 27) < 0.7 ? 4.2 + 1.3 * h01(o, 28) : 0.0;
            float n = floor((b.h.x - 1.6 - shop) / fh);
            if (n >= 1.0) b.bal = float4(h01(o, 44) < 0.5 ? d : -d, fh, shop, n);
        }
    }
}

static float maxHeight(float towers) { return 30.0 + 330.0 * (0.3 + 1.2 * towers) + 60.0; }

/// The highest any building of a block with district value D can reach.
static float blockBound(float D, float towers) {
    float tf = 0.3 + 1.2 * towers;
    return max(18.0 + (20.0 + 300.0 * D * D) * tf + 47.0, 5.0 + (6.0 + 40.0 * D) * (0.5 + 0.5 * tf)) + 0.5;
}

/// The building standing on lot `rc` (relative to the camera cell). Streets and parks: top < 0.
/// Only the geometry; `bldLook` adds id / style / band for shading. `yLow` = the lowest the walking ray gets over
/// this lot: when it passes above anything a rooftop structure could reach, those aren't worked out (the walk only
/// needs to know it can't hit; `bound` then is the building's own top).
constant float ROOF_MAX = 6.6;   // the most a rooftop structure rises above its roof (see below)
static Bld building(int2 rc, constant CityU& U, thread int2& lastBlk, thread float& lastD, float yLow = -1e9, bool det = true) {
    // everything initialised: streets / parks return early, and the shadow walk tests `bound` / `hitBld` on them
    // (uninitialised fields made drone shadows fall in random blocks of pixels: "pixelated light")
    Bld b; b.top = -1.0; b.bound = -1.0; b.corn = float2(0.0); b.bal = float4(0.0);
    b.fp = float4(0.0); b.h = float3(0.0); b.inset = float2(0.0); b.spire = 0.0; b.rk = 0;
    b.rb = float4(0.0); b.ry = float2(0.0); b.owner = int2(0); b.id = 0.0; b.style = 0.0; b.band = 0;
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
    // rooftop structures (Architecture): a penthouse / plant room on towers, a water tank on low buildings
    b.rk = 0; b.bound = b.top;
    if (yLow > hgt + ROOF_MAX) return b;
    float arch = U.cfg4.x;
    // (`det` false: shadow and reflection walks skip the cornices / balconies: many steps per pixel, they barely show there)
#ifndef NO_DET
    if (det && arch > 0.0) bldDetails(b, m, arch);
#endif
    float r6 = h01(owner, 12);
    bool pad = b.top > 120.0 && h01(owner, 6) > 0.72;           // helipad roofs stay clear
    if (arch > 0.0 && !pad && r6 < arch * (hgt > 45.0 ? 0.9 : 0.55)) {
        float s0 = hgt > 45.0 ? b.inset.y : 0.0;
        float2 lo = b.fp.xy + s0, hi = b.fp.zw - s0;
        float2 ext = hi - lo;
        float r7 = h01(owner, 13), r8 = h01(owner, 14);
        if (hgt > 45.0 || r8 < 0.35) {
            b.rk = 1;
            float2 hw = ext * float2(0.14 + 0.12 * r7, 0.14 + 0.12 * fract(r7 * 7.3));
            float2 c = lo + hw + 1.0 + (ext - 2.0 * hw - 2.0) * float2(r8, fract(r8 * 5.1));
            b.rb = float4(c, hw);
            b.ry = float2(hgt, hgt + (hgt > 45.0 ? 3.5 + 3.0 * r7 : 2.6 + 1.0 * r7));
        } else {
            b.rk = 2;
            float rad = 1.2 + 0.6 * r7;
            float2 c = lo + rad + 1.2 + (ext - 2.0 * rad - 2.4) * float2(fract(r8 * 3.7), fract(r8 * 9.1));
            b.rb = float4(c, rad, rad);
            b.ry = float2(hgt, hgt + 1.8 + 3.2 + 1.2 * r8);
        }
        b.bound = max(b.top, b.ry.y);
    }
    return b;
}

static void bldLook(thread Bld& b) {
    b.id = h01(b.owner, 6); b.style = h01(b.owner, 8);
    b.band = int(h01(b.owner, 5) * 8.0) & 7;
}

struct Hit {
    float t;
    float3 n;
    int kind;        // 0 sky, 1 ground, 2 building, 3 car (boxTop = its hash)
    int2 cell;
    float boxTop;    // top of the box that was hit
    float4 box;      // its footprint
    int part;        // 0…2 tiers, 3 spire, 4 rooftop structure; cars: the lane
    int sub;         // buildings: 0 the box itself, 1 cornice, 2 balcony
};

/// Ray / box slab test without rejecting a start inside the box: entry (may be < 0), exit and the entry normal.
static bool boxSpan(float3 ro, float3 ird, float3 lo, float3 hi, thread float& tn, thread float& tf, thread float3& n) {
    float3 a = (lo - ro) * ird, c = (hi - ro) * ird;
    float3 mn = min(a, c), mx = max(a, c);
    tn = max(max(mn.x, mn.y), mn.z);
    tf = min(min(mx.x, mx.y), mx.z);
    if (tn > tf || tf < 1e-3) return false;
    n = mn.x >= tn ? float3(-sign(ird.x), 0, 0) : mn.z >= tn ? float3(0, 0, -sign(ird.z)) : float3(0, -sign(ird.y), 0);
    return true;
}

/// Balcony strips in front of tier 0's faces along one axis: per floor a slab (BAL_SLAB thick) and a solid balustrade
/// (BAL_RAIL high) along the outer edge, open between them. Exact: the ray is followed through the shell analytically.
static bool hitBalcony(Bld b, float3 ro, float3 ird, float tLim, thread Hit& h) {
    float d = abs(b.bal.x), fh = b.bal.y, y0 = b.bal.z, nF = b.bal.w;
    bool ax = b.bal.x > 0.0;                       // true: in front of the x faces
    float4 f = b.fp;
    float3 lo = float3(f.x - (ax ? d : 0.0), y0 + fh - BAL_SLAB, f.y - (ax ? 0.0 : d));
    float3 hi = float3(f.z + (ax ? d : 0.0), y0 + fh * nF + BAL_RAIL, f.w + (ax ? 0.0 : d));
    float tn, tf; float3 n;
    if (!boxSpan(ro, ird, lo, hi, tn, tf, n) || tn >= tLim) return false;
    float3 rd = 1.0 / ird;
    float t = max(tn, 0.0);
    float tEnd = min(tf, tLim);
    float3 p = ro + rd * t;
    float a = ax ? p.x : p.z;
    float cA = ax ? 0.5 * (f.x + f.z) : 0.5 * (f.y + f.w);
    float hw = ax ? 0.5 * (f.z - f.x) : 0.5 * (f.w - f.y);
    // inside the building's own box: no balcony there (the box test handles it)
    if (abs(a - cA) < hw - 1e-3 && tn > 0.0) return false;
    // floor j: slab top at y0 + fh·j; solid for yr ∈ [−BAL_SLAB, BAL_RAIL] near the outer edge, [−BAL_SLAB, 0] inwards
    float yr0 = p.y - y0;
    float j = floor((yr0 + BAL_SLAB) / fh);
    float yr = yr0 - fh * j;                       // height above slab j's top (−BAL_SLAB…fh − BAL_SLAB)
    if (tn > 0.0) {
        bool nearOuter = abs(a - cA) > hw + d - 0.08;    // over the balustrade (entered through the outer face, an end or its top)
        if (j >= 1.0 && j <= nF && (yr <= 1e-3 || (yr <= BAL_RAIL + 1e-3 && nearOuter))) {
            h.t = tn; h.n = n; h.part = 0; h.sub = 2; h.boxTop = y0 + fh * j; h.box = float4(lo.xz, hi.xz);
            return true;
        }
    }
    // in the open part of floor j: down onto the slab (or the balustrade's top), up into the next slab's underside,
    // outwards through the balustrade (rays starting at the facade, e.g. reflections)
    float best = tEnd; float3 bn = float3(0); float bTop = 0.0;
    if (rd.y < 0.0 && j >= 1.0 && j <= nF) {
        float ty = (y0 + fh * j - ro.y) / rd.y;
        if (ty > t && ty < best) { best = ty; bn = float3(0, 1, 0); bTop = y0 + fh * j; }
    } else if (rd.y > 0.0 && j + 1.0 <= nF) {
        float ty = (y0 + fh * (j + 1.0) - BAL_SLAB - ro.y) / rd.y;
        if (ty > t && ty < best) { best = ty; bn = float3(0, -1, 0); bTop = y0 + fh * (j + 1.0); }
    }
    float va = ax ? rd.x : rd.z;
    float s = sign(a - cA);
    if (va * s > 0.0) {
        float tp = (cA + s * (hw + d - 0.06) - (ax ? ro.x : ro.z)) / va;
        float yp = ro.y + rd.y * tp - y0 - fh * j;
        if (tp > t && tp < best && j >= 1.0 && j <= nF && yp <= BAL_RAIL) {
            best = tp; bn = ax ? float3(-s, 0, 0) : float3(0, 0, -s); bTop = y0 + fh * j;
        }
    }
    if (best < tEnd) {
        h.t = best; h.n = bn; h.part = 0; h.sub = 2; h.boxTop = bTop; h.box = float4(lo.xz, hi.xz);
        return true;
    }
    return false;
}

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
            tLim = tn; any = true; h.t = tn; h.n = n; h.boxTop = b.h[k]; h.box = g; h.part = k; h.sub = 0;
        }
        // cornice: a real box round the top of the tier
#ifndef NO_CORN
        if (b.corn.x > 0.0 && b.h[k] - b.corn.x > (k == 0 ? 3.0 : b.h[k - 1])) {
            float4 gc = g + float4(-b.corn.y, -b.corn.y, b.corn.y, b.corn.y);
            if (boxRay(ro, ird, float3(gc.x, b.h[k] - b.corn.x, gc.y), float3(gc.z, b.h[k], gc.w), tn, n) && tn < tLim) {
                tLim = tn; any = true; h.t = tn; h.n = n; h.boxTop = b.h[k]; h.box = gc; h.part = k; h.sub = 1;
            }
        }
#endif
    }
#ifndef NO_BAL
    if (b.bal.x != 0.0) {
        Hit bh;
        if (hitBalcony(b, ro, ird, tLim, bh)) { tLim = bh.t; any = true; h = bh; }
    }
#endif
    if (b.spire > 0.0) {
        float2 c = 0.5 * (f.xy + f.zw);
        if (boxRay(ro, ird, float3(c.x - 0.7, 0, c.y - 0.7), float3(c.x + 0.7, b.spire, c.y + 0.7), tn, n) && tn < tLim) {
            any = true; tLim = tn; h.t = tn; h.n = n; h.boxTop = b.spire; h.box = float4(c - 0.7, c + 0.7); h.part = 3; h.sub = 0;
        }
    }
    if (b.rk == 1) {
        float2 c = b.rb.xy, e = b.rb.zw;
        if (boxRay(ro, ird, float3(c.x - e.x, b.ry.x, c.y - e.y), float3(c.x + e.x, b.ry.y, c.y + e.y), tn, n) && tn < tLim) {
            any = true; h.t = tn; h.n = n; h.boxTop = b.ry.y; h.box = float4(c - e, c + e); h.part = 4; h.sub = 0;
        }
    } else if (b.rk == 2) {
        // water tank: a cylinder standing on a narrower square base (its legs, seen as one dark block)
        float2 c = b.rb.xy; float rad = b.rb.z;
        float y0 = b.ry.x + 1.8;
        float bw = rad * 0.7;
        if (boxRay(ro, ird, float3(c.x - bw, b.ry.x, c.y - bw), float3(c.x + bw, y0, c.y + bw), tn, n) && tn < tLim) {
            any = true; tLim = tn; h.t = tn; h.n = n; h.boxTop = y0; h.box = float4(c - bw, c + bw); h.part = 4; h.sub = 0;
        }
        float3 rd = 1.0 / ird;
        float2 oc = ro.xz - c;
        float qa = dot(rd.xz, rd.xz), qb = dot(oc, rd.xz), qc = dot(oc, oc) - rad * rad;
        float disc = qb * qb - qa * qc;
        if (disc > 0.0 && qa > 1e-8) {
            float t = (-qb - sqrt(disc)) / qa;
            float y = ro.y + rd.y * t;
            if (t > 1e-3 && t < tLim && y > y0 && y < b.ry.y) {
                any = true; tLim = t; h.t = t; h.n = float3(normalize(oc + rd.xz * t), 0).xzy; h.boxTop = b.ry.y;
                h.box = float4(c - rad, c + rad); h.part = 4; h.sub = 0;
            } else if (rd.y < 0.0) {
                float tc = (b.ry.y - ro.y) / rd.y;
                float2 q = oc + rd.xz * tc;
                if (tc > 1e-3 && tc < tLim && dot(q, q) < rad * rad) {
                    any = true; h.t = tc; h.n = float3(0, 1, 0); h.boxTop = b.ry.y; h.box = float4(c - rad, c + rad); h.part = 4; h.sub = 0;
                }
            }
        }
    }
    return any;
}

/// Cars: low glowing boxes (0.75 m tall) hovering over the four lanes of every street (14 m slots, Traffic = share of them
/// filled, the same hashes as the old painted head / tail lights). They are real boxes in the walk (so they show in
/// the wet streets and the windows) and light the road around them (`carLight`).
constant float CAR_L = 2.2, CAR_W = 0.85, CAR_Y0 = 0.38, CAR_Y1 = 1.12;

static float3 carColour(float r, int lane, constant CityU& U) {
    float3 c = lane >= 2 ? float3(1.0, 0.86, 0.66) : float3(1.0, 0.14, 0.06);
    if (fract(r * 53.0) < 0.2) c = mix(U.colA.rgb, U.colB.rgb, fract(r * 91.0));
    return c;
}

/// Runs the code given last (it sees lc, cl, r, lane, along) for every car whose box may reach the stretch [l0 − pad, l1 + pad] of the
/// streets running through world cell wc (o = the cell's corner, camera-relative). lc / cl = lane centre across /
/// car centre along (camera-relative metres).
#define CAR_LOOP(wc, o, l0p, l1p, pad, ...) { \
    int2 kk_ = (wc) - blockOf(wc) * PER; \
    bool av_ = kk_.x == PER - 1, cr_ = kk_.y == PER - 1; \
    for (int ax_ = 0; ax_ < 2; ax_++) { \
        bool along = ax_ == 0; \
        if (along ? !av_ : !cr_) continue; \
        int street_ = along ? (wc).x : (wc).y; \
        float cA_ = (along ? (o).x : (o).y) + 0.5 * C; \
        float l0_ = along ? (l0p).y : (l0p).x, l1_ = along ? (l1p).y : (l1p).x; \
        for (int lane = 0; lane < 4; lane++) { \
            float lc = cA_ + float(lane) * 2.7 - 4.05; \
            float base_ = along ? (lane >= 2 ? U.traffic.x : U.traffic.y) : (lane >= 2 ? U.traffic.z : U.traffic.w); \
            float sA_ = l0_ + base_ - (pad), sB_ = l1_ + base_ + (pad); \
            for (float sl_ = floor((sA_ - 11.0) / 14.0); sl_ <= floor((sB_ - 3.0) / 14.0); sl_ += 1.0) { \
                int si_ = int(sl_ - 256.0 * floor(sl_ / 256.0)); \
                float r = h01(int2(si_, street_ * 4 + lane), 31u); \
                if (r > U.cfg.z * 0.85) continue; \
                float cl = sl_ * 14.0 + 3.0 + 8.0 * fract(r * 17.0) - base_; \
                __VA_ARGS__ \
            } \
        } \
    } }

/// The nearest car of street cell rc along the ray before tLim.
static bool carsHit(int2 rc, float3 ro, float3 ird, float tLim, constant CityU& U, thread Hit& h) {
    if (U.cfg.z <= 0.0) return false;
    int2 wc = U.cell.xy + rc;
    float2 o = float2(rc) * C;
    bool any = false;
    CAR_LOOP(wc, o, o, o + C, CAR_L, {
        float3 lo = along ? float3(lc - CAR_W, CAR_Y0, cl - CAR_L) : float3(cl - CAR_L, CAR_Y0, lc - CAR_W);
        float3 hi = along ? float3(lc + CAR_W, CAR_Y1, cl + CAR_L) : float3(cl + CAR_L, CAR_Y1, lc + CAR_W);
        float tn; float3 n;
        if (boxRay(ro, ird, lo, hi, tn, n) && tn < tLim) {
            tLim = tn; any = true; h.t = tn; h.n = n; h.kind = 3; h.box = float4(lo.xz, hi.xz); h.boxTop = r; h.part = lane; h.sub = 0;
        }
    })
    return any;
}

/// Light the cars throw on the road around them (irradiance; soft area light from the slab's underside).
static float3 carLight(float3 p, int2 rc, constant CityU& U) {
    float3 acc = float3(0.0);
    if (U.cfg.z <= 0.0) return acc;
    int2 wc = U.cell.xy + rc;
    float2 o = float2(rc) * C;
    float I = 2.4 * (0.85 + 0.5 * U.music.y);
    CAR_LOOP(wc, o, p.xz, p.xz, CAR_L + 6.0, {
        float acr = along ? p.x : p.z, len = along ? p.z : p.x;
        float dx = max(abs(acr - lc) - CAR_W, 0.0), dz = max(abs(len - cl) - CAR_L, 0.0);
        float d2 = dx * dx + dz * dz;
        if (d2 < 36.0) {
            float cut = 1.0 - d2 / 36.0;
            acc += carColour(r, lane, U) * I * cut * cut / (1.0 + 0.9 * (d2 + CAR_Y0 * CAR_Y0));
        }
    })
    return acc;
}

/// A car's own glow: a dim translucent body, a bright light band round its sides, a lit rim on top.
static float3 carShade(float3 p, Hit h, constant CityU& U, float fp) {
    float3 c = carColour(h.boxTop, h.part, U);
    float4 b = h.box;
    float I = 0.8 + 0.5 * U.music.y;
    if (h.n.y > 0.5) {
        float de = min(min(p.x - b.x, b.z - p.x), min(p.z - b.y, b.w - p.z));
        float rim = 1.0 - smoothstep(0.05, 0.16 + fp, de);
        return c * I * (0.18 + 1.2 * rim);
    }
    float y = p.y - CAR_Y0, hgt = CAR_Y1 - CAR_Y0;
    float band = lineMask(abs(y - 0.55 * hgt), 0.07, fp);
    float glowB = 1.0 - smoothstep(0.0, 0.25, y);          // the underside light spilling round the bottom edge
    return c * I * (0.22 + 1.6 * band + 0.6 * glowB);
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
static Hit trace(float3 ro, float3 rd, int maxSteps, float tMax, constant CityU& U, bool wantLamps, thread float& lamps, float fpAng, bool det = true) {
    Hit h; h.kind = 0; h.t = tMax; h.n = float3(0, 1, 0); h.cell = int2(0); h.boxTop = 0; h.box = float4(0); h.part = 0; h.sub = 0;
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
        Bld b = building(w.c, U, lb, lD, yLow, det && t0 < 300.0);   // farther: the cornices are only painted (facade)
        if (b.top > 0.0) {
            if (yLow < b.bound) {
                Hit bh;
                if (hitBld(b, ro, ird, min(t1, tg) + 1e-3, bh)) { bh.kind = 2; bh.cell = w.c; return bh; }
            }
        } else {
            if (yLow < CAR_Y1 + 0.01) {
                Hit ch;
                if (carsHit(w.c, ro, ird, min(t1, tg) + 1e-3, U, ch)) { ch.cell = w.c; return ch; }
            }
            if (wantLamps && t0 < 400.0 && yLow < 12.0) lamps += lampHeads(w.c, U, ro, rd, min(t1, tg), fpAng);
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
        Bld b = building(w.c, U, lb, lD, yLow, false);
        if (b.bound > yLow) {
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
static float3 lighting(float3 p, float3 n, constant CityU& U, constant float4* L, bool cheap) {
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
    int mat;         // wall material: 0 brick, 1 concrete, 2 pale stone, 3 dark (curtain walls: 3)
    // architectural details (Architecture slider: each one is present on a share of the buildings that suit it)
    float cornice;   // cornice depth at the top of every tier (m, 0 = none)
    float plinth;    // rusticated base up to this height (0 = none)
    int pil;         // a pilaster every pil bays (0 = none)
    bool balcony;    // balconies with railings
    int fire;        // fire escape: first bay of its 3-bay column in the lot (−1 = none)
    float ac;        // share of windows with an AC unit
    bool quoin;      // corner stones
    float flood;     // facade floodlights (0 = none, else the colour pick)
    bool fins;       // glass fins / sunshades on curtain walls
};

static Look lookOf(Bld b, float arch) {
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
        k.mat = 3;
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
        k.mat = m < 0.3 ? 0 : (m < 0.6 ? 1 : (m < 0.8 ? 2 : 3));
        k.wall = m < 0.3 ? float3(0.13, 0.068, 0.05) : (m < 0.6 ? float3(0.11, 0.105, 0.1) : (m < 0.8 ? float3(0.16, 0.15, 0.135) : float3(0.06, 0.06, 0.066)));
        k.wall *= 0.8 + 0.4 * fract(b.id * 31.7);
        k.tint = float3(0.9, 0.93, 1.0);
        k.refl = k.kind == 1 ? 0.75 : 0.55;
    }
    k.shop = h01(b.owner, 27) < 0.7 ? 4.2 + 1.3 * h01(b.owner, 28) : 0.0;
    bool curtain = k.kind == 3;
    bool punched = !curtain && (k.kind == 0 || k.kind == 2);
    float a1 = h01(b.owner, 32), a2 = h01(b.owner, 33), a3 = h01(b.owner, 34), a4 = h01(b.owner, 35);
    float a5 = h01(b.owner, 36), a6 = h01(b.owner, 37), a7 = h01(b.owner, 38), a8 = h01(b.owner, 39);
    k.cornice = b.corn.x;          // real geometry (bldDetails), shaded here
    (void)a1;
    k.plinth = !curtain && k.mat != 3 && a3 < arch * 0.75 ? max(k.shop, 0.0) + k.fh * (1.0 + floor(a2 * 2.0)) : 0.0;
    k.pil = !curtain && k.pier == 0 && a4 < arch * 0.55 ? (k.kind == 1 ? 1 : 2 + int(a5 * 2.0)) : 0;
    k.balcony = b.bal.x != 0.0;   // real geometry (bldDetails)
    k.fire = k.mat == 0 && b.top < 70.0 && b.top > 12.0 && a6 < arch * 0.85 ? int(a7 * float(k.nb - 3)) : -1;
    k.ac = punched && !k.balcony && a8 < 0.7 ? 0.14 * arch : 0.0;
    k.quoin = (k.mat == 0 || k.mat == 2) && h01(b.owner, 40) < arch * 0.75;
    k.flood = h01(b.owner, 41) < arch * 0.4 ? 0.05 + 0.95 * h01(b.owner, 42) : 0.0;
    k.fins = curtain && h01(b.owner, 43) < arch * 0.7;
    return k;
}

/// How much of a detail of size `sz` (m) still shows at `fp` metres per pixel (fades out before it would alias).
static float vis(float sz, float fp) { return 1.0 - smoothstep(0.25 * sz, 0.9 * sz, fp); }
static int imod(int a, int m) { return ((a % m) + m) % m; }

/// Something solid in front of the facade (a cornice, a railing, a fire escape…) covering `c` of the pixel: it hides
/// the window light and glass behind it; its brightness is `mul` × the wall albedo, or its own colour `col` (ovA = 1).
static void coverWall(float c, float mul, thread float3& e, thread float& glass, thread float& wallMul) {
    e *= 1.0 - c; glass *= 1.0 - c; wallMul = mix(wallMul, mul, c);
}
static void coverCol(float c, float3 col, thread float3& e, thread float& glass, thread float4& ov) {
    e *= 1.0 - c; glass *= 1.0 - c;
    float a = ov.a * (1.0 - c) + c;
    ov.rgb = (ov.rgb * ov.a * (1.0 - c) + col * c) / max(a, 1e-4);
    ov.a = a;
}

/// Windows (and neon, crowns, shop fronts) of a building facade: emission. `fp` = metres per pixel (antialiasing:
/// fine window grids fade to their average). Outputs: `glass` = how much of the pixel is reflecting glass, `spill`
/// = average window light (bounce), `wallMul` = albedo detail, `jit` = the pane's small tilt (broken-up mirror).
static float3 facade(float3 p, float3 n, float3 rd, Hit h, Bld b, Look k, constant CityU& U, float fp,
                     thread float& glass, thread float3& spill, thread float& wallMul, thread float2& jit,
                     thread float3& nB, thread float4& ov) {
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
    // the window opening in the facade
    float wmS = smoothstep(k.mu - aa, k.mu + aa, fu) * smoothstep(k.mu - aa, k.mu + aa, 1.0 - fu)
              * smoothstep(k.sill - aav, k.sill + aav, fv) * smoothstep(k.head - aav, k.head + aav, 1.0 - fv);
    if (pierBay || mech) wmS = 0.0;
    // window recess: the glass sits `dep` behind the facade. Followed exactly: where the ray meets the glass plane
    // (fuG, fvG) and, if that is outside the opening, it met a reveal (jamb, sill or head) first
    float far0 = smoothstep(0.2, 0.7, max(aa, aav));
#ifdef NO_REV
    float dep = 0.0;
#else
    float dep = curtain ? 0.0 : (k.kind == 1 ? 0.14 : 0.2 + 0.12 * fract(b.id * 7.7)) * (1.0 - far0);
#endif
    float3 tU0 = xFace ? float3(0, 0, 1) : float3(1, 0, 0);
    float2 shG = float2(dot(rd, tU0), rd.y) * dep / max(-dot(rd, n), 0.08);
    float fuG = fu + shG.x / bay, fvG = fv + shG.y / k.fh;
    float wmG = smoothstep(k.mu - aa, k.mu + aa, fuG) * smoothstep(k.mu - aa, k.mu + aa, 1.0 - fuG)
              * smoothstep(k.sill - aav, k.sill + aav, fvG) * smoothstep(k.head - aav, k.head + aav, 1.0 - fvG);
    float wm = wmS * wmG;                  // glass seen through the opening
    float rev = wmS * (1.0 - wmG) * smoothstep(0.0, 0.03, dep);   // the reveal
    float exU = max(k.mu - fuG, fuG - (1.0 - k.mu)) * bay, exV = max(k.sill - fvG, fvG - (1.0 - k.head)) * k.fh;
    float3 revN = exU > exV ? tU0 * (fuG < 0.5 ? 1.0 : -1.0) : float3(0, fvG < 0.5 ? 1.0 : -1.0, 0);
    // how deep in the reveal (0 at the facade, 1 at the glass): darker towards the glass
    float revD = clamp(1.0 - max(exU, exV) / max(length(shG), 1e-3), 0.0, 1.0);
    // mullions / transoms: thin dark bars (6 cm) across the pane (on the glass plane)
    float mw = 0.03 / bay, mwv = 0.03 / k.fh;
    float bars = 0.0;
    if (k.mull == 1 || k.mull == 3) bars = max(bars, lineMask(abs(fuG - 0.5), mw, aa));
    if (k.mull == 2) bars = max(bars, max(lineMask(abs(fuG - (k.mu + (1.0 - 2.0 * k.mu) / 3.0)), mw, aa),
                                          lineMask(abs(fuG - (1.0 - k.mu - (1.0 - 2.0 * k.mu) / 3.0)), mw, aa)));
    if (k.mull == 3) bars = max(bars, lineMask(abs(fvG - (k.sill + 0.62 * (1.0 - k.sill - k.head))), mwv, aav));
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
    float wv = (fvG - k.sill) / max(0.05, 1.0 - k.sill - k.head);
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
    jit = (float2(h01(int2(col, row), 93u), h01(int2(col, row), 94u)) - 0.5) * (curtain ? 0.01 : 0.016) * (1.0 - far);
    // wall detail: the floor slab / spandrel band, a frame around punched windows, louvres on plant floors
    float slabB = 1.0 - smoothstep(0.0, 0.35 * k.sill + aav, fv);
    float frame = curtain ? 0.0 : max(0.0, smoothstep(k.mu - 0.06 / bay - aa, k.mu - aa, fu) * smoothstep(k.mu - 0.06 / bay - aa, k.mu - aa, 1.0 - fu)
                  * smoothstep(k.sill - 0.08 / k.fh - aav, k.sill - aav, fv) * smoothstep(k.head - 0.06 / k.fh - aav, k.head - aav, 1.0 - fv) - wmS);
    float louv = mech ? 0.5 + 0.5 * mix(sin(p.y * 2.0 * M_PI_F / 0.3), 0.0, smoothstep(0.1, 0.3, aav * k.fh / 0.3)) : 0.0;
    wallMul = mix(1.0 + k.slab * slabB * (1.0 - wmS) + 0.6 * frame + 0.5 * louv, 1.0 + 0.3 * k.slab * k.sill, far);
    nB = n; ov = float4(0.0);
    // the reveal: wall material, darker deeper in, lit by the room when the window is lit
    wallMul = mix(wallMul, 1.25 - 0.4 * revD, rev);
    e += lc * litM * rev * (0.15 + 0.35 * revD);
    float uW = uRel + float(imod(cellU, 256)) * C;  // along the facade in (wrapped) world metres: patterns stay put

    // architectural details (Architecture slider; Look decides which ones this building has)
    if (U.cfg4.x > 0.0 && h.part < 3 && p.y >= k.shop) {
        float3 upV = float3(0, 1, 0);
        float3 tU = xFace ? float3(0, 0, 1) : float3(1, 0, 0);
        float loA = xFace ? h.box.y : h.box.x, hiA = xFace ? h.box.w : h.box.z;
        float dcA = min(uRel - loA, hiA - uRel);
        float dy = fv * k.fh;                        // height above this floor's slab
        float bendU = 0.0, bendS = 0.0;              // normal bends: up / sideways (along tU)
        int gB = int(floor(cu + 0.5)) + cellU * k.nb;   // nearest bay boundary (world index)
        float dB = abs(cu - floor(cu + 0.5)) * bay;     // distance to it (m)
        float sB = sign(cu - floor(cu + 0.5));
        // pilasters: flat vertical piers on the bay boundaries, lit edges, a shadow strip beside them
        if (k.pil > 0 && imod(gB, k.pil) == 0) {
            float pw = 0.22 + 0.08 * fract(b.id * 19.0);
            float inP = lineMask(dB, pw, fp);
            coverWall(inP, 1.3, e, glass, wallMul);
            float edge = smoothstep(pw - 0.08, pw, dB) * inP * vis(0.15, fp);
            bendS += sB * 0.7 * edge;
            wallMul *= 1.0 - 0.3 * (1.0 - inP) * lineMask(dB - pw, 0.12, fp) * step(0.0, sB) * vis(0.2, fp);
        }
        // glass fins on curtain walls: thin metal blades on every other mullion, sunshades on some
        if (k.fins) {
            if (imod(gB, 2) == 0) {
                float inF = lineMask(dB, 0.07, fp);
                coverCol(inF * (0.4 + 0.6 * vis(0.14, fp)), float3(0.13, 0.14, 0.16), e, glass, ov);
                bendS += sB * 0.8 * inF * vis(0.14, fp);
            }
            if (fract(b.id * 23.0) < 0.5 && !mech) {
                float sh = lineMask(abs(dy - k.sill * k.fh), 0.07, fp);
                coverCol(sh, float3(0.12, 0.13, 0.15), e, glass, ov);
                bendU += 0.6 * sh;
            }
        }
        // balconies: a slab at each floor with a railing, its shadow on the windows below, now and then a lamp
        bool balFace = k.balcony && (b.bal.x > 0.0) == xFace && h.part == 0;
        if (balFace && row >= 1 && float(row) <= b.bal.w && !mech) {
            // the balcony slab above (real geometry) shades the top of this floor and the wall just above the floor
            float shade = smoothstep(k.fh - 0.7, k.fh - 0.05, dy) + 0.6 * (1.0 - smoothstep(0.0, 0.5, dy));
            shade *= vis(0.3, fp);
            e *= 1.0 - 0.3 * shade; wallMul *= 1.0 - 0.45 * shade;
            float lampH = h01(int2(col, row), 111u);
            if (lampH < 0.1 && row > 0) {
                float2 d2 = float2((fu - 0.5) * bay, dy - (k.fh - 0.4));
                float r = 0.1 + fp;
                e += float3(1.0, 0.72, 0.4) * exp(-dot(d2, d2) / (r * r)) * min(1.0, 0.012 / (r * r)) * 1.5 * U.music2.w;
            }
        }
        // AC units in some windows: a pale box on the sill with a grille, a drip stain under it
        if (k.ac > 0.0 && !mech && !pierBay && h01(int2(col, row), 101u) < k.ac) {
            float sy = k.sill * k.fh;
            float inX = lineMask(abs(fu - 0.5) * bay, 0.32, fp);
            float box = inX * smoothstep(sy - 0.06 - fp, sy - 0.06 + fp, dy) * (1.0 - smoothstep(sy + 0.38 - fp, sy + 0.38 + fp, dy));
            float gr = mix(0.75 + 0.25 * step(0.5, fract(dy / 0.06)), 0.87, 1.0 - vis(0.06, fp));
            coverCol(box, float3(0.15, 0.15, 0.14) * gr, e, glass, ov);
            float drip = inX * smoothstep(sy - 0.6, sy - 0.06, dy) * (1.0 - step(sy - 0.06, dy)) * vis(0.3, fp);
            wallMul *= 1.0 - 0.25 * drip;
            bendU += 0.4 * box * lineMask(abs(dy - sy - 0.36), 0.03, fp);
        }
        // fire escape (brick buildings): platforms and railings at every floor, a zigzag stair between them
        if (k.fire >= 0 && p.y > max(k.shop, 3.2) && p.y < h.boxTop - 1.2 && h.part == 0) {
            int lbay = colL - k.nb * int(floor(float(colL) / float(k.nb)));
            if (lbay >= k.fire && lbay < k.fire + 3) {
                float W = 3.0 * bay;
                float ue = (float(lbay - k.fire) + fu) * bay;
                float inX = smoothstep(0.1 - fp, 0.1 + fp, ue) * smoothstep(0.1 - fp, 0.1 + fp, W - ue);
                float plat = lineMask(abs(dy - 0.06), 0.06, fp);
                float rail = lineMask(abs(dy - 0.95), 0.03, fp) + lineMask(abs(dy - 0.5), 0.015, fp) * vis(0.05, fp);
                float post = lineMask(abs(fract(ue / 0.1 + 0.5) - 0.5) * 0.1, 0.01, fp);
                post = mix(post, 0.2, 1.0 - vis(0.1, fp)) * step(dy, 0.95);
                float uN = (row & 1) == 0 ? ue / W : 1.0 - ue / W;
                float yl = (uN - 0.12) / 0.76 * k.fh;              // the stair's stringer climbs one floor
                float onS = step(0.12, uN) * step(uN, 0.88);
                float str = lineMask(abs(dy - yl), 0.05, fp) * onS;
                float treads = lineMask(abs(dy - yl - 0.12), 0.14, fp) * onS * mix(step(0.5, fract(dy / 0.19)), 0.5, 1.0 - vis(0.19, fp));
                float iron = min(1.0, (plat + rail + post * 0.9 + str + treads * 0.8) * inX);
                coverCol(iron, float3(0.02, 0.02, 0.022), e, glass, ov);
                // its shadow on the wall just below each platform
                wallMul *= 1.0 - 0.3 * inX * smoothstep(k.fh - 0.35, k.fh, dy) * vis(0.3, fp);
            }
        }
        // quoins: alternating long and short corner stones
        if (k.quoin && dcA < 1.1) {
            float course = floor(p.y / 0.55);
            float qw = fmod(course, 2.0) < 0.5 ? 0.95 : 0.6;
            float inQ = lineMask(dcA, qw, fp) * vis(0.3, fp);
            float g = lineMask(abs(fract(p.y / 0.55 + 0.5) - 0.5) * 0.55, 0.025, fp) * vis(0.12, fp);
            coverWall(inQ, (k.mat == 0 ? 1.9 : 1.35) * (1.0 - 0.5 * g), e, glass, wallMul);
        }
        // rusticated base: deep horizontal joints, staggered vertical ones, a string course on top
        if (k.plinth > 0.0 && p.y < k.plinth) {
            float course = floor(p.y / 0.6);
            float gh = lineMask(abs(fract(p.y / 0.6 + 0.5) - 0.5) * 0.6, 0.035, fp);
            float gv = lineMask(abs(fract(uW / 1.4 + 0.5 * fmod(course, 2.0) + 0.5) - 0.5) * 1.4, 0.02, fp);
            float v = vis(0.15, fp);
            wallMul *= mix(1.0, (1.15 - 0.6 * max(gh, gv * 0.7)), (1.0 - wm) * mix(0.5, 1.0, v));
            bendU += 0.5 * gh * v * (1.0 - wm);
            float sc = lineMask(abs(p.y - (k.plinth - 0.15)), 0.15, fp);
            coverWall(sc, 1.5, e, glass, wallMul);
            bendU += 0.6 * sc;
            wallMul *= 1.0 - 0.3 * smoothstep(k.plinth - 0.6, k.plinth - 0.3, p.y) * (1.0 - smoothstep(k.plinth - 0.3, k.plinth - 0.28, p.y)) * vis(0.3, fp);
        }
        // cornice at the top of every tier: a lit cap, a row of dentils, a deep shadowed soffit, its shadow below
        if (k.cornice > 0.0) {
            float d = h.boxTop - p.y, cH = k.cornice;
            if (d < cH + 0.6) {
                float inC = lineMask(abs(d - 0.5 * cH), 0.5 * cH, fp);
                float top = 1.0 - smoothstep(0.3 * cH - fp, 0.3 * cH + fp, d);
                float sof = smoothstep(0.68 * cH - fp, 0.68 * cH + fp, d);
                float dent = max(0.0, 1.0 - top - sof);
                float blk = mix(step(0.5, fract(uW / 0.3)), 0.5, 1.0 - vis(0.3, fp));
                coverWall(inC, top * 1.55 + dent * mix(0.7, 1.35, blk) + sof * 0.5, e, glass, wallMul);
                bendU += (0.9 * top - 0.8 * sof) * inC;
                float below = smoothstep(cH - fp, cH + fp, d) * (1.0 - smoothstep(cH + 0.1, cH + 0.6 + fp, d)) * vis(0.4, fp);
                wallMul *= 1.0 - 0.35 * below; e *= 1.0 - 0.3 * below;
            }
        }
        nB = normalize(n + upV * bendU + tU * bendS);
        // floodlights at the foot of the facade washing up the wall, breathing with the building's band
        if (k.flood > 0.0) {
            float y0 = k.shop + 0.15;
            float yr = p.y - y0;
            float sp = k.pil > 0 ? bay * float(k.pil) : (k.pier > 0 ? bay * float(k.pier) : max(2.0 * bay, 3.2));
            float du = (fract((uW + 0.5 * sp) / sp) - 0.5) * sp;
            float w = 0.25 + 0.11 * yr;
            float shape = mix(exp(-du * du / (w * w)), min(1.0, w * 1.77 / sp), smoothstep(0.1 * sp, 0.4 * sp, fp));
            float beam = shape * exp(-yr / (3.5 + 0.06 * b.top)) * smoothstep(0.0, 0.5, yr);
            float3 fc = k.flood < 0.6 ? float3(1.0, 0.78, 0.52) : mix(U.colA.rgb, U.colB.rgb, (k.flood - 0.6) / 0.4);
            float3 wallA = mix(k.wall * wallMul, ov.rgb, ov.a);
            e += fc * beam * 5.0 * wallA * (1.0 - 0.85 * wm) * (0.55 + 1.6 * lvl) * (0.5 + 0.5 * U.music2.w);
        }
    }

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

#ifndef NO_MAT
    // weathering: big blotches, rain streaks running down, dirt washed down from the sills, a darker splash zone
    // at the foot of the wall (world-anchored noise: lattice periods × frequency = 4096)
    {
        float wk = k.mat == 3 ? 0.5 : 1.0;
        float blot = vnoiseM(float2(uW * 0.25, p.y * 0.25 + b.id * 40.0), 1023);
        float vS = vis(0.5, fp);
        float streak = smoothstep(0.55, 0.9, vnoiseM(float2(uW * 2.0, p.y * 0.06 + b.id * 23.0), 8191));
        streak = mix(0.12, streak, vS);
        float inCol = smoothstep(k.mu, k.mu + 0.05, fu) * smoothstep(k.mu, k.mu + 0.05, 1.0 - fu);
        float drip = (pierBay || mech || curtain) ? 0.0 : inCol * smoothstep(0.0, k.sill, fv) * (1.0 - step(k.sill, fv))
                   * step(h01(int2(col, row), 97u), 0.65) * vis(0.4, fp);
        float splash = 1.0 - smoothstep(0.2, 1.4, p.y);
        float g = (0.25 * (blot - 0.5) * 2.0 * 0.5 + 0.22 * streak + 0.3 * drip + 0.3 * splash) * wk;
        wallMul *= clamp(1.0 - g, 0.45, 1.25);
        glass *= 0.88 + 0.12 * blot;
        if (curtain) glass *= 0.82 + 0.3 * h01(int2(col, row), 95u) * (1.0 - far);   // panes never quite match
    }
    // bevelled edges: the box corners and tier tops are rounded off a little and catch the light
    {
        float r = 0.09;
        float cU = lineMask(dc, r, fp), cT = lineMask(h.boxTop - p.y, r, fp);
        float3 tU = xFace ? float3(0, 0, 1) : float3(1, 0, 0);
        float sU = (uRel - lo < hi - uRel) ? -1.0 : 1.0;
        float bv = vis(0.05, fp);
        nB = normalize(nB + tU * sU * 1.1 * cU * bv + float3(0, 1, 0) * 1.1 * cT * bv);
        wallMul *= 1.0 + 0.3 * max(cU, cT);
        e *= 1.0 - max(cU, cT);
        glass *= 1.0 - max(cU, cT);
    }
#endif
    // the reveal's own normal (lighting from the side it faces)
    nB = normalize(mix(nB, revN, rev));
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

/// Rooftop structures (Architecture): a water tank of dark wooden staves and steel hoops on a black base, or a
/// concrete penthouse / plant room with louvred vents and a door under a small lamp.
static float3 roofBox(float3 p, Hit h, Bld b, constant CityU& U, float fp, thread float3& alb) {
    float3 e = float3(0.0);
    if (b.rk == 2) {
        if (h.boxTop < b.ry.y - 0.01) { alb = float3(0.022); return e; }
        alb = float3(0.12, 0.08, 0.055) * (0.8 + 0.4 * fract(b.id * 17.3));
        if (h.n.y > 0.5) { alb *= 0.7; return e; }
        float arc = atan2(p.z - b.rb.y, p.x - b.rb.x) * b.rb.z;
        float stave = mix(0.75 + 0.5 * h11(float2(floor(arc / 0.18), b.id * 100.0)), 1.0, smoothstep(0.04, 0.12, fp));
        float hoop = lineMask(abs(fract((p.y - b.ry.x) / 0.7 + 0.5) - 0.5) * 0.7, 0.035, fp) * vis(0.15, fp);
        alb = mix(alb * stave, float3(0.03), hoop);
        // the roof's light (and the city's glow) catching the lower staves
        e += alb * float3(1.0, 0.72, 0.45) * 0.5 * exp(-(p.y - b.ry.x - 1.8) / 1.5) * (0.4 + 0.6 * U.music2.w);
        return e;
    }
    alb = float3(0.12, 0.12, 0.125) * (0.75 + 0.5 * fract(b.id * 17.3));
    if (h.n.y > 0.5) {
        float de = min(min(p.x - h.box.x, h.box.z - p.x), min(p.z - h.box.y, h.box.w - p.z));
        alb = mix(alb * 0.85, float3(0.13), lineMask(de, 0.2, fp));
        return e;
    }
    bool xF = abs(h.n.x) > 0.5;
    float u = xF ? p.z : p.x;
    float lo = xF ? h.box.y : h.box.x, hi = xF ? h.box.w : h.box.z;
    float uc = u - 0.5 * (lo + hi), wdt = hi - lo;
    float y = p.y - b.ry.x, hgt = b.ry.y - b.ry.x;
    // louvred vents in the upper part
    float lv = step(abs(uc), 0.5 * wdt - 0.6) * step(hgt * 0.45, y) * step(y, hgt - 0.5);
    float sl = mix(step(0.5, fract(y / 0.12)), 0.5, 1.0 - vis(0.12, fp));
    alb *= 1.0 - lv * (0.3 + 0.35 * sl);
    // roof lights washing up the walls
    e += alb * float3(1.0, 0.75, 0.5) * (0.15 + 0.6 * step(fract(b.id * 29.0), 0.4)) * exp(-y / 1.5) * (0.4 + 0.6 * U.music2.w);
    // a lit window strip on penthouses of the taller towers
    if (b.top > 45.0 && fract(b.id * 41.0) < 0.6 && lv < 0.5) {
        float wx = fract(uc / 1.6 + 0.5);
        float win = lineMask(abs(wx - 0.5) * 1.6, 0.55, fp) * lineMask(abs(y - 1.6), 0.6, fp) * step(abs(uc), 0.5 * wdt - 0.8);
        float on = step(h01(int2(int(floor(uc / 1.6 + 0.5)), int(b.id * 9999.0)), 61u), 0.5 * U.music2.w + 0.1);
        e += float3(1.0, 0.6, 0.28) * win * on * 0.45;
    }
    // a door on one face, a lamp above it and its pool of light on the wall
    bool doorFace = xF == (fract(b.id * 11.3) < 0.5) && ((h.n.x + h.n.z > 0.0) == (fract(b.id * 5.7) < 0.5));
    if (doorFace && wdt > 3.0) {
        float dx = uc - 0.25 * wdt;
        float door = lineMask(abs(dx), 0.5, fp) * (1.0 - smoothstep(2.1 - fp, 2.1 + fp, y));
        alb = mix(alb, float3(0.035), door);
        float2 dd = float2(dx, y - 2.35);
        float r = 0.12 + fp;
        e += float3(1.0, 0.75, 0.45) * (exp(-dot(dd, dd) / (r * r)) * min(1.0, 0.015 / (r * r)) * 2.0 + alb * 5.0 * exp(-dot(dd, dd) / 1.2));
    }
    return e;
}

/// Balconies (real geometry): concrete slab edges, a tiled floor, a pale soffit with now and then a lamp, the
/// balustrade frosted glass with the room's light behind it or dark railing bars in front of the dim balcony.
static float3 balconyShade(float3 p, Hit h, Bld b, Look k, constant CityU& U, float fp, thread float3& alb, thread float& glass) {
    float fh = b.bal.y, y0 = b.bal.z;
    bool ax = b.bal.x > 0.0;
    float u = ax ? p.z : p.x;
    int cellU = ax ? U.cell.y : U.cell.x;
    float uW = u + float(imod(cellU, 256)) * C;
    float a = ax ? p.x : p.z;
    float cA = ax ? 0.5 * (b.fp.x + b.fp.z) : 0.5 * (b.fp.y + b.fp.w);
    float hw = ax ? 0.5 * (b.fp.z - b.fp.x) : 0.5 * (b.fp.w - b.fp.y);
    float outD = abs(a - cA) - hw;                 // distance out from the facade
    float yr = p.y - h.boxTop;                      // height above this floor's slab top
    int row = int(floor((h.boxTop - y0) / fh + 0.5)) + (a < cA ? 3001 : 0);
    float bay = C / float(k.nb);
    int col = int(floor(uW / bay));
    float3 conc = mix(k.wall, float3(0.15, 0.148, 0.14), 0.6);
    float3 warm = mix(float3(1.0, 0.55, 0.22), U.colC.rgb, U.cfg2.w * 0.4);
    float lit = step(h01(int2(col, row), 131u), 0.35 * U.music2.w);
    float3 e = float3(0.0);
    glass = 0.0;
    if (h.n.y < -0.5) {                             // soffit, sometimes a lamp
        alb = conc * 0.9;
        int lc = int(floor(uW / (2.0 * bay)));
        if (h01(int2(lc, row), 133u) < 0.3) {
            float2 d2 = float2((fract(uW / (2.0 * bay)) - 0.5) * 2.0 * bay, outD - 0.5 * abs(b.bal.x));
            float r = 0.08 + fp;
            e += float3(1.0, 0.75, 0.45) * (exp(-dot(d2, d2) / (r * r)) * min(1.0, 0.0064 / (r * r)) * 3.0 + conc * 1.5 * exp(-dot(d2, d2) / 0.8))
               * (0.3 + 0.7 * U.music2.w);
        }
        return e;
    }
    if (h.n.y > 0.5) {                              // floor tiles / balustrade top
        float tile = mix(step(0.5, fract(uW / 0.4)) * 0.2 + 0.9, 1.0, 1.0 - vis(0.4, fp));
        alb = outD > abs(b.bal.x) - 0.08 ? conc * 1.1 : float3(0.075, 0.07, 0.065) * tile;
        return e;
    }
    if (yr < 0.0) { alb = conc * 1.15; return e; }  // slab edge
    float3 behind = warm * 0.06 * lit;              // the lit room behind, seen through the balustrade
    if (h01(b.owner, 45) < 0.5) {
        // frosted glass panels in a thin metal frame
        float frame = max(lineMask(abs(yr - BAL_RAIL + 0.03), 0.03, fp), lineMask(abs(fract(uW / 1.6 + 0.5) - 0.5) * 1.6, 0.025, fp));
        alb = mix(float3(0.035, 0.045, 0.045), float3(0.05), frame);
        e = behind * 2.2 * (1.0 - frame) + warm * 0.004;
        glass = 0.35 * (1.0 - frame);
    } else {
        // railing: hand rail, bottom rail and bars; behind them the dim balcony
        float post = lineMask(abs(fract(uW / 0.12 + 0.5) - 0.5) * 0.12, 0.012, fp);
        post = mix(post, 0.2, 1.0 - vis(0.12, fp));
        float rails = max(lineMask(abs(yr - BAL_RAIL + 0.03), 0.035, fp), lineMask(abs(yr - 0.1), 0.025, fp));
        float c = max(post, rails);
        alb = mix(k.wall * 0.35, float3(0.03, 0.03, 0.034), c);
        e = behind * (1.0 - c);
    }
    return e;
}

/// The ground: streets (asphalt, lane marks, cross walks, cars, lamp light pools), sidewalks, alleys and parks.
/// `gi` = global illumination there (rgb, how much of it is known; a = 0: the old stand-in for bounce light).
static float3 ground(float3 p, Hit h, float3 rd, constant CityU& U, constant float4* L, float fp, thread float& wetOut, bool cheap, float4 gi) {
    int2 wc = U.cell.xy + h.cell;
    int2 blk = blockOf(wc);
    int2 k = wc - blk * PER;
    float2 o = float2(h.cell) * C;
    float2 lp = p.xz - o;          // 0…16 inside the lot
    bool street = k.x == PER - 1 || k.y == PER - 1;
    float3 alb = float3(0.07, 0.068, 0.075);
    float3 e = float3(0.0);
    // puddles in world coordinates (448 and 1760 cells per 4096 m wrap); with p.xz they jumped 16 m whenever the camera
    // entered the next lot and seemed to drift like cloud shadows
    float2 pw = worldXZ(p, U);
    float wetMask = U.cfg.y * (0.3 + 0.7 * smoothstep(0.42, 0.62, vnoiseP(pw * 0.109375, 448) * 0.7 + vnoiseP(pw * 0.4296875, 1760) * 0.3));
    if (street) {
        // sidewalks along the blocks (2.5 m), the road in between
        float side = min(k.x == PER - 1 ? min(lp.x, C - lp.x) : 1e3, k.y == PER - 1 ? min(lp.y, C - lp.y) : 1e3);
        bool inter = k.x == PER - 1 && k.y == PER - 1;
        float along0 = k.x == PER - 1 ? pw.y : pw.x;
        if (!inter && side < 2.5) {
            // sidewalk: slabs with joints, a stone kerb at the road edge
            alb = float3(0.14, 0.135, 0.14) * (0.9 + 0.2 * vnoiseM(pw * 2.0, 8191));
            float j = max(lineMask(abs(fract(along0 / 1.5 + 0.5) - 0.5) * 1.5, 0.012, fp), lineMask(abs(fract(side / 1.2 + 0.5) - 0.5) * 1.2, 0.012, fp));
            alb *= 1.0 - 0.4 * j * vis(0.08, fp);
            float kerb = smoothstep(2.28 - fp, 2.3 + fp, side);
            alb = mix(alb, float3(0.19, 0.185, 0.18), kerb);
            wetMask *= 0.6;
        } else {
            // asphalt: worn patches, sealed cracks, darker polished wheel tracks, a wet gutter along the kerb
            float across0 = k.x == PER - 1 ? lp.x : lp.y;
            alb *= 0.8 + 0.4 * vnoiseM(pw * 0.5, 2047);
            float patchN = vnoiseM(pw * 0.125, 511);
            alb *= 1.0 - 0.25 * smoothstep(0.62, 0.64, patchN);
            float crack = (1.0 - smoothstep(0.0, 0.004 + 0.5 * fp, abs(vnoiseM(pw * 1.0, 4095) - 0.5)))
                        * smoothstep(0.55, 0.75, vnoiseM(pw * 0.25 + 9.0, 1023)) * vis(0.08, fp);
            alb *= 1.0 - 0.3 * crack;
            if (!inter) {
                float ln = fract((across0 - 2.5) / 2.75);
                float track = lineMask(abs(abs(ln - 0.5) - 0.24) * 2.75, 0.3, fp);
                alb *= 1.0 - 0.18 * track;
                wetMask = min(1.0, wetMask + 0.25 * U.cfg.y * track);
                float gut = lineMask(abs(min(across0, C - across0) - 2.75), 0.3, fp);
                wetMask = max(wetMask, U.cfg.y * 0.95 * gut);
            }
            // lane marks: dashed lines between lanes, a double yellow line in the middle
            float across = k.x == PER - 1 ? lp.x : lp.y, along = k.x == PER - 1 ? pw.y : pw.x;
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
    if (street) lit += carLight(p, h.cell, U);
    // bounce light from the lit facades down into the canyon; darker where the ground meets the walls
    float edge = street ? min(k.x == PER - 1 ? min(lp.x, C - lp.x) : 1e3, k.y == PER - 1 ? min(lp.y, C - lp.y) : 1e3) : 0.6;
    float ao = 0.45 + 0.55 * smoothstep(0.0, 4.0, edge);
    lit += mix((float3(0.03, 0.024, 0.02) + fogTint(U) * 0.15) * (0.5 + U.cfg3.x) * ao, gi.rgb, gi.a);
    return alb * (1.0 - 0.5 * wetMask) * lit * ao + e;
}

/// Glow of the drones and searchlights along a ray up to `tEnd` (cores + their halo in the haze).
static float3 rayGlow(float3 ro, float3 rd, float tEnd, constant CityU& U, constant float4* L, float fpAng) {
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
        // core (only if in front of the surface; beyond 16 core radii exp() < 1e-7: nothing to add)
        if (bb > 0.0 && bb < tEnd) {
            float r = 0.9 + fpAng * bb;
            if (h2 < 16.0 * r * r) g += b.rgb * b.w * 0.02 * exp(-h2 / (r * r)) * min(1.0, 0.81 / (r * r));
        }
        // in-scattering in the haze: ∫ 1 / (h² + (t − b)²) dt from 0 to tEnd = (atan((tEnd − b) / h) − atan(−b / h)) / h,
        // as one atan2 (atan x − atan y = atan2(x − y, 1 + x·y) on the whole range; both arguments × h²)
        float sc = atan2(tEnd * hh, h2 - (tEnd - bb) * bb) / hh;
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

// Two passes. `cityFrag` traces the primary ray and shades it; what it can't finish (the one reflection ray of window
// glass and wet streets, the haze, the drone / searchlight glow and the tone mapping) goes into a small G-buffer, and
// `cityReflShade` + `cityFinal` do that. Split, each shader gets its own register budget: as one shader the reflection code alone
// (even where no ray was traced) made the whole pass ~50 % slower (fewer pixels in flight). Keeping the G-buffer in
// tile memory (memoryless + framebuffer fetch) was tried: ~5 % slower than these plain textures (smaller tiles).
struct CityG {
    float4 col [[color(0)]];    // rgb = shaded colour (before haze / tone mapping, incl. lamps and the untraced part
                                // of the reflection), a = distance (negative: the ray hit nothing = sky)
    float4 rO [[color(1)]];     // reflection ray origin, w = footprint (m per pixel) it starts with
    float4 rD [[color(2)]];     // reflection ray direction, w = cone (window glass) or −1 (wet street)
    float4 rW [[color(3)]];     // weight of the traced reflection (rgb; a = 1 when there is a ray to trace)
};

/// Global illumination (LandGI) at p for normal n: (irradiance in this scene's lighting units, how much is known).
/// GI space = metres from the camera's lot corner, anchored at that lot (G.anchor).
#define GI_TEX gi0, gi1, gi2, gi3
static float4 giAt(float3 p, float3 n, constant CityU& U, constant GIView& G, texture3d<float> g0, texture3d<float> g1,
                   texture3d<float> g2, texture3d<float> g3) {
    if (G.cam.w <= 0.0) return float4(0.0);
    float4 e = giIrradiance(p, p - U.cam.xyz, n, G, g0, g1, g2, g3);
    return float4(e.rgb * G.horizon.w, e.a);
}

/// The primary ray of a pixel (shared by the three passes).
static float3 primaryDir(float2 uv, constant CityU& U) {
    float2 ndc = float2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
    return normalize(U.fwd.xyz + U.right.xyz * ndc.x * U.right.w + U.up.xyz * ndc.y * U.up.w);
}
/// Where the haze has (almost) hidden everything: the walks stop there.
static float hazeFar(float3 ro, constant CityU& U) {
    float densE = (0.00025 + 0.0022 * U.cfg.w) * (1.0 + 4.0 * U.cfg3.x) * exp(-max(1.0, ro.y) / (260.0 + 200.0 * U.cfg3.x));
    return clamp(3.2 / densE, 400.0, 2600.0);
}

/// Pass 1: only the walk of the primary ray (kept apart from the shading, it runs with far more pixels in flight: the
/// walk alone took ~2.4× as long inside the big shading shader). Writes what it found: distance, street lamp glow
/// passed on the way, and the lot (+ hit kind) for `cityFrag`, which works the exact hit out again from that one lot.
fragment float4 cityWalk(VOut in [[stage_in]], constant CityU& U [[buffer(0)]]) {
    float3 rd = primaryDir(in.uv, U);
    float3 ro = U.cam.xyz;
    float lamps = 0.0;
    Hit h = trace(ro, rd, 220, hazeFar(ro, U), U, true, lamps, U.fwd.w);
    return float4(h.t, lamps, float(h.cell.x * 4 + h.kind), float(h.cell.y));
}

/// The full hit of a primary ray, from what `cityWalk` found: the nearest box of that lot's building or cars again
/// (the same tests the walk made, limited to just past its distance).
static Hit primaryHit(float4 w, float3 ro, float3 rd, constant CityU& U, bool det = true) {
    Hit h; h.t = w.x; h.n = float3(0, 1, 0); h.boxTop = 0; h.box = float4(0); h.part = 0; h.sub = 0;
    int cx4 = int(w.z);
    h.kind = cx4 & 3;
    h.cell = int2((cx4 - h.kind) / 4, int(w.w));
    if (h.kind >= 2) {
        float3 ird = 1.0 / float3(abs(rd.x) < 1e-6 ? 1e-6 : rd.x, abs(rd.y) < 1e-6 ? 1e-6 : rd.y, abs(rd.z) < 1e-6 ? 1e-6 : rd.z);
        float tLim = h.t * 1.0001 + 2e-3;
        Hit bh;
        int2 lb = int2(1 << 30); float lD = 0.0;
        bool ok = h.kind == 2 ? hitBld(building(h.cell, U, lb, lD, -1e9, det), ro, ird, tLim, bh) : carsHit(h.cell, ro, ird, tLim, U, bh);
        if (ok) { bh.kind = h.kind; bh.cell = h.cell; return bh; }
    }
    return h;
}

/// Pass 2: shading of the primary hit.
fragment CityG cityFrag(VOut in [[stage_in]], constant CityU& U [[buffer(0)]], constant float4* L [[buffer(1)]],
                        texture2d<float> walkTex [[texture(0)]], constant GIView& G [[buffer(2)]],
                        texture3d<float> gi0 [[texture(1)]], texture3d<float> gi1 [[texture(2)]],
                        texture3d<float> gi2 [[texture(3)]], texture3d<float> gi3 [[texture(4)]]) {
    float3 rd = primaryDir(in.uv, U);
    float3 ro = U.cam.xyz;
    float fpAng = U.fwd.w;
    CityG g;
    g.rO = float4(0.0); g.rD = float4(0.0); g.rW = float4(0.0);
    float4 w = walkTex.read(uint2(in.pos.xy));
    float lamps = w.y;
    Hit h = primaryHit(w, ro, rd, U);
    if (U.cfg3.y == 1.0) { g.col = float4(float3(h.kind == 2 ? 0.5 : h.kind == 1 ? 0.2 : 0.0) * exp(-h.t / 500.0), 0.0); return g; }
    float3 col;
    float t = h.t;
    float3 p = ro + rd * t;
    float fp = t * fpAng;
    int2 lb = int2(1 << 30); float lD = 0.0;
    // one reflection ray, shared by window glass and wet streets
    float3 rW = float3(0.0);      // its weight (Fresnel × coverage × tint)
    float3 rO = float3(0.0), rD = float3(0.0, 1.0, 0.0);
    float rFp = 0.0, rNear = 1e9, rCone = 0.0;
    bool rWindow = false;
    float gloom = U.cfg3.x;
    float reflAmt = U.cfg3.z;
    if (h.kind == 2) {
        Bld b = building(h.cell, U, lb, lD);
        bldLook(b);
        Look k = lookOf(b, U.cfg4.x);
        float glass, wallMul;
        float3 spill;
        float2 jit;
        float3 alb;
        float3 e;
        float3 nB = h.n;
        bool isRoof = h.n.y > 0.5;
        if (h.sub == 2) { e = balconyShade(p, h, b, k, U, fp, alb, glass); spill = float3(0.0); jit = float2(0.0); }
        else if (h.n.y < -0.5) { alb = k.wall * 0.6; e = float3(0.0); glass = 0.0; spill = float3(0.0); jit = float2(0.0); }   // cornice soffit
        else if (h.part == 4) { e = roofBox(p, h, b, U, fp, alb); glass = 0.0; spill = float3(0.0); jit = float2(0.0); }
        else if (isRoof) { e = roof(p, h, b, U, fp, alb); glass = 0.0; spill = float3(0.0); jit = float2(0.0); }
        else {
            float4 ov;
            e = facade(p, h.n, rd, h, b, k, U, fp, glass, spill, wallMul, jit, nB, ov);
            alb = mix(k.wall * wallMul, ov.rgb, ov.a);
        }
        float3 lit = lighting(p, nB, U, L, false);
        // soft bounce light (a cheap stand-in for global illumination): light spilling out of the windows onto the
        // wall around them, the warm glow of the lit street rising up the lower floors, the haze's own glow
        float ao = 0.35 + 0.65 * smoothstep(0.0, 18.0, p.y);
        float3 streetGlow = mix(float3(1.0, 0.6, 0.32), U.colC.rgb, U.cfg2.w * 0.5) * 0.05 * exp(-p.y / 22.0);
        // with global illumination on, the real bounce (from the GI probes) replaces the street glow / haze stand-in
        float4 gi = giAt(p, nB, U, G, GI_TEX);
        lit += spill * 1.6 * (0.5 + gloom) * ao + mix((streetGlow + fogTint(U) * 0.15) * (0.5 + gloom) * ao, gi.rgb, gi.a);
        col = alb * lit * (0.4 + 0.6 * smoothstep(0.0, 14.0, p.y)) + e;
        if (glass > 0.0) {
            // the glass mirrors the city: each pane tilted a little (jit) so the image breaks up like real glass
            float3 tU = abs(h.n.x) > 0.5 ? float3(0, 0, 1) : float3(1, 0, 0);
            // Reflection blur: everything the ray hits is shaded with a cone's footprint (window grids and lights fade to
            // soft averages), the panes tilt more, and a small per-pixel jitter softens the edges (a bigger one only
            // made speckles: one ray per pixel)
            float blur = U.cfg3.w;
            jit *= 1.0 + 0.8 * blur;   // was 0.035 / 0.05 × (1 + 2.5·blur): bright drones broke into pane-sized blocks ("pixelated")
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
                rO = p + h.n * 0.05; rD = r; rFp = t * fpAng; rNear = 220.0; rWindow = true;
            }
        }
    } else if (h.kind == 1) {
        float wet;
        col = ground(p, h, rd, U, L, fp, wet, false, giAt(p, float3(0, 1, 0), U, G, GI_TEX));
        if (wet > 0.01) {
            // wet streets: puddle ripples with the treble (two octaves; faded out before they get smaller than a pixel,
            // single-octave value noise showed its square lattice as blocky smears in the reflections)
            float2 wq = worldXZ(p, U);
            float2 rp = wq * 3.0 + float2(U.cam.w * 0.6, 0.0), rp2 = wq * 7.0 + float2(0.0, U.cam.w * 0.9);
            float amp = (0.01 + 0.04 * U.music.z) * vis(0.33, fp), amp2 = 0.5 * (0.01 + 0.04 * U.music.z) * vis(0.14, fp);
            float3 n = normalize(float3((vnoiseP(rp, 12288) - 0.5) * amp + (vnoiseP(rp2, 28672) - 0.5) * amp2, 1.0,
                                        (vnoiseP(rp + 17.0, 12288) - 0.5) * amp + (vnoiseP(rp2 + 5.0, 28672) - 0.5) * amp2));
            float F = 0.04 + 0.96 * pow(1.0 - max(dot(-rd, n), 0.0), 5.0);
            rW = float3(wet * (0.12 + 0.88 * F));
            rO = p + float3(0, 0.02, 0); rD = reflect(rd, n); rFp = 10.0;
            // roughness: damp asphalt scatters the reflection, standing water much less. The ray itself is not jittered
            // (one ray per pixel turned that into speckles): cityFinal blurs it by roughness × reflected distance
            float rough = mix(0.035, 0.008, smoothstep(0.45, 0.9, wet / max(U.cfg.y, 1e-3)));
            rCone = rough;
        }
    } else if (h.kind == 3) {
        col = carShade(p, h, U, fp);
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
            // traced by cityReflWalk / cityReflShade; the faded-out part of it stays the sky / haze
            col += rc * rW * farW;
            g.rO = float4(rO, rFp);
            g.rD = float4(rD, rWindow ? rCone : -1.0 - rCone);
            g.rW = float4(rW * (1.0 - farW), 1.0);
        } else {
            col += rc * rW;
        }
    }
    // street lamp heads seen on the way
    col += float3(1.0, 0.7, 0.4) * lamps;
    g.col = float4(col, h.kind == 0 ? -t : t);
    if (G.ground.w > 0.5 && (h.kind == 1 || h.kind == 2)) {
        // debug (AUDIOWATCH_GI_DEBUG=1): only the GI light, on grey (GI off: the old bounce stand-ins' level)
        float4 gg = giAt(p, h.kind == 1 ? float3(0, 1, 0) : h.n, U, G, GI_TEX);
        g.col.rgb = 0.5 * mix(float3(0.02), gg.rgb, gg.a);
        g.rW = float4(0.0);
    }
    return g;
}

/// Pass 3: the walk of the reflection rays (where there is one), apart from their shading for the same reason as
/// `cityWalk`. Same output as `cityWalk`.
fragment float4 cityReflWalk(VOut in [[stage_in]], constant CityU& U [[buffer(0)]],
                             texture2d<float> g2 [[texture(1)]], texture2d<float> g3 [[texture(2)]], texture2d<float> g4 [[texture(3)]]) {
    uint2 pi = uint2(in.pos.xy);
    if (g4.read(pi).a < 0.5) return float4(0.0);
    float4 o = g2.read(pi), d = g3.read(pi);
    bool rWindow = d.w >= 0.0;
    float lamps = 0.0;
    Hit h = trace(o.xyz, d.xyz, rWindow ? 18 : 56, min(rWindow ? 350.0 : 700.0, hazeFar(U.cam.xyz, U)), U, false, lamps, U.fwd.w, false);
    return float4(h.t, 0.0, float(h.cell.x * 4 + h.kind), float(h.cell.y));
}

/// Pass 4: shading of the reflection hits. Writes the reflected radiance (before its weight) and the reflected
/// distance, signed: > 0 wet street, < 0 window glass, 0 = no traced reflection here.
fragment float4 cityReflShade(VOut in [[stage_in]], constant CityU& U [[buffer(0)]], constant float4* L [[buffer(1)]],
                              texture2d<float> g1 [[texture(0)]], texture2d<float> g2 [[texture(1)]],
                              texture2d<float> g3 [[texture(2)]], texture2d<float> g4 [[texture(3)]],
                              texture2d<float> reflWalk [[texture(4)]]) {
    uint2 pi = uint2(in.pos.xy);
    CityG g;
    g.rW = g4.read(pi);
    if (g.rW.a < 0.5 || U.cfg3.y == 1.0) return float4(0.0);
    g.col = g1.read(pi); g.rO = g2.read(pi); g.rD = g3.read(pi);
    float fpAng = U.fwd.w;
    float haze = U.cfg.w;
    float gloom = U.cfg3.x;
    float t = abs(g.col.a);
    {
        float3 rW = g.rW.rgb;
        float3 rO = g.rO.xyz, rD = g.rD.xyz;
        float rFp = g.rO.w;
        bool rWindow = g.rD.w >= 0.0;
        float rCone = rWindow ? g.rD.w : 0.0;
        float rMax = rWindow ? 350.0 : 700.0;
        float starR = 1.0 - 3.3 * rCone;
        int2 lb = int2(1 << 30); float lD = 0.0;
        float3 rc;
        float lamps2 = 0.0;
        Hit h2 = primaryHit(reflWalk.read(pi), rO, rD, U, false);   // (what cityReflWalk found)
        if (h2.kind == 0 && rD.y < 0.25) h2.t = max(h2.t, rMax);   // ran out: the haze hides the rest
        float3 p2 = rO + rD * h2.t;
        float fp2 = max(rFp, (t + h2.t) * fpAng + h2.t * rCone);
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
            rc = sky(rD, U, starR);
        }
        rc += float3(1.0, 0.7, 0.4) * lamps2;
        float d2 = (0.00025 + 0.0022 * haze) * (1.0 + 4.0 * gloom) * exp(-max(1.0, rO.y + rD.y * min(h2.t, 1500.0) * 0.5) / (260.0 + 200.0 * gloom));
        rc = mix(rc, fogTint(U), 1.0 - exp(-min(h2.t, 3000.0) * d2 * (h2.kind == 0 ? 0.6 : 1.0)));
        rc += rayGlow(rO, rD, h2.t, U, L, fpAng * 3.0 + rCone);
        (void)rW;
        return float4(rc, max(min(h2.t, 3000.0), 0.01) * (rWindow ? -1.0 : 1.0));
    }
}

/// Pass 5: the reflections filtered (one jittered ray per pixel → a soft glossy reflection), haze, glow, tone mapping.
/// The filter's size follows the reflection's real blur: roughness × reflected distance, seen from the camera (contact
/// reflections stay sharp, far ones go soft); wet streets smear vertically. Neighbours only count when they are the
/// same kind of surface at about the same distance.
fragment float4 cityFinal(VOut in [[stage_in]], constant CityU& U [[buffer(0)]], constant float4* L [[buffer(1)]],
                          texture2d<float> g1 [[texture(0)]], texture2d<float> g3 [[texture(2)]],
                          texture2d<float> g4 [[texture(3)]], texture2d<float> refl [[texture(5)]]) {
    uint2 pi = uint2(in.pos.xy);
    float4 c1 = g1.read(pi);
    if (U.cfg3.y == 1.0) return float4(c1.rgb, 1.0);
    float3 rd = primaryDir(in.uv, U);
    float3 ro = U.cam.xyz;
    float fpAng = U.fwd.w;
    float haze = U.cfg.w;
    float gloom = U.cfg3.x;
    float3 col = c1.rgb;
    bool skyHit = c1.a < 0.0;
    float t = abs(c1.a);
    float4 w4 = g4.read(pi);
    if (w4.a > 0.5) {
        float4 r0 = refl.read(pi);
        float4 d3 = g3.read(pi);
        bool street = d3.w < 0.0;
        float rough = street ? -1.0 - d3.w : d3.w + 0.006 + 0.03 * U.cfg3.w;
        float dR = abs(r0.a);
        float H = float(g1.get_height());
        float px = clamp(1.3 * rough * dR / ((t + dR) * fpAng), 0.0, 0.04 * H);
        float2 R = street ? float2(0.45, 1.6) * px : float2(px);
        // weights × 1 / (1 + luminance): single bright samples (a lamp caught by one jittered ray) don't become speckles
        float w0 = 1.0 / (1.0 + dot(r0.rgb, float3(0.3, 0.55, 0.15)));
        float3 sum = r0.rgb * w0; float ws = w0;
#ifdef NO_FILT
        px = 0.0;
#endif
        if (px > 0.75) {
            float ang0 = 6.2831853 * fract(52.9829189 * fract(dot(in.pos.xy, float2(0.06711056, 0.00583715))));
            int2 mx = int2(g1.get_width(), g1.get_height()) - 1;
            for (int i = 0; i < 10; i++) {
                float rr = sqrt((float(i) + 0.5) / 10.0);
                float a = ang0 + float(i) * 2.39996323;
                int2 q = clamp(int2(pi) + int2(round(float2(cos(a), sin(a)) * R * rr)), int2(0), mx);
                float4 s = refl.read(uint2(q));
                if (s.a * r0.a <= 0.0) continue;                  // no reflection there, or the other kind
                float tq = abs(g1.read(uint2(q)).a);
                float w = exp(-abs(tq - t) / (0.03 * t + 0.15)) * (1.0 - 0.5 * rr) / (1.0 + dot(s.rgb, float3(0.3, 0.55, 0.15)));
                sum += s.rgb * w; ws += w;
            }
        }
        col += sum / ws * w4.rgb;
    }
    // night haze: thicker low down, glowing with the city's light pollution
    float dens = (0.00025 + 0.0022 * haze) * (1.0 + 4.0 * gloom);
    float yAvg = max(1.0, ro.y + rd.y * min(t, 1500.0) * 0.5);
    float fog = 1.0 - exp(-min(t, 3000.0) * dens * exp(-yAvg / (260.0 + 200.0 * gloom)) * (skyHit ? 0.6 : 1.0));
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
