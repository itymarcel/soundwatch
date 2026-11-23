// MSL for the Forest mode (ForestGPU), compiled at runtime into its own library.
// World units are metres, y up, the camera flies towards −z. Everything repeats every 8192 m in z (the noise texture
// tiles, the valley's curve and the tree hashes do too), so the camera's z wraps without a jump. Positions are
// handled relative to the camera (`rel`), the absolute world position only for noise lookups.
let forestShaderSource = #"""
#include <metal_stdlib>
using namespace metal;
//@GI_CORE@

// Must match ForestUniforms in ForestGPU.swift (all 16-byte aligned).
struct ForestU {
    float4x4 viewProj;     // camera-relative world → clip (reversed Z: near = 1, infinitely far = 0)
    float4x4 shadow0;      // camera-relative world → light clip, cascade 0 (near) / 1 (far)
    float4x4 shadow1;
    float4 cam;            // camera world position, time
    float4 sun;            // direction to the sun, intensity
    float4 sunCol;         // rgb, beat
    float4 zenith;         // rgb, mist
    float4 horizon;        // rgb, cloud cover
    float4 music;          // gust (bass push on the trees), shimmer (treble flutter), level, band light
    float4 wind;           // direction xz, strength, palette tint
    float4 planes[4];      // view frustum side planes (camera-relative), widened for shadow casters
    float4 cfg;            // tree density, view distance, tree cell size, band count
    float4 lod;            // tree LOD 0 / 1 distances, shadow 0 / 1 half sizes
    float4 fwd;            // camera forward, exposure
    int4 cell;             // camera's tree cell (x, z), half the scatter grid, unused
    float4 seasonA;        // snow cover, broadleaf foliage, autumn colour, spring's fresh green
    float4 seasonB;        // meadow flowers, blossom, dry grass, river ice
    float4 seasonC;        // late flowers (colour mix), temperature (−1 … 1), rain wetness, leaf litter
    float4 precip;         // falling rain, snow, leaves, petals (0 … 1 each)
    float4 drift;          // wind drift xz (metres so far), wind velocity xz (m/s)
    float4 vel;            // camera velocity xyz (m/s), radians per pixel
    float4 night;          // night (0 day … 1), unused
};

constant float3 SNOW = float3(0.74, 0.77, 0.82);

struct TreeV { float4 p; float4 n; float4 u; };     // p.xyz unit-height position, n.xyz normal + ao, u = uv, sway, phase
struct TreeI { float4 p; float4 q; float4 f; };    // p = foot (world) + height; q = turn, random, band, species;
                                                   // f = fade: threshold, side (+1 near LOD / −1 far LOD), visibility
struct NodeI { float4 o; };                        // terrain patch: origin x z, size, LOD level

constant float WP = 8192.0;                        // world period in z
constant float WATER = 0.0;
constant uint CAP[4] = { 4000, 12000, 20000, 60000 };   // instances per (species, LOD)

constexpr sampler nrep(filter::linear, mip_filter::none, address::repeat);
constexpr sampler linMip(filter::linear, mip_filter::linear, address::clamp_to_edge, max_anisotropy(8));
constexpr sampler shadowS(coord::normalized, filter::linear, address::clamp_to_edge, compare_func::less_equal);

// ---------------------------------------------------------------- noise and terrain

/// The noise texture: periodic Perlin noise, 32 cells per tile; (value, d/dx, d/dy in cell units, a second noise).
static float4 nz(texture2d<float> T, float2 p) { return T.sample(nrep, p * (1.0 / 32.0), level(0.0)); }

static float fh(int2 c, uint s) {
    uint n = uint(c.x) * 1597334677u ^ uint(c.y) * 3812015801u ^ s * 2654435761u;
    n = (n ^ (n >> 16)) * 2246822519u; n ^= n >> 13; n *= 3266489917u; n ^= n >> 16;
    return float(n) * (1.0 / 4294967295.0);
}

/// The river valley's middle line, x as a function of z (same in ForestViz.valley).
static float valley(float z) {
    float k = 6.2831853 / WP;
    return 45.0 * sin(z * k * 3.0) + 22.0 * sin(z * k * 7.0 + 1.0) + 9.0 * sin(z * k * 17.0 + 2.0);
}
static float valleyD(float z) {
    float k = 6.2831853 / WP;
    return 45.0 * 3.0 * k * cos(z * k * 3.0) + 22.0 * 7.0 * k * cos(z * k * 7.0 + 1.0) + 9.0 * 17.0 * k * cos(z * k * 17.0 + 2.0);
}

static float2 sstep(float a, float b, float x) {   // smoothstep and its derivative
    float t = clamp((x - a) / (b - a), 0.0, 1.0);
    return float2(t * t * (3.0 - 2.0 * t), 6.0 * t * (1.0 - t) / (b - a));
}

/// Eroded fbm (each octave damped where the ones before are steep: ridges and gullies) → (value, gradient per metre).
static float3 fbmE(texture2d<float> T, float2 xz, int oct) {
    float2 p = xz / 256.0;
    float a = 0.0, b = 0.5, f = 1.0;
    float2 d = 0.0, g = 0.0;
    for (int i = 0; i < oct; i++) {
        float4 n = nz(T, p * f + float2(0.37, 0.71) * float(i));
        d += n.yz;
        float e = 1.0 / (1.0 + dot(d, d));
        a += b * n.x * e;
        g += b * n.yz * f * e;
        b *= 0.5; f *= 2.0;
    }
    return float3(a, g / 256.0);
}

/// The river: its middle line wanders off the valley's line (6 m either way) and its width changes along it
/// (same in ForestTerrain.swift).
static float riverWidth(texture2d<float> T, float z) { return 6.5 + 3.5 * nz(T, float2(z / 110.0, 7.7)).w; }

/// Distance from the river's middle to a frayed edge: inlets, points and roots every few metres. width = its width there.
static float riverDist(texture2d<float> T, float2 xz, thread float &width, thread float2 &grad) {
    float4 ro = nz(T, float2(xz.y / 160.0, 3.3));
    float rc = valley(xz.y) + 6.0 * ro.x, drc = valleyD(xz.y) + 6.0 * ro.y / 160.0;
    width = riverWidth(T, xz.y);
    float dx = xz.x - rc, sx = dx < 0.0 ? -1.0 : 1.0;
    float4 b1 = nz(T, xz / 7.0 + 2.1), b2 = nz(T, xz / 2.3 + 5.7);
    grad = float2(sx, -sx * drc) + 2.0 * b1.yz / 7.0 + 0.6 * b2.yz / 2.3;
    return abs(dx) + 2.0 * b1.x + 0.6 * b2.x;
}

/// Ground height and its gradient: a river bed in the valley, a meadow beside it, wooded hills rising beyond.
static float3 terrain(texture2d<float> T, float2 xz, int oct, thread float &ae, thread float &width) {
    float2 dae;
    ae = riverDist(T, xz, width, dae);
    float2 bed = sstep(width * 0.5, width * 1.35, ae);
    float vx = valley(xz.y), dv = valleyD(xz.y);
    float dxv = xz.x - vx, sv = dxv < 0.0 ? -1.0 : 1.0;
    // In the river bed and on its banks the hills (w = 0) and the meadow's bumps (und = 0) are both switched off:
    // the fbm's octaves would be multiplied by zero, so they aren't sampled at all (same result, much cheaper).
    if (ae <= width * 1.6 && abs(dxv) <= 30.0) return float3(WATER - 2.4 + 3.4 * bed.x, 3.4 * bed.y * dae);
    float3 f = fbmE(T, xz, oct);
    float u = clamp(f.x + 0.42, 0.0, 1.5);
    float hh = 180.0 * u * u;
    float2 gh = f.yz * (f.x + 0.42 > 0.0 ? 360.0 * u : 0.0);
    float2 und = sstep(width * 1.6, 45.0, ae);
    float m = WATER - 2.4 + 3.4 * bed.x + 7.0 * f.x * und.x;
    float2 gm = 3.4 * bed.y * dae + 7.0 * (f.yz * und.x + f.x * und.y * dae);
    float2 w = sstep(30.0, 150.0, abs(dxv));
    return float3(m + hh * w.x, gm + gh * w.x + hh * w.y * float2(sv, -sv * dv));
}
static float3 terrain(texture2d<float> T, float2 xz, int oct) { float ae, width; return terrain(T, xz, oct, ae, width); }

// ---------------------------------------------------------------- light, sky, mist

static float3 tonemap(float3 c, float exposure) {
    c *= exposure;
    c = (c * (2.51 * c + 0.03)) / (c * (2.43 * c + 0.59) + 0.14);
    return pow(clamp(c, 0.0, 1.0), float3(1.0 / 2.2));
}

/// Tone mapping with the night's grade: moonlit scenes lose their colour and turn blue (the eye's rod vision),
/// so dim green meadows don't read as daylight.
static float3 tonemap(float3 c, constant ForestU& U) {
    float n = U.night.x;
    float l = dot(c, float3(0.22, 0.68, 0.1));
    c = mix(c, l * float3(0.62, 0.78, 1.15), 0.75 * n);
    return tonemap(c, U.fwd.w);
}
/// The same with light that keeps its colour through the night grade (the fireflies' light on the surfaces).
static float3 tonemap(float3 c, constant ForestU& U, float3 extra) {
    float n = U.night.x;
    float l = dot(c, float3(0.22, 0.68, 0.1));
    c = mix(c, l * float3(0.62, 0.78, 1.15), 0.75 * n) + extra;
    return tonemap(c, U.fwd.w);
}

static float3 skyColor(float3 V, constant ForestU& U, texture2d<float> T, bool clouds) {
    float3 L = U.sun.xyz;
    float y = V.y;
    float3 c = mix(U.horizon.rgb, U.zenith.rgb, pow(clamp(y, 0.0, 1.0), 0.45));
    if (y < 0.0) c = U.horizon.rgb * mix(1.0, 0.75, clamp(-y * 4.0, 0.0, 1.0));
    float s = max(dot(V, L), 0.0);
    c += U.sunCol.rgb * (pow(s, 6.0) * 0.25 + pow(s, 120.0) * 0.8);
    // stars at night (a hashed grid over the sky; each a soft dot of about a pixel, twinkling a little)
    if (U.night.x > 0.05 && y > 0.0) {
        float2 sp = float2(atan2(V.z, V.x), asin(clamp(y, 0.0, 1.0))) * 300.0;
        int2 cell = int2(floor(sp));
        float h = fh(cell, 41u);
        if (h > 0.975) {
            float2 off = float2(fh(cell, 42u), fh(cell, 43u)) * 0.6 + 0.2;
            float d = length(fract(sp) - off);
            float b = (h - 0.975) / 0.025;
            float tw = 0.75 + 0.25 * sin(U.cam.w * (2.0 + 3.0 * fh(cell, 44u)) + h * 80.0);
            c += float3(0.85, 0.9, 1.0) * exp(-d * d * 90.0) * (0.15 + 1.6 * b * b) * tw * smoothstep(0.05, 0.9, U.night.x) * smoothstep(0.0, 0.15, y);
        }
    }
    if (clouds && y > 0.0) {
        float2 cp = V.xz / (y + 0.06) * 0.9 + float2(U.cam.w * 0.004, U.cam.w * 0.0015);
        float n = 0.0, a = 0.55, fr = 1.0;
        float edge = 0.78 - 0.45 * U.horizon.w;
        for (int i = 0; i < 5; i++) {
            n += a * nz(T, cp * fr + 3.7 * float(i)).x; a *= 0.5; fr *= 2.03;
            // the noise is within ±1: once the octaves left (2a at most) can't lift it to the cover's edge, it's clear sky
            if (n + 0.5 + 2.0 * a <= edge) break;
        }
        float cov = smoothstep(edge, 1.08 - 0.35 * U.horizon.w, n + 0.5);
        if (cov <= 0.0) { c += U.sunCol.rgb * smoothstep(0.99965, 0.99985, s) * 30.0; return c; }
        float lit = 0.55 + 0.45 * smoothstep(-0.2, 0.3, nz(T, cp * 1.0 + 9.0 + L.xz * 0.3).x);
        float3 cc = mix(U.horizon.rgb * 0.7, float3(pow(0.06, U.night.x)), 0.45) * lit + U.sunCol.rgb * pow(s, 8.0) * 0.6;
        c = mix(c, cc, cov * smoothstep(0.0, 0.18, y) * 0.9);
    }
    c += U.sunCol.rgb * smoothstep(0.99965, 0.99985, s) * 30.0;     // the sun's disc
    return c;
}

/// How much of a surface's own light gets through the mist (1 − applyMist's blend).
static float mistT(float3 rel, constant ForestU& U) {
    float hgt = max(0.0, U.cam.y + rel.y * 0.5);
    float dens = (0.00025 + 0.0045 * U.zenith.w) * (exp(-hgt * 0.015) + 0.12);
    return exp(-length(rel) * dens);
}

/// Aerial perspective: mist thickening with distance, thinner higher up, glowing towards the sun.
static float3 applyMist(float3 c, float3 rel, constant ForestU& U) {
    float dist = length(rel);
    float3 V = rel / max(dist, 1e-3);
    float hgt = max(0.0, U.cam.y + rel.y * 0.5);
    float dens = (0.00025 + 0.0045 * U.zenith.w) * (exp(-hgt * 0.015) + 0.12);
    float a = 1.0 - exp(-dist * dens);
    float s = pow(max(dot(V, U.sun.xyz), 0.0), 8.0);
    float3 mc = mix(U.horizon.rgb, U.sunCol.rgb * 1.3, s * 0.5);
    return mix(c, mc, a);
}

/// Sun shadow from the two cascades (4 bilinear compare taps each, 1 with `taps1`: foliage hides the difference).
static float shadowAt(float3 rel, float3 N, constant ForestU& U, depth2d_array<float> S, bool taps1 = false) {
    float3 p = rel + N * 0.08 + U.sun.xyz * 0.05;
    float4 lc = U.shadow0 * float4(p, 1.0);
    uint layer = 0;
    float2 uv = lc.xy * float2(0.5, -0.5) + 0.5;
    float z = lc.z;
    float texel = 1.0 / 2048.0;
    if (any(uv < 0.02) || any(uv > 0.98) || z > 1.0) {
        lc = U.shadow1 * float4(p + N * 0.3, 1.0);
        uv = lc.xy * float2(0.5, -0.5) + 0.5;
        z = lc.z;
        layer = 1;
        if (any(uv < 0.0) || any(uv > 1.0) || z > 1.0) return 1.0;
    }
    float bias = layer == 0 ? 0.0004 : 0.0008;
    if (taps1) return S.sample_compare(shadowS, uv, layer, z - bias);
    float sh = 0.0;
    sh += S.sample_compare(shadowS, uv + float2(-0.75, -0.75) * texel, layer, z - bias);
    sh += S.sample_compare(shadowS, uv + float2(0.75, -0.75) * texel, layer, z - bias);
    sh += S.sample_compare(shadowS, uv + float2(-0.75, 0.75) * texel, layer, z - bias);
    sh += S.sample_compare(shadowS, uv + float2(0.75, 0.75) * texel, layer, z - bias);
    return sh * 0.25;
}

static float3 ambient(float3 N, constant ForestU& U) {
    float3 sky = U.zenith.rgb * 0.75 + U.horizon.rgb * 0.25;
    float3 ground = float3(0.09, 0.1, 0.06) * (0.3 + U.sun.w * 0.2) * pow(0.12, U.night.x);
    return mix(ground, sky, N.y * 0.5 + 0.5) * 0.5;
}

// Global illumination (LandGI): the flat ambient term above is replaced by the irradiance of the GI clipmap
// (sky light blocked by the canopy and the hills, light bounced off the meadows, glowing trees, fireflies),
// faded in where it's known. G.horizon.w = 0.5 (E/π → this ambient's scale) × intensity.
#define GI_FRAG_PARAMS constant GIView& G [[buffer(2)]], texture3d<float> gi0 [[texture(3)]], texture3d<float> gi1 [[texture(4)]], \
    texture3d<float> gi2 [[texture(5)]], texture3d<float> gi3 [[texture(6)]], texture3d<float> gi4 [[texture(7)]]
#define GI_TEX gi0, gi1, gi2, gi3
// debug (AUDIOWATCH_GI_DEBUG=1): only the ambient / GI light, on grey
#define GI_DEBUG_OUT(N) if (G.ground.w > 0.5) c = 0.5 * giAmbient(N, in.rel, U, G, GI_TEX);
static float3 giWorld(float3 rel, constant ForestU& U) {
    float3 wp = rel + U.cam.xyz;
    wp.z -= WP * floor(wp.z / WP);
    return wp;
}
static float3 giAmbient(float3 N, float3 rel, constant ForestU& U, constant GIView& G, texture3d<float> g0, texture3d<float> g1,
                        texture3d<float> g2, texture3d<float> g3) {
    float3 a = ambient(N, U);
    if (G.cam.w <= 0.0) return a;
    float4 e = giIrradiance(giWorld(rel, U), rel, N, G, g0, g1, g2, g3);
    return mix(a, e.rgb * G.horizon.w, e.a);
}
/// The fireflies' light at a point (kept apart: it keeps its colour through the night grade).
static float3 giFly(float3 rel, constant ForestU& U, constant GIView& G, texture3d<float> g0, texture3d<float> g4) {
    if (G.cam.w <= 0.0 || G.misc.y <= 0.0) return float3(0.0);
    return giPointLight(giWorld(rel, U), rel, G, g0, g4) * G.horizon.w;
}

// ---------------------------------------------------------------- sky pass

struct SkyOut { float4 pos [[position]]; float2 ndc; };

vertex SkyOut forestSkyVert(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2) * 2.0 - 1.0;
    SkyOut o; o.pos = float4(p, 0.0, 1.0); o.ndc = p; return o;
}

fragment float4 forestSkyFrag(SkyOut in [[stage_in]], constant ForestU& U [[buffer(0)]], constant float4x4& invVP [[buffer(1)]],
                              texture2d<float> T [[texture(0)]]) {
    float4 w = invVP * float4(in.ndc, 0.5, 1.0);
    float3 V = normalize(w.xyz / w.w);
    float3 c = skyColor(V, U, T, true);
    // the mist hangs over the horizon too
    c = mix(c, applyMist(c, V * 6000.0, U), smoothstep(0.25, 0.0, V.y));
    return float4(tonemap(c, U), 0.98);      // alpha 0.98 marks the sky for the light shafts (everything else is 1)
}

// ---------------------------------------------------------------- terrain

struct TerrOut { float4 pos [[position]]; float3 rel; };

static float3 terrainVertex(uint vid, NodeI n, float4 G, constant ForestU& U, texture2d<float> T) {
    // indexed grid: vid = a grid point (Q + 1 per row), so each vertex is computed once, not once per triangle
    int Q = int(G.x);
    float2 g = float2(int(vid) % (Q + 1), int(vid) / (Q + 1));
    float2 wxz = n.o.xy + g / float(Q) * n.o.z;
    // CDLOD: near the outer edge of its distance range a patch slides its odd vertices onto the next coarser grid,
    // so it meets the coarser patch beside it without cracks
    float range = G.y * exp2(n.o.w);
    float k = clamp((length(wxz - U.cam.xz) - 0.7 * range) / (0.3 * range), 0.0, 1.0);
    wxz -= fract(g * 0.5) * 2.0 / float(Q) * n.o.z * k;
    float h = terrain(T, wxz, 8).x;
    return float3(wxz.x, h, wxz.y) - U.cam.xyz;
}

vertex TerrOut terrainVert(uint vid [[vertex_id]], uint iid [[instance_id]], const device NodeI* nodes [[buffer(0)]],
                           constant ForestU& U [[buffer(1)]], constant float4& G [[buffer(2)]], texture2d<float> T [[texture(0)]]) {
    TerrOut o;
    o.rel = terrainVertex(vid, nodes[iid], G, U, T);
    o.pos = U.viewProj * float4(o.rel, 1.0);
    return o;
}

vertex float4 terrainShadowVert(uint vid [[vertex_id]], uint iid [[instance_id]], const device NodeI* nodes [[buffer(0)]],
                                constant ForestU& U [[buffer(1)]], constant float4& G [[buffer(2)]],
                                constant float4x4& LVP [[buffer(3)]], texture2d<float> T [[texture(0)]]) {
    return LVP * float4(terrainVertex(vid, nodes[iid], G, U, T), 1.0);
}

fragment float4 terrainFrag(TerrOut in [[stage_in]], constant ForestU& U [[buffer(0)]], texture2d<float> T [[texture(0)]],
                            depth2d_array<float> S [[texture(1)]], GI_FRAG_PARAMS) {
    float3 wp = in.rel + U.cam.xyz;
    float dist = length(in.rel);
    int oct = clamp(int(13.0 - log2(max(dist, 1.0))), 7, 11);   // finer octaves only where a pixel can show them
    float ae, width;
    float3 t = terrain(T, wp.xz, oct, ae, width);
    float3 N = normalize(float3(-t.y, 1.0, -t.z));
    float4 v1 = nz(T, wp.xz / 9.0 + 1.3), v2 = nz(T, wp.xz / 1.7 + 4.1);
    float forestFloor = smoothstep(-0.1, 0.25, nz(T, wp.xz / 64.0 + 5.3).w) * smoothstep(width * 1.6 + 3.0, width * 1.6 + 10.0, ae);
    // grass → forest floor (needles, moss) → river bank (mud, pebbles) → rock on steep slopes → snow on the tops
    float big = nz(T, wp.xz / 45.0 + 8.8).x;
    float3 grass = mix(float3(0.07, 0.13, 0.03), float3(0.17, 0.18, 0.06), smoothstep(-0.4, 0.5, v1.w + 0.6 * big));
    grass = mix(grass, float3(0.2, 0.17, 0.08), smoothstep(0.25, 0.6, big) * 0.6);          // dry patches
    // the season: spring's fresh green, then straw (late summer in patches, dead grass from late autumn to spring)
    grass = mix(grass, float3(0.1, 0.2, 0.035), U.seasonA.w * 0.5);
    grass = mix(grass, float3(0.2, 0.16, 0.085) * (0.8 + 0.4 * smoothstep(-0.5, 0.5, v1.w)), U.seasonB.z * smoothstep(-0.6, 0.2, big + 0.3 * v1.x + U.seasonB.z));
    float3 floorC = mix(float3(0.06, 0.045, 0.03), float3(0.06, 0.09, 0.03), smoothstep(-0.3, 0.4, v1.x));
    // fallen leaves on the forest floor (fresh orange and yellow in autumn, browner through winter), a few out on the meadow
    float3 litterC = mix(float3(0.26, 0.09, 0.025), float3(0.3, 0.2, 0.045), smoothstep(-0.3, 0.3, v2.x)) * mix(1.0, 0.6, U.seasonA.x + (1.0 - U.seasonA.z) * 0.5);
    floorC = mix(floorC, litterC, U.seasonC.w * 0.85 * smoothstep(-0.6, 0.0, v2.w));
    grass = mix(grass, litterC, U.seasonC.w * 0.3 * smoothstep(0.1, 0.6, v2.w));
    float3 alb = mix(grass, floorC, forestFloor);
    // the shore: pebbles and sand just above the water, darker and wet right at it, mud below
    float above = wp.y - WATER;
    float shore = smoothstep(0.35, 0.05, above + 0.25 * v2.x);
    if (shore > 0.0 && dist < 60.0) {
        // pebbles: the nearest of four jittered points in a 12 cm grid; each stone its own shade, dark gaps between
        float2 g = wp.xz / 0.12, gi = floor(g);
        float best = 9.0, second = 9.0, id = 0.0;
        for (int j = 0; j < 4; j++) {
            float2 cc = gi + float2(j & 1, j >> 1) - float2(g.x - gi.x < 0.5 ? 1.0 : 0.0, g.y - gi.y < 0.5 ? 1.0 : 0.0);
            int2 ic = int2(cc);
            float2 pt = cc + float2(fh(ic, 41u), fh(ic, 42u));
            float d2 = distance_squared(g, pt);
            if (d2 < best) { second = best; best = d2; id = fh(ic, 43u); } else if (d2 < second) second = d2;
        }
        float edge = smoothstep(0.0, 0.25, sqrt(second) - sqrt(best));
        // only some cells hold a stone (more of them right at the water), the rest is wet sand and grit
        float isStone = step(0.45 - 0.35 * smoothstep(0.3, 0.0, above), fract(id * 7.7)) * smoothstep(0.55, 0.3, sqrt(best));
        float3 sand = float3(0.15, 0.13, 0.1) * (0.8 + 0.4 * fract(id * 3.1));
        float3 stone = mix(sand, mix(float3(0.13, 0.115, 0.095), float3(0.26, 0.23, 0.19), id) * mix(0.5, 1.0, edge), isStone);
        float3 pebbles = mix(float3(0.1, 0.085, 0.065), stone, 1.0 - smoothstep(30.0, 60.0, dist));
        alb = mix(alb, pebbles, shore);
    } else {
        alb = mix(alb, float3(0.12, 0.1, 0.08) * (0.75 + 0.5 * v2.w), shore);
    }
    alb *= mix(1.0, 0.6, smoothstep(0.2, 0.0, above));                     // wet
    alb = mix(alb, float3(0.32, 0.3, 0.27) * (0.75 + 0.5 * v2.x), smoothstep(0.82, 0.65, N.y) * smoothstep(0.3, 0.8, above));
    alb = mix(alb, float3(0.9, 0.92, 0.96), smoothstep(215.0, 245.0, wp.y + 15.0 * v1.x) * smoothstep(0.55, 0.75, N.y));
    alb *= 0.85 + 0.3 * v2.w;
    alb *= 1.0 - 0.3 * U.seasonC.z;                                         // rain-soaked
    // snow: patchy while it comes and goes (open, flat ground first; less under the trees and on steep slopes)
    float cover = U.seasonA.x;
    if (cover > 0.0) {
        float nn = 0.5 + 0.3 * big + 0.2 * v1.x;
        float th = 1.05 - 1.2 * cover;
        float snowM = smoothstep(th - 0.06, th + 0.06, nn - 0.25 * forestFloor);
        snowM *= smoothstep(0.62 - 0.22 * cover, 0.82 - 0.1 * cover, N.y) * smoothstep(0.0, 0.12, above + 0.05 * v2.x);
        alb = mix(alb, SNOW * (0.93 + 0.1 * v2.w), snowM);
    }
    // under the water: the river bed, dark and silty (whatever the slope: rock showed through the shallows as a grey band)
    if (above < 0.0) alb = mix(float3(0.07, 0.065, 0.045), float3(0.03, 0.04, 0.03), smoothstep(0.0, 1.2, -above)) * (0.8 + 0.4 * v2.w);
    float sh = shadowAt(in.rel, N, U, S);
    float3 L = U.sun.xyz;
    float3 c = alb * (U.sunCol.rgb * U.sun.w * max(dot(N, L), 0.0) * sh + giAmbient(N, in.rel, U, G, GI_TEX) * (0.75 + 0.25 * N.y));
    // a meadow seen towards the sun glows (light through the blades)
    float3 V = -in.rel / max(dist, 1e-3);
    c += alb * U.sunCol.rgb * U.sun.w * pow(max(dot(V, -L), 0.0), 4.0) * 0.5 * (1.0 - forestFloor) * (1.0 - shore) * sh;
    GI_DEBUG_OUT(N)
    c = applyMist(c, in.rel, U);
    return float4(tonemap(c, U, (G.ground.w > 0.5 ? float3(0.5) : alb) * giFly(in.rel, U, G, gi0, gi4) * mistT(in.rel, U)), 1.0);
}

// ---------------------------------------------------------------- trees: placement (compute)

/// A conservative early cull for the scatter kernels, before any noise is sampled: is the column above xz
/// (camera-relative, ±r sideways, from below the river bed up to above the highest hill) entirely outside one of the
/// (widened) frustum planes by more than `margin`? Then the exact test later would reject whatever stands there.
static bool columnOutside(constant ForestU& U, float2 relXZ, float r, float margin) {
    float3 lo = float3(relXZ.x - r, -40.0 - U.cam.y, relXZ.y - r), hi = float3(relXZ.x + r, 480.0 - U.cam.y, relXZ.y + r);
    for (int i = 0; i < 4; i++) {
        float3 n = U.planes[i].xyz;
        float3 v = select(lo, hi, n >= 0.0);
        if (dot(n, v) + U.planes[i].w < -margin) return true;
    }
    return false;
}

kernel void forestScatter(uint2 gid [[thread_position_in_grid]], constant ForestU& U [[buffer(0)]],
                          device atomic_uint* counts [[buffer(1)]], device TreeI* out [[buffer(2)]],
                          texture2d<float> T [[texture(0)]]) {
    int N = U.cell.z;
    if (int(gid.x) >= 2 * N || int(gid.y) >= 2 * N) return;
    int2 c = U.cell.xy + int2(gid) - N;
    int cells = int(WP / U.cfg.z);
    int2 hc = int2(c.x, ((c.y % cells) + cells) % cells);
    float h1 = fh(hc, 1u), h2 = fh(hc, 2u), h3 = fh(hc, 3u);
    float2 xz = (float2(c) + 0.5 + (float2(h1, h2) - 0.5) * 0.85) * U.cfg.z;
    if (length_squared(xz - U.cam.xz) > U.cfg.y * U.cfg.y || columnOutside(U, xz - U.cam.xz, 20.0, 0.0)) return;
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
    // conifers take over higher up; broadleaf trees like the valley floor
    float conifer = mix(0.3, 0.97, smoothstep(5.0, 90.0, t.x));
    uint sp = h4 < conifer ? 0u : 1u;
    float H = (sp == 0u ? 17.0 : 13.0) * (0.55 + 0.9 * h5 * h5) * mix(1.0, 0.55, smoothstep(140.0, 235.0, t.x));
    float3 rel = float3(xz.x, t.x - 0.25, xz.y) - U.cam.xyz;
    float3 sc = rel + float3(0.0, 0.5 * H, 0.0);
    float dist = length(sc);
    if (dist > U.cfg.y) return;
    float r = 0.6 * H + 2.0;
    for (int i = 0; i < 4; i++) if (dot(U.planes[i].xyz, sc) + U.planes[i].w < -r) return;
    // Nothing may pop: far away the haze hides single trees, so they are thinned out, but each fades (dithered) over
    // a stretch of distance; so does the edge of the area; and at every LOD boundary both meshes are drawn for a
    // while with complementary dither patterns (one fades out exactly where the other fades in).
    float vis = 1.0 - smoothstep(U.cfg.y - 120.0, U.cfg.y, dist);
    float thin = smoothstep(380.0, U.cfg.y, dist) * 0.6;
    vis *= clamp((fh(hc, 8u) - thin) / 0.12, 0.0, 1.0);
    if (vis <= 0.0) return;
    const float bound[3] = { U.lod.x, U.lod.y, 380.0 };
    const float band[3] = { 6.0, 16.0, 35.0 };
    uint lod = 0;
    float tf = -1.0;
    for (uint i = 0; i < 3; i++) {
        if (dist > bound[i] + band[i]) lod = i + 1;
        else if (dist > bound[i] - band[i]) { lod = i; tf = (dist - (bound[i] - band[i])) / (2.0 * band[i]); break; }
    }
    int bnd = min(int(U.cfg.w) - 1, int(fh(hc, 7u) * U.cfg.w));
    TreeI ti;
    ti.p = float4(rel + U.cam.xyz, H);
    ti.q = float4(fh(hc, 6u) * 6.2831853, h1, float(bnd), float(sp));
    for (uint pass = 0; pass < (tf >= 0.0 ? 2u : 1u); pass++) {
        uint l = lod + pass;
        ti.f = tf < 0.0 ? float4(1.0, 1.0, vis, 0.0) : float4(1.0 - tf, pass == 0 ? 1.0 : -1.0, vis, 0.0);
        uint k = sp * 4u + l;
        uint idx = atomic_fetch_add_explicit(&counts[k], 1u, memory_order_relaxed);
        if (idx >= CAP[l]) continue;
        uint base = sp * (CAP[0] + CAP[1] + CAP[2] + CAP[3]);
        for (uint i = 0; i < l; i++) base += CAP[i];
        out[base + idx] = ti;
    }
}

/// Screen-door fade (interleaved gradient noise): which pixels of a fading tree are drawn. The near and the far mesh
/// at a LOD boundary use the same threshold from opposite sides, so together they cover each pixel exactly once.
static bool fadeKeep(float2 px, float3 f) {
    float n = fract(52.9829189 * fract(dot(px, float2(0.06711056, 0.00583715))));
    float n2 = fract(52.9829189 * fract(dot(px.yx + 17.0, float2(0.06711056, 0.00583715))));
    return (f.y > 0.0 ? n < f.x : n >= f.x) && n2 < f.z;
}

/// Writes the counted instances into the indirect draw arguments (bark and leaves of every species × LOD).
kernel void forestFinalize(device uint* counts [[buffer(0)]], device uint* args [[buffer(1)]]) {
    for (uint k = 0; k < 8; k++) {
        uint n = min(counts[k], CAP[k % 4]);
        args[(k * 2) * 5 + 1] = n;
        args[(k * 2 + 1) * 5 + 1] = n;
    }
}

// ---------------------------------------------------------------- trees: drawing

struct TreeOut {
    float4 pos [[position]];
    float3 rel;
    float3 n;
    float2 uv;
    float ao;
    float tint;
    float glow;
    float sp;
    float leafTint;
    float3 fade [[flat]];
    float4 season [[flat]];
    float3 amb;            // ambient / GI light at the vertex (the GI is smooth: per vertex is enough, and far cheaper)
    float3 fly;            // fireflies' light there
};

/// The season of a broadleaf leaf cluster (one cluster = two crossed cards with the same tint): x = 1 while it still
/// hangs on the tree (0 = fallen: drawn as bare twigs), y = how far it has turned (autumn), z = 1 if it blossoms,
/// w = the cluster's own random number. Every tree keeps its own timing (some go bare or turn earlier).
static float4 leafSeason(TreeV v, TreeI t, constant ForestU& U) {
    float ch = fract((v.p.w - 1.0) * 91.7 + t.q.y * 13.3);
    if (t.q.w < 0.5 || v.p.w < 0.5) return float4(1.0, 0.0, 0.0, ch);
    float th = fract(t.q.y * 27.1), th2 = fract(t.q.y * 41.3);
    float fol = clamp(U.seasonA.y * 1.35 - 0.35 * th, 0.0, 1.0);
    float turn = clamp(U.seasonA.z * 1.6 - 0.6 * th2, 0.0, 1.0);
    turn = clamp(turn * 1.4 - 0.4 * fract(ch * 7.3), 0.0, 1.0);
    float bl = fract(t.q.y * 3.7) < 0.4 && fract(ch * 3.1) < U.seasonB.y * 0.9 ? 1.0 : 0.0;
    return float4(ch < fol ? 1.0 : 0.0, turn, bl, ch);
}

/// A tree's vertex in the world: turned, scaled, bent by the wind (gusts = the bass, rolling across the forest),
/// leaves fluttering with the treble. Returns the camera-relative position; n = turned normal.
static float3 treeVertex(TreeV v, TreeI t, constant ForestU& U, const device float* B, texture2d<float> T, thread float3 &n) {
    float H = t.p.w;
    float c = cos(t.q.x), s = sin(t.q.x);
    float3 lp = v.p.xyz;
    lp.xz = float2(c * lp.x - s * lp.z, s * lp.x + c * lp.z);
    n = v.n.xyz;
    n.xz = float2(c * n.x - s * n.z, s * n.x + c * n.z);
    float time = U.cam.w;
    float2 wd = U.wind.xy, wp2 = float2(-wd.y, wd.x);
    // Gusts are a slow noise field drifting downwind across the forest (neighbours move alike, a gust passes
    // through); the music (bass, smoothed on the CPU) makes the whole field stronger.
    float g = nz(T, t.p.xz / 90.0 - wd * time * 0.09).x * 0.6 + 0.5;
    float strength = U.wind.z * clamp(g, 0.0, 1.2) * (0.3 + 1.2 * U.music.x);
    // the trunk leans with the wind and rocks about that at its own (height-dependent) natural frequency
    float f0 = 0.42 * rsqrt(max(H, 3.0) / 12.0);
    float rock = sin(time * 6.2831853 * f0 + t.q.y * 40.0), rock2 = sin(time * 6.2831853 * f0 * 1.37 + t.q.y * 17.0);
    float lean = strength * (0.012 + 0.005 * rock);
    float hy = max(lp.y, 0.0);
    float3 wp = lp * H;
    float k = hy * hy * H;
    wp.xz += (wd * lean + wp2 * strength * 0.0025 * rock2) * k;
    wp.y -= 0.5 * lean * lean * hy * H;
    if (v.p.w > 0.5) {
        // branches bob: slower near the trunk, the motion travelling through the crown (phase by position)
        float ph = v.u.w * 6.2831853 + dot(lp, float3(4.1, 2.3, 3.7));
        float br = sin(time * (1.3 + 0.7 * v.u.w) + ph) * strength * 0.018 * v.u.z * H;
        wp.y += br;
        wp.xz += wd * br * 0.5;
        // leaves flutter: small and quick, broadleaf only (needles are stiff); the treble adds to it
        if (t.q.w > 0.5) wp += n * sin(time * 9.0 + ph * 5.0) * (0.0015 + 0.008 * U.music.y) * U.wind.z * H * v.u.z;
    }
    return t.p.xyz - U.cam.xyz + wp;
}

vertex TreeOut treeVert(uint vid [[vertex_id]], uint iid [[instance_id]], const device TreeV* V [[buffer(0)]],
                        const device TreeI* I [[buffer(1)]], constant ForestU& U [[buffer(2)]], const device float* B [[buffer(3)]],
                        texture2d<float> T [[texture(0)]], constant GIView& G [[buffer(4)]], texture3d<float> gi0 [[texture(1)]],
                        texture3d<float> gi1 [[texture(2)]], texture3d<float> gi2 [[texture(3)]], texture3d<float> gi3 [[texture(4)]],
                        texture3d<float> gi4 [[texture(5)]]) {
    TreeV v = V[vid]; TreeI t = I[iid];
    TreeOut o;
    float3 n;
    o.rel = treeVertex(v, t, U, B, T, n);
    o.pos = U.viewProj * float4(o.rel, 1.0);
    o.n = n;
    o.uv = v.u.xy;
    o.ao = v.n.w;
    o.tint = t.q.y;
    o.glow = B[int(t.q.z)] * U.music.w;
    o.sp = t.q.w;
    o.leafTint = max(v.p.w - 1.0, 0.0);
    o.fade = t.f.xyz;
    o.season = leafSeason(v, t, U);
    o.amb = giAmbient(normalize(n), o.rel, U, G, GI_TEX);
    o.fly = giFly(o.rel, U, G, gi0, gi4);
    return o;
}

struct ShadowOut { float4 pos [[position]]; float2 uv; };

vertex ShadowOut treeShadowVert(uint vid [[vertex_id]], uint iid [[instance_id]], const device TreeV* V [[buffer(0)]],
                                const device TreeI* I [[buffer(1)]], constant ForestU& U [[buffer(2)]],
                                const device float* B [[buffer(3)]], constant float4x4& LVP [[buffer(4)]],
                                texture2d<float> T [[texture(0)]]) {
    float3 n;
    ShadowOut o;
    o.pos = LVP * float4(treeVertex(V[vid], I[iid], U, B, T, n), 1.0);
    // a tree drawn twice at a LOD boundary casts its shadow once (from the nearer mesh); faded-out ones not at all
    if (I[iid].f.y < 0.0 || I[iid].f.z < 0.5) o.pos = float4(2.0, 2.0, 2.0, 1.0);
    // fallen leaves cast no shadow (the bare twigs are too thin to)
    if (leafSeason(V[vid], I[iid], U).x < 0.5) o.pos = float4(2.0, 2.0, 2.0, 1.0);
    o.uv = V[vid].u.xy;
    return o;
}

// Trilinear, not anisotropic: the shadow pass is all alpha-tested leaf cards, and 8× anisotropic sampling made
// the near cascade cost 3.3 ms instead of 1.1 (the cast shadow's shape is the same).
constexpr sampler triMip(filter::linear, mip_filter::linear, address::clamp_to_edge);
fragment void leafShadowFrag(ShadowOut in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
    if (atlas.sample(triMip, in.uv).a < 0.5) discard_fragment();
}

fragment float4 barkFrag(TreeOut in [[stage_in]], constant ForestU& U [[buffer(0)]], texture2d<float> T [[texture(0)]],
                         depth2d_array<float> S [[texture(1)]], GI_FRAG_PARAMS) {
    float3 N = normalize(in.n);
    float3 wp = in.rel + U.cam.xyz;
    float stripes = nz(T, float2(atan2(N.x, N.z) * 3.0, wp.y * 2.5) + in.tint * 10.0).x;
    float3 alb = in.sp < 0.5 ? float3(0.17, 0.12, 0.09) : mix(float3(0.55, 0.53, 0.48), float3(0.12, 0.11, 0.1), smoothstep(0.05, 0.3, stripes));
    alb *= 0.8 + 0.4 * stripes;
    alb *= 1.0 - 0.35 * U.seasonC.z;
    alb = mix(alb, SNOW, U.seasonA.x * smoothstep(0.35, 0.7, N.y + 0.2 * stripes));      // snow lying on the limbs
    float sh = shadowAt(in.rel, N, U, S);
    float3 c = alb * (U.sunCol.rgb * U.sun.w * max(dot(N, U.sun.xyz), 0.0) * sh + in.amb) * in.ao;
    if (G.ground.w > 0.5) c = 0.5 * in.amb;
    c = applyMist(c, in.rel, U);
    return float4(tonemap(c, U, (G.ground.w > 0.5 ? float3(0.5) : alb) * in.fly * in.ao * mistT(in.rel, U)), fadeKeep(in.pos.xy, in.fade) ? 1.0 : 0.0);   // alpha to coverage
}

fragment float4 leafFrag(TreeOut in [[stage_in]], constant ForestU& U [[buffer(0)]], texture2d<float> T [[texture(0)]],
                         depth2d_array<float> S [[texture(1)]], texture2d<float> atlas [[texture(2)]], GI_FRAG_PARAMS) {
    float4 a = atlas.sample(linMip, in.uv);
    // alpha to coverage: sharpen the (mip-blurred) alpha to about one pixel of edge, so far foliage keeps its density
    float alpha = (a.a - 0.4) / max(fwidth(a.a), 1e-4) + 0.5;
    float3 N = normalize(in.n);
    float3 V = -normalize(in.rel);
    float3 L = U.sun.xyz;
    // spruces dark and a little blue; broadleaf crowns lighter, each leaf cluster its own shade (older, sunnier, drier)
    float3 base = in.sp < 0.5 ? mix(float3(0.018, 0.045, 0.03), float3(0.035, 0.065, 0.032), in.tint)
                              : mix(float3(0.05, 0.11, 0.02), float3(0.11, 0.15, 0.03), in.tint);
    if (in.sp > 0.5) base = mix(base, mix(float3(0.13, 0.15, 0.03), float3(0.035, 0.09, 0.025), in.leafTint), 0.45);
    float4 ls = in.season;
    float dist = length(in.rel);
    if (in.sp > 0.5) {
        // spring: a light, fresh green; autumn: each tree its own colour (birch yellow, orange, maple red, oak brown)
        base = mix(base, float3(0.12, 0.2, 0.03) * (0.85 + 0.3 * in.leafTint), U.seasonA.w * 0.6);
        float kind = fract(in.tint * 7.13);
        float3 au = kind < 0.35 ? float3(0.36, 0.25, 0.015) : (kind < 0.62 ? float3(0.4, 0.14, 0.015)
                  : (kind < 0.82 ? float3(0.32, 0.035, 0.02) : float3(0.2, 0.1, 0.035)));
        au = mix(au, float3(0.3, 0.17, 0.02), 0.35 * fract(ls.w * 5.3)) * (0.8 + 0.4 * in.leafTint);
        base = mix(base, au, ls.y);
        if (ls.z > 0.5) base = mix(float3(0.62, 0.6, 0.58), float3(0.62, 0.42, 0.5), step(0.5, fract(in.tint * 11.0)));
    }
    float3 alb = base * (0.55 + 0.9 * a.rgb);
    if (ls.x < 0.5) {
        // a bare tree: only the twigs are left (the cores of the cards, thinned, grey-brown); in the distance they
        // merge into the purple-grey haze of a winter wood
        alpha = (a.a - 0.8) / max(fwidth(a.a), 1e-4) + 0.5;
        float n = fract(52.9829189 * fract(dot(in.pos.xy, float2(0.06711056, 0.00583715)) + ls.w));
        if (n > mix(0.35, 0.8, smoothstep(40.0, 200.0, dist))) alpha = 0.0;
        alb = mix(float3(0.045, 0.04, 0.04), float3(0.075, 0.068, 0.068), ls.w);
    }
    // snow on the crowns: on top of the spruces' branches, a dusting on bare twigs
    alb = mix(alb, SNOW, U.seasonA.x * smoothstep(-0.15, 0.55, N.y + 0.5 * (ls.w - 0.5)) * (in.sp < 0.5 ? 0.85 : 0.55));
    float sh = shadowAt(in.rel, N, U, S, true);
    float wrap = clamp((dot(N, L) + 0.35) / 1.35, 0.0, 1.0);
    // light through the leaves when looking towards the sun
    float trans = pow(max(dot(V, -L), 0.0), 3.0) * 0.9 * (in.sp < 0.5 ? 0.5 : 1.0);
    float3 c = alb * (U.sunCol.rgb * U.sun.w * (wrap + trans) * sh + in.amb) * in.ao;
    // each tree catches the light of its own frequency band (Band light)
    c += alb * U.sunCol.rgb * in.glow * 2.5 * (0.4 + 0.6 * sh);
    // broadleaf leaves are a little glossy: a soft sheen where they catch the sun
    if (in.sp > 0.5 && ls.x > 0.5) c += U.sunCol.rgb * U.sun.w * pow(max(dot(N, normalize(L + V)), 0.0), 24.0) * 0.06 * sh * a.a;
    if (!fadeKeep(in.pos.xy, in.fade)) alpha = 0.0;
    if (G.ground.w > 0.5) c = 0.5 * in.amb;
    c = applyMist(c, in.rel, U);
    return float4(tonemap(c, U, (G.ground.w > 0.5 ? float3(0.5) : alb) * in.fly * in.ao * mistT(in.rel, U)), clamp(alpha, 0.0, 1.0));
}

// ---------------------------------------------------------------- water

struct WaterOut { float4 pos [[position]]; float3 rel; };

vertex WaterOut waterVert(uint vid [[vertex_id]], constant ForestU& U [[buffer(0)]]) {
    // a 2 km square around the camera, 16 × 16 quads (the river's surface; the terrain hides it elsewhere)
    uint q = vid / 6, corner = vid % 6;
    const int2 offs[6] = { int2(0, 0), int2(1, 0), int2(0, 1), int2(1, 0), int2(1, 1), int2(0, 1) };
    float2 g = (float2(q % 16, q / 16) + float2(offs[corner])) / 16.0 * 2.0 - 1.0;
    WaterOut o;
    o.rel = float3(g.x * 1000.0, WATER - U.cam.y, g.y * 1000.0);
    o.pos = U.viewProj * float4(o.rel, 1.0);
    return o;
}

fragment float4 waterFrag(WaterOut in [[stage_in]], constant ForestU& U [[buffer(0)]], texture2d<float> T [[texture(0)]],
                          depth2d_array<float> S [[texture(1)]]) {
    float3 wp = in.rel + U.cam.xyz;
    float ae, width;
    float depth = WATER - terrain(T, wp.xz, 7, ae, width).x;
    if (depth <= 0.0) discard_fragment();
    float time = U.cam.w;
    float2 flow = float2(-valleyD(wp.z), -1.0);         // downstream: the way we fly
    // three layers of ripples drifting at different speeds and angles (one stretched along the current)
    float2 q = wp.xz;
    float4 r1 = nz(T, float2(q.x * 0.9, q.y * 0.45) + flow * time * 0.35);
    float4 r2 = nz(T, q * 2.3 - flow.yx * time * 0.6 + 4.0);
    float4 r3 = nz(T, float2(q.x * 6.0 + q.y * 2.0, q.y * 5.5 - q.x * 1.5) + flow * time * 1.4 + 9.0);
    float dist = length(in.rel);
    float rough = (0.06 + 0.12 * U.music.y) / (1.0 + dist * 0.015);
    float2 slope = float2(r1.y * 0.9, r1.z * 0.45) * 0.55 + r2.yz * 2.3 * 0.12 + float2(r3.y * 6.0 + r3.z * -1.5, r3.y * 2.0 + r3.z * 5.5) * 0.012 / (1.0 + dist * 0.05);
    float3 N = normalize(float3(-slope.x * rough * 2.0, 1.0, -slope.y * rough * 2.0));
    // raindrops: rings spreading on the surface (two offset grids of 0.5 m cells, one drop per cell at a time)
    float rain = U.precip.x;
    if (rain > 0.002 && dist < 45.0) {
        float2 rs = 0.0;
        for (int l = 0; l < 2; l++) {
            float2 g = wp.xz / 0.5 + float2(l) * 0.5, gi = floor(g);
            int2 ic = int2(gi) + int2(l * 7919, 0);
            float h0 = fh(ic, 61u), cyc = time * (1.1 + 0.6 * fh(ic, 62u)) + h0, ph = fract(cyc);
            if (fh(ic + int2(0, int(floor(cyc)) * 131), 63u) > rain * 1.2) continue;     // a new random set of cells each round
            float2 d = (g - gi - 0.5 - (float2(fh(ic, 64u), fh(ic, 65u)) - 0.5) * 0.4) * 0.5;
            float r = length(d), R = ph * 0.22;
            float w = (r - R) * 90.0;
            rs += d / max(r, 1e-3) * sin(w) * exp(-w * w * 0.08) * (1.0 - ph) * (1.0 - ph);
        }
        float k = 0.35 * (1.0 - smoothstep(20.0, 45.0, dist));
        N = normalize(N - float3(rs.x, 0.0, rs.y) * k);
    }
    float3 V = -normalize(in.rel);
    float3 R = reflect(-V, N);
    R.y = abs(R.y);
    float fres = 0.02 + 0.98 * pow(1.0 - max(dot(N, V), 0.0), 5.0);
    float sh = shadowAt(in.rel, float3(0.0, 1.0, 0.0), U, S);
    float3 refl = skyColor(R, U, T, true);
    // What the river mirrors near its banks: the wall of trees. Across the valley the reflected ray reaches the tree
    // line at `s`; below the treetops there it sees dark, sky-lit foliage instead of sky.
    float dxr = wp.x - (valley(wp.z) + 6.0 * nz(T, float2(wp.z / 160.0, 3.3)).x);
    float treeLine = width * 1.6 + 4.0;
    float sR = (sign(R.x) * treeLine - dxr) / max(abs(R.x), 1e-3) * (abs(R.x) > 1e-3 ? 1.0 : 1e3);
    float top = 13.0 + 5.0 * nz(T, float2(wp.z / 40.0, 11.0)).x;
    float wall = smoothstep(top + 1.5, top - 1.5, sR * R.y) * (1.0 - smoothstep(150.0, 400.0, sR));
    float3 foliage = float3(0.02, 0.05, 0.025) * (ambient(float3(0, 1, 0), U) * 1.5 + U.sunCol.rgb * U.sun.w * 0.25);
    refl = mix(refl, applyMist(foliage, R * sR, U), wall);
    float3 deep = float3(0.01, 0.025, 0.022) * (ambient(float3(0, 1, 0), U) + U.sunCol.rgb * U.sun.w * 0.2 * sh);
    float3 c = mix(deep, refl, fres);
    float sd = max(dot(R, U.sun.xyz), 0.0);
    c += U.sunCol.rgb * U.sun.w * (pow(sd, 300.0) * 3.0 + pow(sd, 3000.0) * 12.0) * sh * (1.0 - wall);   // glare + glitter
    // foam where it laps at the shore, broken up by the ripples
    float lap = 0.035 + 0.02 * sin(time * 1.1 + wp.z * 0.5 + wp.x * 0.3);   // the waterline creeps up and back
    float foam = smoothstep(lap, lap * 0.3, depth) * smoothstep(0.35, 0.75, r2.x * 0.5 + 0.5);
    c = mix(c, (ambient(float3(0, 1, 0), U) + U.sunCol.rgb * U.sun.w * sh * 0.6) * 0.6, foam * 0.55);
    float alpha = clamp(1.0 - exp(-depth * 1.4) + fres + foam, 0.0, 1.0);
    // ice: creeping out from the banks as the winter goes on (at full ice the whole river), dusted with snow, cracked
    float ice = U.seasonB.w;
    if (ice > 0.0) {
        float line = width * 0.55 * (1.0 - 1.15 * ice) - 0.6;
        float im = smoothstep(line - 0.3, line + 0.3, ae + 0.8 * r1.x + 0.3 * r2.x);
        if (im > 0.0) {
            float4 c1 = nz(T, wp.xz / 1.3 + 2.7), c2 = nz(T, wp.xz / 0.37 + 6.1);
            float fade = 1.0 - smoothstep(8.0, 40.0, dist);
            float crack = (smoothstep(0.012, 0.0, abs(c1.x + 0.15 * c2.x)) * 0.25 + smoothstep(0.01, 0.0, abs(c2.x)) * 0.15) * fade
                        * smoothstep(0.2, -0.2, c1.w);                    // only here and there
            float dust = smoothstep(-0.2, 0.4, c1.w + 0.5 * U.seasonA.x);
            float3 ia = mix(float3(0.28, 0.34, 0.38), SNOW, dust * 0.85) * (1.0 - crack);
            float3 IN = normalize(float3(-c2.y, 12.0, -c2.z));
            float3 ic = ia * (U.sunCol.rgb * U.sun.w * max(dot(IN, U.sun.xyz), 0.0) * sh + ambient(IN, U));
            ic += skyColor(reflect(-V, IN), U, T, false) * 0.06 * (1.0 - dust);
            c = mix(c, ic, im);
            alpha = mix(alpha, 1.0, im);
        }
    }
    c = applyMist(c, in.rel, U);
    return float4(tonemap(c, U), alpha);
}

// ---------------------------------------------------------------- grass

struct GrassI { float4 p; float4 q; };              // foot (world) + height; q = turn, tint, phase, lushness
constant uint GRASS_CAP = 60000;
constant float GRASS_CELL = 0.32;                   // 25600 cells per period: the hash repeats with the world
constant float GRASS_FAR = 38.0;

kernel void grassScatter(uint2 gid [[thread_position_in_grid]], constant ForestU& U [[buffer(0)]],
                         device atomic_uint* count [[buffer(1)]], device GrassI* out [[buffer(2)]],
                         texture2d<float> T [[texture(0)]]) {
    int N = int(GRASS_FAR / GRASS_CELL);
    if (int(gid.x) >= 2 * N || int(gid.y) >= 2 * N) return;
    int2 c = int2(floor(U.cam.xz / GRASS_CELL)) + int2(gid) - N;
    int cells = int(WP / GRASS_CELL);
    int2 hc = int2(c.x, ((c.y % cells) + cells) % cells);
    float h1 = fh(hc, 11u), h2 = fh(hc, 12u), h3 = fh(hc, 13u);
    float2 xz = (float2(c) + 0.5 + (float2(h1, h2) - 0.5) * 0.9) * GRASS_CELL;
    float2 rel2 = xz - U.cam.xz;
    float d = length(rel2);
    if (d > GRASS_FAR) return;
    if (columnOutside(U, rel2, 0.0, 26.0)) return;
    if (h3 < smoothstep(GRASS_FAR * 0.55, GRASS_FAR, d) * 0.55) return;      // thinner towards its edge
    float width; float2 dg;
    float ae = riverDist(T, xz, width, dg);
    if (ae < width * 0.45) return;
    float3 t = terrain(T, xz, 8);
    if (t.x < WATER + 0.06 || length(t.yz) > 0.9) return;
    float shade = smoothstep(-0.1, 0.25, nz(T, xz / 64.0 + 5.3).w) * smoothstep(width * 1.6 + 3.0, width * 1.6 + 10.0, ae);
    float lush = nz(T, xz / 6.0 + 9.1).x * 0.5 + 0.5;
    if (fh(hc, 14u) > mix(0.95, 0.3, shade) * smoothstep(0.1, 0.35, lush + 0.15)) return;   // sparse under the trees
    if (fh(hc, 19u) < U.seasonA.x * 0.94) return;                                   // buried under the snow (a few stalks poke out)
    float3 rel = float3(rel2.x, t.x - U.cam.y, rel2.y);
    for (int i = 0; i < 4; i++) if (dot(U.planes[i].xyz, rel) + U.planes[i].w - 25.0 < -1.0) return;
    uint idx = atomic_fetch_add_explicit(count, 1u, memory_order_relaxed);
    if (idx >= GRASS_CAP) return;
    float H = (0.15 + 0.35 * lush) * (0.7 + 0.6 * fh(hc, 15u)) * (1.0 - 0.5 * shade) * mix(1.0, 0.3, smoothstep(0.35, 0.05, t.x - WATER));
    H *= 1.0 - 0.4 * U.seasonB.z * (1.0 - U.seasonA.x);                            // dead grass lies flatter
    GrassI g;
    g.p = float4(xz.x, t.x - 0.03, xz.y, H);
    g.q = float4(fh(hc, 16u) * 6.2831853, fh(hc, 17u), fh(hc, 18u) * 6.2831853, lush);
    out[idx] = g;
}

kernel void grassFinalize(device uint* count [[buffer(0)]], device uint* args [[buffer(1)]]) {
    args[1] = min(count[0], GRASS_CAP);
}

struct GrassOut { float4 pos [[position]]; float3 rel; float3 n; float t; float tint; float lush; float2 fuv; float flower [[flat]]; };

/// Does this clump flower now? (More of them in spring / early summer; none under snow.) Returns the colour pick 0…1, or −1.
static float grassFlower(GrassI g, constant ForestU& U) {
    float chance = 0.012 + 0.3 * U.seasonB.x * (1.0 - U.seasonA.x);
    return fract(g.q.y * 31.7) < chance ? fract(g.q.y * 53.3) : -1.0;
}

/// A point on one blade: t = 0 at the foot … 1 at the tip, `across` = sideways offset (metres).
static float3 bladePoint(GrassI g, uint blade, float t, float across, constant ForestU& U, texture2d<float> T) {
    float ang = g.q.x + float(blade) * 2.1;
    float2 dir = float2(cos(ang), sin(ang)), side = float2(-dir.y, dir.x);
    float H = g.p.w * (0.75 + 0.5 * fract(g.q.y * 13.0 + float(blade) * 0.37));
    float dist = length(g.p.xyz - U.cam.xyz);
    H *= 1.0 - smoothstep(GRASS_FAR * 0.75, GRASS_FAR, dist);          // shrink into the ground at the edge
    float time = U.cam.w;
    float2 wd = U.wind.xy;
    float gst = nz(T, g.p.xz / 90.0 - wd * time * 0.09).x * 0.6 + 0.5;
    float strength = U.wind.z * clamp(gst, 0.0, 1.2) * (0.3 + 1.2 * U.music.x);
    float sway = strength * 0.35 + 0.08 * U.wind.z * sin(time * 2.4 + g.q.z + g.p.x * 0.8);
    float bend = 0.25 + 0.2 * fract(g.q.y * 3.0);
    float3 p = float3(0.0, t * H, 0.0);
    p.xz += dir * bend * t * t * H + wd * sway * t * t * H + side * across;
    p.y -= (bend * bend + sway * sway) * 0.4 * t * t * H;
    return g.p.xyz - U.cam.xyz + p;
}

/// A clump of three blades; each blade is a 5-vertex strip (3 triangles) bent forwards, swaying with the same gust
/// field as the trees plus a quicker flutter of its own. Vertices 27…32: a flower head on the first blade (if it flowers).
vertex GrassOut grassVert(uint vid [[vertex_id]], uint iid [[instance_id]], const device GrassI* G [[buffer(0)]],
                          constant ForestU& U [[buffer(1)]], texture2d<float> T [[texture(0)]]) {
    GrassI g = G[iid];
    GrassOut o;
    o.tint = g.q.y;
    o.lush = g.q.w;
    o.fuv = 0.0;
    o.flower = -1.0;
    float fl = grassFlower(g, U);
    if (vid >= 27) {
        if (fl < 0.0) { o.pos = float4(2.0, 2.0, 2.0, 1.0); o.rel = 0.0; o.n = 0.0; o.t = 0.0; return o; }
        const float2 cs[6] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, -1), float2(1, 1), float2(-1, 1) };
        float2 c = cs[vid - 27];
        float3 head = bladePoint(g, 0, 1.0, 0.0, U, T) + float3(0.0, 0.015, 0.0);
        float3 V = normalize(-head);
        // faces the sky, tipped towards the camera
        float3 nrm = normalize(float3(0.0, 1.0, 0.0) + V * 1.2);
        float3 ex = normalize(cross(nrm, abs(nrm.y) > 0.95 ? float3(1, 0, 0) : float3(0, 1, 0)));
        float3 ey = cross(nrm, ex);
        float r = 0.022 + 0.02 * fract(g.q.y * 71.0);
        o.rel = head + (ex * c.x + ey * c.y) * r;
        o.pos = U.viewProj * float4(o.rel, 1.0);
        o.n = nrm; o.t = 1.0; o.fuv = c; o.flower = fl;
        return o;
    }
    uint blade = vid / 9, k = vid % 9;
    const uint idx[9] = { 0, 1, 2, 1, 3, 2, 2, 3, 4 };
    uint v = idx[k];
    float t = v == 4 ? 1.0 : (v >= 2 ? 0.55 : 0.0);
    float wdt = (v == 4 ? 0.0 : (v >= 2 ? 0.6 : 1.0)) * (0.014 + 0.01 * fract(g.q.y * 7.0));
    float sx = v == 4 ? 0.0 : ((v & 1u) == 0u ? -0.5 : 0.5);
    o.rel = bladePoint(g, blade, t, sx * wdt, U, T);
    o.pos = U.viewProj * float4(o.rel, 1.0);
    float ang = g.q.x + float(blade) * 2.1;
    float2 dir = float2(cos(ang), sin(ang)), side = float2(-dir.y, dir.x);
    o.n = normalize(float3(side.x, 0.0, side.y) * 0.3 + float3(0.0, 1.0, 0.0) - float3(dir.x, 0.0, dir.y) * 0.3);
    o.t = t;
    return o;
}

fragment float4 grassFrag(GrassOut in [[stage_in]], constant ForestU& U [[buffer(0)]], depth2d_array<float> S [[texture(1)]], GI_FRAG_PARAMS) {
    // the same greens as the meadow under it, a little lighter towards the tips; fresh in spring, straw when dead
    float3 base = mix(float3(0.07, 0.13, 0.03), float3(0.17, 0.18, 0.06), in.tint * (1.0 - 0.5 * in.lush));
    base = mix(base, float3(0.1, 0.2, 0.035), U.seasonA.w * 0.5);
    base = mix(base, float3(0.22, 0.17, 0.09) * (0.8 + 0.4 * fract(in.tint * 5.0)), U.seasonB.z);
    float3 alb = base * mix(0.6, 1.15, in.t);
    alb *= 1.0 - 0.3 * U.seasonC.z;
    float3 N = normalize(in.n);
    if (in.flower >= 0.0) {
        // five petals round a centre. Early in the year white and yellow (anemones, dandelions, buttercups);
        // in summer poppies, cornflowers, daisies, clover
        float r = length(in.fuv), a = atan2(in.fuv.y, in.fuv.x);
        if (r > 0.6 + 0.4 * abs(cos(2.5 * a + in.tint * 20.0))) discard_fragment();
        float k = in.flower, late = U.seasonC.x;
        float3 petal = k < mix(0.45, 0.25, late) ? float3(0.7, 0.7, 0.66)
                     : (k < mix(0.9, 0.42, late) ? float3(0.72, 0.55, 0.04)
                     : (k < mix(1.0, 0.7, late) ? float3(0.38, 0.18, 0.55)
                     : (k < 0.86 ? float3(0.6, 0.04, 0.03) : float3(0.12, 0.25, 0.65))));
        float3 heart = k < 0.7 ? float3(0.6, 0.45, 0.04) : float3(0.03, 0.02, 0.02);
        alb = mix(heart, petal, smoothstep(0.22, 0.32, r));
    }
    float3 L = U.sun.xyz;
    float3 V = -normalize(in.rel);
    float sh = shadowAt(in.rel, float3(0.0, 1.0, 0.0), U, S, true);
    float trans = pow(max(dot(V, -L), 0.0), 4.0) * 0.8 * in.t;
    float3 c = alb * (U.sunCol.rgb * U.sun.w * (clamp(dot(N, L) * 0.6 + 0.4, 0.0, 1.0) + trans) * sh + giAmbient(N, in.rel, U, G, GI_TEX) * mix(0.5, 1.0, in.t));
    GI_DEBUG_OUT(N)
    c = applyMist(c, in.rel, U);
    return float4(tonemap(c, U, (G.ground.w > 0.5 ? float3(0.5) : alb) * giFly(in.rel, U, G, gi0, gi4) * mistT(in.rel, U)), 1.0);
}

// ---------------------------------------------------------------- birds

struct BirdI { float4 p; float4 v; };               // world position + wingbeat phase; velocity + size

struct BirdOut { float4 pos [[position]]; float3 rel; float lit; };

/// A bird in 7 triangles: body, and each wing in an inner and an outer part, beating (the outer part lags).
vertex BirdOut birdVert(uint vid [[vertex_id]], uint iid [[instance_id]], const device BirdI* Bd [[buffer(0)]],
                        constant ForestU& U [[buffer(1)]]) {
    BirdI b = Bd[iid];
    float3 f = normalize(b.v.xyz + float3(0.0, 1e-4, 0.0));
    float3 r = normalize(cross(f, float3(0.0, 1.0, 0.0)));
    float3 u = cross(r, f);
    float a = sin(b.p.w) * 0.85 + 0.1, a2 = sin(b.p.w - 0.6) * 1.1 + 0.1;
    uint tri = vid / 3, k = vid % 3;
    float side = tri >= 4 ? -1.0 : 1.0;
    float3 l;                                          // x right, y up, z forwards
    float3 sf = float3(0.03, 0.0, 0.07), sb = float3(0.03, 0.0, -0.09);
    float3 el = float3(0.28 * cos(a), 0.28 * sin(a), -0.01);
    float3 eb = el + float3(0.0, 0.0, -0.1);
    float3 tp = el + float3(0.3 * cos(a2), 0.3 * sin(a2), -0.13);
    if (tri == 0) {
        l = k == 0 ? float3(0.0, 0.0, 0.25) : (k == 1 ? float3(-0.045, 0.0, -0.26) : float3(0.045, 0.0, -0.26));
    } else {
        uint w = (tri - 1) % 3;
        float3 P[9] = { sf, el, sb,  sb, el, eb,  el, tp, eb };
        l = P[w * 3 + k];
        l.x *= side;
    }
    float3 wp = b.p.xyz + (r * l.x + u * l.y + f * l.z) * b.v.w;
    BirdOut o;
    o.rel = wp - U.cam.xyz;
    o.pos = U.viewProj * float4(o.rel, 1.0);
    o.lit = 0.5 + 0.5 * sin(b.p.w);
    return o;
}

fragment float4 birdFrag(BirdOut in [[stage_in]], constant ForestU& U [[buffer(0)]]) {
    float3 c = float3(0.03, 0.028, 0.026) * (ambient(float3(0.0, 1.0, 0.0), U) + U.sunCol.rgb * U.sun.w * 0.25 * in.lit);
    c = applyMist(c, in.rel, U);
    return float4(tonemap(c, U), 1.0);
}

// ---------------------------------------------------------------- light shafts (post, quarter size)

struct ShaftU { float2 sun; float aspect; float strength; float3 col; float pad; };
struct PostOut { float4 pos [[position]]; float2 uv; };

vertex PostOut postVert(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2) * 2.0 - 1.0;
    PostOut o; o.pos = float4(p, 0.0, 1.0); o.uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5); return o;
}

constexpr sampler linClampS(filter::linear, address::clamp_to_edge);

/// The sky's own brightness (alpha 0.98 marks sky; leaves and branches in front of it block it), weighted
/// towards the sun.
fragment float4 shaftMaskFrag(PostOut in [[stage_in]], texture2d<float> src [[texture(0)]], constant ShaftU& S [[buffer(0)]]) {
    float4 c = src.sample(linClampS, in.uv);
    float sky = clamp((1.0 - c.a) * 50.0, 0.0, 1.0);
    float2 d = (in.uv - S.sun) * float2(S.aspect, 1.0);
    float l = dot(c.rgb, float3(0.3, 0.5, 0.2));
    return float4(float3(smoothstep(0.35, 0.9, l) * sky * exp(-length(d) * 2.2)), 1.0);
}

/// Smears the mask towards the sun: rays through the gaps in the canopy.
fragment float4 shaftBlurFrag(PostOut in [[stage_in]], texture2d<float> src [[texture(0)]], constant ShaftU& S [[buffer(0)]]) {
    float2 step = (S.sun - in.uv) / 48.0 * 0.95;
    float2 uv = in.uv;
    float acc = 0.0, w = 1.0;
    float j = fract(52.9829189 * fract(dot(in.pos.xy, float2(0.06711056, 0.00583715))));
    uv += step * j;
    for (int i = 0; i < 48; i++) { acc += src.sample(linClampS, uv).r * w; w *= 0.965; uv += step; }
    return float4(float3(acc / 18.0), 1.0);
}

fragment float4 shaftAddFrag(PostOut in [[stage_in]], texture2d<float> src [[texture(0)]], constant ShaftU& S [[buffer(0)]]) {
    return float4(src.sample(linClampS, in.uv).r * S.strength * S.col, 0.0);
}

// ---------------------------------------------------------------- rocks

struct RockV { float4 p; float4 n; };
struct RockI { float4 p; float4 q; };               // foot (world) + size; q = turn, stretch x, stretch z, mossiness
constant uint ROCK_CAP = 8000;
constant float ROCK_CELL = 8.0;                     // 1024 cells per period

kernel void rockScatter(uint2 gid [[thread_position_in_grid]], constant ForestU& U [[buffer(0)]],
                        device atomic_uint* count [[buffer(1)]], device RockI* out [[buffer(2)]], texture2d<float> T [[texture(0)]]) {
    int N = 40;                                      // ±320 m
    if (int(gid.x) >= 2 * N || int(gid.y) >= 2 * N) return;
    int2 c = int2(floor(U.cam.xz / ROCK_CELL)) + int2(gid) - N;
    int cells = int(WP / ROCK_CELL);
    int2 hc = int2(c.x, ((c.y % cells) + cells) % cells);
    for (uint k = 0; k < 4; k++) {
        float h1 = fh(hc, 20u + k * 8u), h2 = fh(hc, 21u + k * 8u), h3 = fh(hc, 22u + k * 8u);
        float2 xz = (float2(c) + float2(h1, h2)) * ROCK_CELL;
        if (h3 > 0.95 || length_squared(xz - U.cam.xz) > 320.0 * 320.0 || columnOutside(U, xz - U.cam.xz, 4.0, 0.0)) continue;
        float width; float2 dg;
        float ae = riverDist(T, xz, width, dg);
        float bank = smoothstep(width * 0.4, width * 0.8, ae) * smoothstep(width * 2.4, width * 1.4, ae);
        float3 t = terrain(T, xz, 8);
        float slope = length(t.yz);
        float p = 0.55 * bank + 0.05 + 0.35 * smoothstep(0.4, 0.9, slope);
        if (h3 > p) continue;
        float size = bank > 0.3 ? 0.25 + 0.7 * pow(fh(hc, 23u + k * 8u), 2.0) : 0.4 + 1.6 * pow(fh(hc, 23u + k * 8u), 2.5);
        float3 rel = float3(xz.x, t.x, xz.y) - U.cam.xyz;
        float d = length(rel);
        if (d > 320.0) continue;
        bool vis = true;
        for (int i = 0; i < 4; i++) if (dot(U.planes[i].xyz, rel) + U.planes[i].w < -size * 2.0) vis = false;
        if (!vis) continue;
        uint idx = atomic_fetch_add_explicit(count, 1u, memory_order_relaxed);
        if (idx >= ROCK_CAP) return;
        RockI r;
        // sunk in deeper on a slope, so the low side doesn't hover
        r.p = float4(xz.x, t.x - size * (0.2 + 0.6 * min(slope, 1.0)), xz.y, size);
        r.q = float4(fh(hc, 24u + k * 8u) * 6.2831853, 0.8 + 0.5 * fh(hc, 25u + k * 8u), 0.8 + 0.5 * fh(hc, 26u + k * 8u),
                     (1.0 - bank) * smoothstep(-0.3, 0.3, nz(T, xz / 64.0 + 5.3).w));
        out[idx] = r;
    }
}

kernel void rockFinalize(device uint* count [[buffer(0)]], device uint* args [[buffer(1)]]) { args[1] = min(count[0], ROCK_CAP); }

struct RockOut { float4 pos [[position]]; float3 rel; float3 n; float3 lp; float ao; float moss; float vis [[flat]]; };

static float3 rockVertex(RockV v, RockI r, constant ForestU& U, thread float3 &n) {
    float c = cos(r.q.x), s = sin(r.q.x);
    float3 lp = v.p.xyz * float3(r.q.y, 1.0, r.q.z);
    lp.xz = float2(c * lp.x - s * lp.z, s * lp.x + c * lp.z);
    n = v.n.xyz / float3(r.q.y, 1.0, r.q.z);
    n.xz = float2(c * n.x - s * n.z, s * n.x + c * n.z);
    n = normalize(n);
    return r.p.xyz - U.cam.xyz + lp * r.p.w;
}

vertex RockOut rockVert(uint vid [[vertex_id]], uint iid [[instance_id]], const device RockV* V [[buffer(0)]],
                        const device RockI* I [[buffer(1)]], constant ForestU& U [[buffer(2)]]) {
    RockV v = V[vid]; RockI r = I[iid];
    RockOut o;
    float3 n;
    o.rel = rockVertex(v, r, U, n);
    o.pos = U.viewProj * float4(o.rel, 1.0);
    o.n = n;
    o.lp = v.p.xyz * 3.0 + r.q.x;
    o.ao = v.n.w;
    o.moss = r.q.w;
    o.vis = 1.0 - smoothstep(250.0, 320.0, length(o.rel));
    return o;
}

vertex float4 rockShadowVert(uint vid [[vertex_id]], uint iid [[instance_id]], const device RockV* V [[buffer(0)]],
                             const device RockI* I [[buffer(1)]], constant ForestU& U [[buffer(2)]], constant float4x4& LVP [[buffer(4)]]) {
    float3 n;
    return LVP * float4(rockVertex(V[vid], I[iid], U, n), 1.0);
}

fragment float4 rockFrag(RockOut in [[stage_in]], constant ForestU& U [[buffer(0)]], texture2d<float> T [[texture(0)]],
                         depth2d_array<float> S [[texture(1)]], GI_FRAG_PARAMS) {
    float3 N = normalize(in.n);
    float3 wp = in.rel + U.cam.xyz;
    float4 n1 = nz(T, in.lp.xz * 1.7 + in.lp.y), n2 = nz(T, wp.xz * 4.0 + wp.y * 3.0);
    float3 alb = mix(float3(0.17, 0.16, 0.15), float3(0.27, 0.25, 0.22), smoothstep(-0.4, 0.4, n1.x)) * (0.8 + 0.35 * n2.w);
    alb = mix(alb, float3(0.32, 0.31, 0.26), smoothstep(0.55, 0.7, n2.x) * 0.6);                       // lichen
    float moss = smoothstep(0.35, 0.75, N.y + 0.25 * n1.w) * (0.25 + 0.75 * in.moss);
    alb = mix(alb, float3(0.06, 0.1, 0.03) * (0.8 + 0.4 * n2.x), moss);
    alb *= mix(0.55, 1.0, smoothstep(-0.05, 0.25, wp.y - WATER));                                        // wet at the waterline
    alb *= 1.0 - 0.3 * U.seasonC.z;
    alb = mix(alb, SNOW, U.seasonA.x * smoothstep(0.35, 0.65, N.y + 0.25 * n1.x) * smoothstep(-0.05, 0.2, wp.y - WATER));
    float sh = shadowAt(in.rel, N, U, S);
    float3 c = alb * (U.sunCol.rgb * U.sun.w * max(dot(N, U.sun.xyz), 0.0) * sh + giAmbient(N, in.rel, U, G, GI_TEX)) * in.ao;
    GI_DEBUG_OUT(N)
    c = applyMist(c, in.rel, U);
    return float4(tonemap(c, U, (G.ground.w > 0.5 ? float3(0.5) : alb) * giFly(in.rel, U, G, gi0, gi4) * in.ao * mistT(in.rel, U)), fadeKeep(in.pos.xy, float3(1.0, 1.0, in.vis)) ? 1.0 : 0.0);
}
// ---------------------------------------------------------------- falling things: rain, snow, leaves, petals

constant uint P_NEAR = 14000, P_FAR = 10000, P_LEAF = 3000;      // = ForestGPU.precipNear / Far / Leaves

struct PrecipOut { float4 pos [[position]]; float2 uv; float4 col; float kind [[flat]]; };

/// Every particle lives in a box that tiles the world (32 m, or 128 m for the far rain / snow) and is wrapped to the
/// box around the camera, so there is always the same amount around it without any state: its place is a hash, plus
/// how far it has fallen (speed × time) and how far the wind has carried it (`drift`, integrated on the CPU).
vertex PrecipOut precipVert(uint vid [[vertex_id]], uint iid [[instance_id]], constant ForestU& U [[buffer(0)]]) {
    PrecipOut o;
    o.pos = float4(2.0, 2.0, 2.0, 1.0); o.uv = 0.0; o.col = 0.0; o.kind = 0.0;
    const float2 cs[6] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, -1), float2(1, 1), float2(-1, 1) };
    float2 c = cs[vid];
    int2 id = int2(int(iid), 977);
    float h0 = fh(id, 1u), h1 = fh(id, 2u), h5 = fh(id, 6u), h6 = fh(id, 7u), h7 = fh(id, 8u);
    float3 base = float3(fh(id, 3u), fh(id, 4u), fh(id, 5u));
    float time = U.cam.w;
    bool leafy = iid >= P_NEAR + P_FAR;
    float3 B; float3 p; float amount, kind;
    float alpha = 1.0;
    if (!leafy) {
        bool far = iid >= P_NEAR;
        B = far ? float3(128.0, 64.0, 128.0) : float3(32.0, 24.0, 32.0);
        float total = U.precip.x + U.precip.y;
        amount = min(1.0, total);
        bool snow = h1 < U.precip.y / max(total, 1e-4);
        kind = snow ? 1.0 : 0.0;
        float fall = snow ? 0.8 + 0.6 * h5 : 7.5 + 2.5 * h5;
        p = base * B + float3(U.drift.x, 0.0, U.drift.y) * (snow ? 1.0 : 0.35) - float3(0.0, fall * time, 0.0);
        if (snow) {   // flakes swirl as they fall
            p.x += 0.5 * sin(time * (0.6 + 0.8 * h6) + h7 * 6.2831853);
            p.z += 0.5 * cos(time * (0.5 + 0.7 * h7) + h6 * 6.2831853);
        }
        if (far) alpha = 0.7;
    } else {
        B = float3(32.0, 20.0, 32.0);
        float total = U.precip.z + U.precip.w;
        amount = min(1.0, total);
        bool petal = h1 < U.precip.w / max(total, 1e-4);
        kind = petal ? 3.0 : 2.0;
        float fall = petal ? 0.45 + 0.3 * h5 : 0.8 + 0.7 * h5;
        p = base * B + float3(U.drift.x, 0.0, U.drift.y) * (petal ? 1.3 : 1.15) - float3(0.0, fall * time, 0.0);
        // leaves rock from side to side as they fall
        float sw = time * (0.9 + 0.8 * h6) + h7 * 6.2831853;
        p.x += 0.7 * sin(sw); p.z += 0.5 * sin(sw * 0.7 + 1.0);
    }
    if (h0 > amount) return o;
    alpha *= clamp((amount - h0) / 0.04, 0.0, 1.0);
    // wrap into the box around the camera (vertically: more above it than below)
    float3 rel = p - U.cam.xyz;
    rel.xz -= B.xz * floor(rel.xz / B.xz + 0.5);
    rel.y -= B.y * floor(rel.y / B.y + 0.3);
    if (rel.y + U.cam.y < WATER + 0.02) return o;
    float dist = length(rel);
    if (dist < 0.3) return o;
    float3 V = rel / dist;
    float pix = dist * U.vel.w;                              // one pixel at this distance, metres
    float3 L = U.sun.xyz;
    float3 amb = ambient(float3(0.0, 1.0, 0.0), U);
    float3 pos;
    float3 col;
    if (kind < 0.5) {
        // rain: a thin streak along its motion relative to the camera (as a camera shutter would smear it)
        float3 vel = float3(U.drift.z * 0.35, -8.5, U.drift.w * 0.35) - U.vel.xyz;
        float3 len = vel * 0.022;
        float3 side = normalize(cross(len, V));
        float w = 0.0035;
        float wPix = max(w, pix * 0.6);
        alpha *= w / wPix * 0.55;
        pos = rel + len * (c.y * 0.5) + side * (c.x * wPix);
        col = amb * 1.6 + U.sunCol.rgb * U.sun.w * 0.15;
    } else if (kind < 1.5) {
        // a snowflake: a soft round spot facing the camera
        float r = 0.018 + 0.022 * h6 * h6;
        float rPix = max(r, pix * 0.8);
        alpha *= (r / rPix) * (r / rPix) * 0.95;
        float3 ex = normalize(cross(V, float3(0.0, 1.0, 0.0))), ey = cross(ex, V);
        pos = rel + (ex * c.x + ey * c.y) * rPix;
        col = SNOW * (amb * 1.8 + U.sunCol.rgb * U.sun.w * 0.45);
    } else {
        // a leaf or a petal tumbling: a small card turning about two axes
        float a = time * (1.2 + 2.5 * h6) + h7 * 6.2831853, b = time * (0.8 + 1.5 * h7) + h5 * 6.2831853;
        float3 ex = float3(cos(a), sin(a) * cos(b), sin(a) * sin(b));
        float3 ey = normalize(cross(ex, float3(sin(b), cos(b), 0.3)));
        float3 n = cross(ex, ey);
        float s = kind < 2.5 ? 0.035 + 0.025 * h5 : 0.012 + 0.006 * h5;
        float sPix = max(s, pix * 0.7);
        alpha *= (s / sPix) * (s / sPix);
        pos = rel + (ex * c.x + ey * (c.y * 0.75)) * sPix;
        float k = fract(h7 * 13.7);
        float3 alb = kind < 2.5
            ? (k < 0.35 ? float3(0.36, 0.25, 0.015) : (k < 0.65 ? float3(0.4, 0.14, 0.015) : (k < 0.85 ? float3(0.32, 0.035, 0.02) : float3(0.2, 0.1, 0.035))))
            : mix(float3(0.62, 0.6, 0.58), float3(0.62, 0.42, 0.5), step(0.5, k));
        float lit = abs(dot(n, L)) * 0.7 + pow(max(dot(-V, L), 0.0), 3.0) * 0.6;     // light through it towards the sun
        col = alb * (U.sunCol.rgb * U.sun.w * lit + amb * 1.2);
    }
    col = applyMist(col, rel, U);
    o.pos = U.viewProj * float4(pos, 1.0);
    o.uv = c;
    o.col = float4(col, alpha * (1.0 - smoothstep(B.x * 0.38, B.x * 0.5, length(rel.xz))));
    o.kind = kind;
    return o;
}

fragment float4 precipFrag(PrecipOut in [[stage_in]], constant ForestU& U [[buffer(0)]]) {
    float a;
    if (in.kind < 0.5) a = (1.0 - in.uv.x * in.uv.x) * (1.0 - in.uv.y * in.uv.y);
    else if (in.kind < 1.5) a = smoothstep(1.0, 0.2, length(in.uv));
    else a = smoothstep(1.0, 0.85, length(in.uv * float2(1.0, 1.0 + 0.3 * abs(in.uv.x))));    // a leaf's oval
    a *= in.col.a;
    if (a < 0.003) discard_fragment();
    return float4(tonemap(in.col.rgb, U), a);
}
// ---------------------------------------------------------------- fireflies (night)

struct FlyOut { float4 pos [[position]]; float2 uv; float3 col; float core [[flat]]; };

/// A firefly: a camera-facing glow sprite (a bright core of at least about a pixel + a soft halo), dimmed by the mist.
vertex FlyOut fireflyVert(uint vid [[vertex_id]], uint iid [[instance_id]], constant ForestU& U [[buffer(0)]],
                          const device float4* F [[buffer(1)]]) {
    const float2 cs[6] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, -1), float2(1, 1), float2(-1, 1) };
    float2 c = cs[vid];
    float4 f = F[iid * 2];
    FlyOut o;
    float3 rel = f.xyz - U.cam.xyz;
    float dist = length(rel);
    float3 V = rel / max(dist, 1e-3);
    float pix = dist * U.vel.w;
    float r = 0.03;                          // the glowing abdomen, metres
    float rPix = max(r, pix * 0.9);
    float R = max(0.45, pix * 5.0);          // the halo
    float3 ex = normalize(cross(V, float3(0.0, 1.0, 0.0))), ey = cross(ex, V);
    float3 pos = rel + (ex * c.x + ey * c.y) * R;
    // mist between it and the camera (the same density as applyMist)
    float hgt = max(0.0, U.cam.y + rel.y * 0.5);
    float dens = (0.00025 + 0.0045 * U.zenith.w) * (exp(-hgt * 0.015) + 0.12);
    float vis = exp(-dist * dens * 1.5) * (dist < 0.4 ? 0.0 : 1.0);
    o.pos = U.viewProj * float4(pos, 1.0);
    o.uv = c * R / rPix;                     // in core radii
    o.col = F[iid * 2 + 1].rgb * f.w * vis * min(1.0, (r / rPix) * (r / rPix) * 1.5 + 0.08);
    o.core = R / rPix;
    return o;
}

fragment float4 fireflyFrag(FlyOut in [[stage_in]], constant ForestU& U [[buffer(0)]]) {
    float d2 = dot(in.uv, in.uv);
    float core = exp(-d2 * 1.2);
    float q = d2 / (in.core * in.core);      // 0 … 1 over the halo
    float halo = exp(-q * 7.0) * 0.12 * min(1.0, in.core * 0.25);
    float3 c = in.col * (core * 2.2 + halo);
    if (max(c.r, c.g) < 0.001) discard_fragment();
    return float4(c, 0.0);
}
"""#
