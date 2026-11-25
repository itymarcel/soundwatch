// Metal shader source, compiled at runtime (no Xcode / metal toolchain needed).
let shaderSource = #"""
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 viewPx; float pxScale; float time;
    float4 cam0; float4 cam1; float4 cam2;
    float2 center; float2 pan;
    float zoom; float persp; float pad0; float pad1;
};

/// Camera transform of a scene point (window points, y down): tilt the scene plane in 3D, perspective, pan, zoom.
/// Returns the new point (xy) and its local scale (z) for widths.
static float3 camXf(float2 pt, constant Uniforms& U) {
    float3 l = float3(pt.x - U.center.x, U.center.y - pt.y, 0.0);
    float3 r = float3(dot(U.cam0.xyz, l), dot(U.cam1.xyz, l), dot(U.cam2.xyz, l));
    float k = U.zoom * U.persp / max(U.persp - r.z, 1.0);
    return float3(U.center + U.pan + float2(r.x, -r.y) * k, k);
}
struct Seg { float2 a; float2 b; float4 color; float width; float dash; float cap; float w; };   // w: inverse depth (Seg.w)

struct SphereU {
    float4 rot0; float4 rot1; float4 rot2;
    float2 center; float R; float cam;
    float dotR; float dispK; float phase; float colorByFreq;
    float lineW; float alphaK; float square; float dash;
    uint N; uint bandCount; uint mirror; uint mode;
    uint layout; uint histBands; uint histCols; uint head;
    float4 w0; float4 w1; float4 spin0; float4 spin1;
};

// Harmonics layout: real spherical harmonics Y(l, m), low bands → low degree l.
constant int2 sphereModes[8] = { int2(2,0), int2(2,2), int2(3,1), int2(4,3), int2(5,2), int2(6,5), int2(8,4), int2(10,7) };

/// Associated Legendre P_l^m(x) (Condon–Shortley sign dropped), by the standard recurrence.
static float legendreP(int l, int m, float x) {
    float s = sqrt(max(0.0, 1.0 - x * x));
    float pmm = 1.0, odd = 1.0;
    for (int i = 0; i < m; i++) { pmm *= odd * s; odd += 2.0; }
    if (l == m) return pmm;
    float pm1 = x * float(2 * m + 1) * pmm;
    if (l == m + 1) return pm1;
    float pl = 0.0;
    for (int ll = m + 2; ll <= l; ll++) {
        pl = (x * float(2 * ll - 1) * pm1 - float(ll + m - 1) * pmm) / float(ll - m);
        pmm = pm1; pm1 = pl;
    }
    return pl;
}

/// Scale that gives Y(l, m) = N · P_l^m(cos θ) · cos(m φ) an RMS of 1 over the sphere.
static float shNorm(int l, int m) {
    float ratio = 1.0;                                   // (l − m)! / (l + m)!
    for (int k = l - m + 1; k <= l + m; k++) ratio /= float(k);
    return m == 0 ? sqrt(float(2 * l + 1)) : sqrt(2.0 * float(2 * l + 1) * ratio);
}

/// Spectrum-weighted sum of 8 spherical harmonics. Returns the field and the index of the dominant mode.
static float2 sphereField(float3 p, constant SphereU& S) {
    float w[8] = { S.w0.x, S.w0.y, S.w0.z, S.w0.w, S.w1.x, S.w1.y, S.w1.z, S.w1.w };
    float spin[8] = { S.spin0.x, S.spin0.y, S.spin0.z, S.spin0.w, S.spin1.x, S.spin1.y, S.spin1.z, S.spin1.w };
    float y = clamp(p.y, -1.0, 1.0);
    float ph = atan2(p.z, p.x);
    float f = 0.0, best = 0.0, idx = 0.0;
    for (int k = 0; k < 8; k++) {
        if (w[k] < 1e-4) continue;
        int l = sphereModes[k].x, m = sphereModes[k].y;
        float c = w[k] * shNorm(l, m) * legendreP(l, m, y) * cos(float(m) * (ph + spin[k]));
        f += c;
        if (abs(c) > best) { best = abs(c); idx = float(k); }
    }
    return float2(f, idx);
}

struct BandU {
    float fMin; float ratio; float binHz; float floorDB;
    float gain; float tilt; float release; float attack;
    uint count; uint halfBins; uint levels; uint frozen;
};

struct WarpU { float decay; float zoom; float rot; float swirl; float ripple; float kaleido; float time; float aspect; };

struct SimU {
    float4 w0; float4 w1;
    float shake; float speed; float dtScale; float time;
    float turb; float noiseScale; float beat; float level;
    uint count; uint frame; uint bandCount; uint kind;
    float aspect; float p0; float p1; float p2;
};

struct PartDrawU {
    float2 origin; float2 extent;
    float dotR; float alphaK; float phase; float colorByFreq;
    float square; float streak; float domT; float speedK;
    uint kind; uint count; uint bandCount; uint pad;
};

struct SpectroU { float head; float rows; float phase; float colorByFreq; float mirror; float nearest; float bands; float cellPx; };

struct CompU {
    float4 ink;
    float4 bg;
    float glow; float scan; float vignette; float flicker;
    float bandY; float bgOpacity; float sceneGain; float cornerR;
    float time; float pxScale; float flickerRand; float grainSize;
    float4 grade;    // brightness, contrast, saturation, hue (turns)
    float4 fx;       // aberration px, pixel size px, posterize levels, invert
    float4 media;    // blend (-1 = none), opacity, displace px, fit
    float4 media2;   // media aspect, padded (blurred) texture flag, pad fraction x, y
    float4 mediaXf;  // offset x, y (screen heights), scale, angle
    float4 mediaKal; // kaleidoscope segments, tile mode, scene alpha = coverage (Real Metaballs)
    float4 fx2;      // soft focus, streak, edge fringe px, film grain
    float4 dist;     // distort style (0 = none), amount, phase (music time), beat push
    float4 dist2;    // distort scale
};

struct ShaderModeU {
    float4 view0; float4 view1; float4 view2;
    float2 viewPt; float2 center;
    float2 pan; float zoom; float world;
    float time; float phase; float colorByFreq; float level;
    float bass; float beat; float reach; float count;
    float4 p0; float4 p1;
    float4 p2;   // x = pixels of the render target per window point (set by the renderer)
};

// ---------------------------------------------------------------- helpers

constexpr sampler linClamp(filter::linear, address::clamp_to_edge);

static float pingPong(float t) { float m = t - 2.0 * floor(t * 0.5); return m <= 1.0 ? m : 2.0 - m; }

static float3 pal(texture2d<float> p, float t) {
    return p.sample(linClamp, float2((pingPong(t) * 255.0 + 0.5) / 256.0, 0.5), level(0.0)).rgb;
}

static uint pcg(uint v) {
    uint state = v * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}
static float rnd(uint a, uint b) { return float(pcg(a ^ pcg(b + 0x9E3779B9u))) * (1.0 / 4294967295.0); }

static float lattice(int3 c) { return float(pcg(uint(c.x) + pcg(uint(c.y) + pcg(uint(c.z))))) * (1.0 / 4294967295.0); }

/// Smooth 3D value noise in [0,1].
static float vnoise(float3 p) {
    int3 i = int3(floor(p));
    float3 f = fract(p);
    float3 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float n000 = lattice(i), n100 = lattice(i + int3(1,0,0)), n010 = lattice(i + int3(0,1,0)), n110 = lattice(i + int3(1,1,0));
    float n001 = lattice(i + int3(0,0,1)), n101 = lattice(i + int3(1,0,1)), n011 = lattice(i + int3(0,1,1)), n111 = lattice(i + int3(1,1,1));
    return mix(mix(mix(n000, n100, u.x), mix(n010, n110, u.x), u.y),
               mix(mix(n001, n101, u.x), mix(n011, n111, u.x), u.y), u.z);
}


static float hash(float2 p) { return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453); }
/// Integer hash (no sin): uniform 0…1 with no repeating structure, even for big pixel coordinates.
static float hashU(int2 p, uint seed) {
    uint h = uint(p.x) * 1597334673u ^ uint(p.y) * 3812015801u ^ seed * 2798796415u;
    h = (h ^ (h >> 16)) * 0x7feb352du;
    h = (h ^ (h >> 15)) * 0x846ca68bu;
    h ^= h >> 16;
    return float(h) * (1.0 / 4294967296.0);
}
/// Signed grain value at a lattice point (triangular distribution, −1…1).
static float grainAt(int2 p, uint seed) { return hashU(p, seed) + hashU(p, seed ^ 0x9e3779b9u) - 1.0; }

// ---------------------------------------------------------------- segments (lines, dots, rects)

struct SegOut {
    float4 pos [[position]];
    float2 local;
    float4 color;
    float len; float hw; float dash; float cap; float dashBase; float alphaK;
    float w;   // inverse depth for depth of field (0 = none: a flat mode's scene plane)
};

/// What the scene pass writes: the light, and (attachment 1, rg16Float) inverse depth × coverage and the coverage, summed
/// (or "over"-blended for shaded surfaces), so the depth-of-field pass can take the light-weighted mean depth = r / g.
/// Pipelines that don't write depth mask attachment 1 off (their pixels fall back to the scene plane's depth).
struct SceneOut { float4 c [[color(0)]]; float4 d [[color(1)]]; };
struct SceneOutH { half4 c [[color(0)]]; half4 d [[color(1)]]; };
static SceneOut sceneOut(float4 c, float w) {
    SceneOut o;
    o.c = c;
    o.d = w > 0.0 ? float4(w * c.a, c.a, 0.0, 0.0) : float4(0.0);
    return o;
}

static SegOut makeSeg(float2 aPt, float2 bPt, float widthPt, float4 color, float dashPt, float cap,
                      uint vid, constant Uniforms& U, float w = 0.0) {
    SegOut o;
    o.w = w;
    float s = U.pxScale;
    float3 ca = camXf(aPt, U), cb = camXf(bPt, U);
    float2 a = ca.xy * s, b = cb.xy * s;
    float wpx = widthPt * s * 0.5 * (ca.z + cb.z);
    float hw = max(wpx * 0.5, 0.5);
    float2 d = b - a;
    float len = length(d);
    float2 dir = len > 1e-4 ? d / len : float2(1.0, 0.0);
    float2 nrm = float2(-dir.y, dir.x);
    float ext = hw + 0.5;   // coverage reaches 0 half a pixel outside the shape: no wider quad needed
    float u = (vid & 1) ? len + ext : -ext;
    float v = (vid & 2) ? ext : -ext;
    float2 p = a + dir * u + nrm * v;
    float2 ndc = p / U.viewPx * 2.0 - 1.0;
    o.pos = float4(ndc.x, -ndc.y, 0.0, 1.0);
    o.local = float2(u, v);
    o.color = color;
    o.len = len; o.hw = hw; o.dash = dashPt * s; o.cap = cap;
    o.dashBase = dot(a, dir);
    o.alphaK = min(1.0, wpx);
    return o;
}

// ---------------------------------------------------------------- dots as point sprites
// A dot drawn as one point primitive instead of a 4-vertex quad, carrying as little per vertex as possible (position,
// size, one flat half-float colour): with millions of dots the GPU's time goes into storing and sorting the
// transformed primitives into tiles, not into pixels. Same coverage maths as segFrag.

struct DotOut {
    float4 pos [[position]];
    float size [[point_size]];      // 2 × (half width + ½ px of soft edge)
    half4 color [[flat]];           // premultiplied
    float hw [[flat]];              // half width in pixels (the point size itself can't be read by the fragment)
    half w [[flat]];                // inverse depth for depth of field (0 = none)
};

static DotOut makeDot(float2 pt, float widthPt, float4 color, constant Uniforms& U, float w = 0.0) {
    DotOut o;
    o.w = half(w);
    float3 c = camXf(pt, U);
    float2 p = c.xy * U.pxScale;
    float wpx = widthPt * U.pxScale * c.z;
    float hw = min(max(wpx * 0.5, 0.5), 250.0);
    float2 ndc = p / U.viewPx * 2.0 - 1.0;
    o.pos = float4(ndc.x, -ndc.y, 0.0, 1.0);
    o.size = 2.0 * hw + 1.0;
    o.hw = hw;
    float a = color.a * min(1.0, wpx);
    o.color = half4(float4(color.rgb * a, a));
    return o;
}

/// `square` (buffer 0): 0 = round dots, 1 = square ones.
fragment SceneOutH dotFrag(DotOut in [[stage_in]], float2 pc [[point_coord]], constant float& square [[buffer(0)]]) {
    float2 l = (pc - 0.5) * (2.0 * in.hw + 1.0);
    float d = square < 0.5 ? length(l) - in.hw : max(abs(l.x), abs(l.y)) - in.hw;
    SceneOutH o;
    o.c = in.color * half(clamp(0.5 - d, 0.0, 1.0));
    o.d = in.w > 0.0h ? half4(in.w * o.c.a, o.c.a, 0.0h, 0.0h) : half4(0.0h);
    return o;
}

// ---------------------------------------------------------------- chrome (Chrome surface look, Orbs)

/// Chrome settings: environment turn (1 = full turn), blur, palette tint, exposure. Matches Swift ChromeUniforms.
struct ChromeU { float turn; float blur; float tint; float exposure; };

constexpr sampler envSampler(filter::linear, mip_filter::linear, s_address::repeat, t_address::clamp_to_edge);

/// The HDR environment (equirectangular, Resources/env) seen in view-space direction `d` (y up, +z towards the
/// viewer), turned by `K.turn` (1 = a full turn). `lod` picks a blurrier mip level.
static float3 chromeEnv(float3 d, ChromeU K, texture2d<float> env, float lod) {
    float u = atan2(d.x, -d.z) * (0.5 / M_PI_F) + 0.5 + K.turn;
    float v = acos(clamp(d.y, -1.0, 1.0)) * (1.0 / M_PI_F);

    // the maps hold linear light, the scene is display-referred: gamma-encode (bright HDR values stay above 1 and bloom)
    return pow(max(env.sample(envSampler, float2(u, v), level(lod)).rgb * K.exposure, 0.0), float3(1.0 / 2.2));
}

/// Metal Fresnel (Schlick): F0 a cool silver, optionally tinted towards a palette colour; whiter at grazing angles.
static float3 chromeFresnel(float3 N, float3 V, float3 tint, ChromeU K) {
    float m = max(tint.r, max(tint.g, tint.b));
    float3 F0 = mix(float3(0.60, 0.61, 0.64), (m > 1e-4 ? tint / m : float3(1.0)) * 0.8, K.tint);
    return F0 + (1.0 - F0) * pow(1.0 - clamp(dot(N, V), 0.0, 1.0), 5.0);
}

/// The environment reflected off a surface with normal N seen from V (view space, N facing V), blurred by K.blur:
/// a blurrier mip level plus a few reflection samples spread over a cone (jittered per pixel by `seed`).
static float3 chromeReflect(float3 N, float3 V, float2 seed, ChromeU K, texture2d<float> env) {
    float3 R = reflect(-V, N);
    if (K.blur < 0.01) return chromeEnv(R, K, env, 0.0);
    float3 T = normalize(cross(abs(R.y) < 0.95 ? float3(0.0, 1.0, 0.0) : float3(1.0, 0.0, 0.0), R));
    float3 Bt = cross(R, T);
    float spread = 0.3 * K.blur, lod = K.blur * 6.5;
    float j = hash(seed), rot = hash(seed + 5.17) * 6.2832;
    float3 acc = float3(0.0);
    // the samples' angles step by the golden angle: turned by a fixed rotation instead of a sin / cos each
    const float2 golden = float2(cos(2.39996), sin(2.39996));
    float2 cs = float2(cos(rot), sin(rot));
    for (int i = 0; i < 4; i++, cs = float2(cs.x * golden.x - cs.y * golden.y, cs.x * golden.y + cs.y * golden.x)) {
        float r = sqrt((float(i) + j) / 4.0) * spread;
        float3 Rs = normalize(R + (T * cs.x + Bt * cs.y) * r);
        if (dot(Rs, N) < 0.0) Rs = reflect(Rs, N);   // keep samples above the surface
        acc += chromeEnv(Rs, K, env, lod);
    }
    return acc * 0.25;
}

/// Chrome: the (blurred) environment times Fresnel. N, V in view space; `ao` darkens creases.
static float3 chromeShade(float3 N, float3 V, float3 tint, float ao, float2 seed, ChromeU K, texture2d<float> env) {
    if (dot(N, V) < 0.0) N = -N;                       // two-sided surfaces
    return chromeReflect(N, V, seed, K, env) * chromeFresnel(N, V, tint, K) * ao;
}

// ---------------------------------------------------------------- shaded triangles (3D surfaces)

struct TriV { float2 p; float2 depth; float4 color; float4 n; float4 e; };   // depth.x = inverse depth (TriVert.depth)
struct TriOut { float4 pos [[position]]; float4 color; float4 n; float4 e; float w; };

/// Pre-projected, pre-lit triangle vertices (window points); only pan/zoom is applied here.
vertex TriOut triVert(uint vid [[vertex_id]], const device TriV* T [[buffer(0)]], constant Uniforms& U [[buffer(1)]]) {
    TriV t = T[vid];
    float2 px = camXf(t.p, U).xy * U.pxScale;
    float2 ndc = px / U.viewPx * 2.0 - 1.0;
    TriOut o;
    o.pos = float4(ndc.x, -ndc.y, 0.0, 1.0);
    o.color = t.color;
    o.n = t.n; o.e = t.e;
    o.w = t.depth.x;
    return o;
}

fragment SceneOut triFrag(TriOut in [[stage_in]], constant ChromeU& K [[buffer(0)]], texture2d<float> env [[texture(0)]]) {
    float3 c = in.color.rgb;
    if (in.n.w > 0.5) c = chromeShade(normalize(in.n.xyz), normalize(in.e.xyz), c, 1.0, in.pos.xy, K, env);
    return sceneOut(float4(c * in.color.a, in.color.a), in.w);       // premultiplied
}

vertex SegOut segVert(uint vid [[vertex_id]], uint iid [[instance_id]],
                      const device Seg* segs [[buffer(0)]], constant Uniforms& U [[buffer(1)]]) {
    Seg g = segs[iid];
    return makeSeg(g.a, g.b, g.width, g.color, g.dash, g.cap, vid, U, g.w);
}

fragment SceneOut segFrag(SegOut in [[stage_in]]) {
    float u = in.local.x, v = in.local.y;
    float d;
    if (in.cap < 0.5) {
        float cu = clamp(u, 0.0, in.len);
        d = length(float2(u - cu, v)) - in.hw;
    } else {
        float du = in.len < 1e-3 ? abs(u) - in.hw : max(-u, u - in.len);
        d = max(du, abs(v) - in.hw);
    }
    float cov = clamp(0.5 - d, 0.0, 1.0) * in.alphaK;
    if (in.dash > 0.0) {
        float k = fract((in.dashBase + u) / in.dash);
        cov *= step(k, 0.62);
    }
    float a = in.color.a * cov;
    return sceneOut(float4(in.color.rgb * a, a), in.w);
}

// ---------------------------------------------------------------- sphere (fully GPU)

struct SpherePt { float2 sp; float2 bp; float3 col; float alpha; float fade; float a; float proj; float p0; };

static SpherePt spherePoint(uint iid, const device float4* unit, const device float* vals, constant SphereU& S,
                            const device float* hist, texture2d<float> palTex) {
    float4 u4 = unit[iid];
    float3 p = u4.xyz;
    float frac = u4.w;                                   // where in the spectrum this point sits (0 = low)
    if (S.mirror != 0) frac = 1.0 - abs(2.0 * frac - 1.0);
    float a;
    float disp;
    if (S.layout == 3) {
        // Harmonics: signed bulges in and out; colour by the dominant mode, brightness by local strength.
        float2 fi = sphereField(p, S);
        a = min(abs(fi.x) * 2.0, 1.5);
        disp = max(0.3, 1.0 + fi.x);
        frac = (fi.y + 0.5) / 8.0;
    } else {
        if (S.layout == 1 || S.layout == 2) {
            uint b = min(uint(frac * float(S.histBands)), S.histBands - 1);
            uint c;
            if (S.layout == 1) {
                float az = atan2(p.z, p.x) / (2.0 * M_PI_F) + 0.5;      // time globe: longitude = time
                c = min(uint(az * float(S.histCols)), S.histCols - 1);
            } else {
                float lat = acos(clamp(p.y, -1.0, 1.0)) / M_PI_F;      // ripples: top pole = now, bottom = oldest
                c = min(uint(lat * float(S.histCols - 1)), S.histCols - 1);
            }
            uint row = (S.head + S.histCols - c) % S.histCols;
            a = hist[row * S.histBands + b];
        } else {
            a = vals[min(uint(frac * float(S.bandCount)), S.bandCount - 1)];
        }
        disp = 1.0 + a * S.dispK;
    }
    float3 q = float3(dot(S.rot0.xyz, p), dot(S.rot1.xyz, p), dot(S.rot2.xyz, p));
    SpherePt o;
    o.a = a;
    o.proj = S.cam / (S.cam - q.z * disp);
    o.sp = S.center + float2(q.x, -q.y) * disp * S.R * o.proj;
    o.fade = 0.15 + 0.85 * (q.z + 1.0) * 0.5;
    float t = (S.colorByFreq > 0.5 ? frac : min(a, 1.0)) + S.phase;
    o.col = pal(palTex, t);
    o.alpha = o.fade * (0.3 + 0.7 * min(a * 1.2, 1.0)) * S.alphaK;
    o.p0 = S.cam / (S.cam - q.z);
    o.bp = S.center + float2(q.x, -q.y) * S.R * o.p0;
    return o;
}

/// Spikes (mode 1): each point computed once per frame by `spherePrepKernel` (a spike's 4 vertices all need it: doing
/// it per vertex was most of the vertex cost with a million points), then a quad from the rest position to the
/// displaced one with slim, mostly flat outputs (the tiler stores every vertex's outputs).
/// Spikes (mode 1): each point computed once per frame by `spherePrepKernel` (a spike's 4 vertices all needed it),
/// then a quad from the rest position to the displaced one. (Slimmer `[[flat]]` outputs were tried: 2.5× slower.)
struct SpikeP { float2 sp; float2 bp; half4 col; half w; half pad0; float pad1; };

kernel void spherePrepKernel(const device float4* unit [[buffer(0)]], const device float* vals [[buffer(1)]],
                             constant SphereU& S [[buffer(2)]], const device float* hist [[buffer(4)]],
                             device SpikeP* out [[buffer(5)]], texture2d<float> palTex [[texture(0)]],
                             uint i [[thread_position_in_grid]]) {
    if (i >= S.N) return;
    SpherePt q = spherePoint(i, unit, vals, S, hist, palTex);
    SpikeP o;
    o.sp = q.sp; o.bp = q.bp;
    o.col = half4(half3(q.col), half(q.alpha));
    o.w = half(0.5 * (q.proj + q.p0));
    o.pad0 = 0.0h; o.pad1 = 0.0;
    out[i] = o;
}

vertex SegOut sphereVert(uint vid [[vertex_id]], uint iid [[instance_id]],
                         const device SpikeP* P [[buffer(0)]], constant SphereU& S [[buffer(2)]],
                         constant Uniforms& U [[buffer(3)]]) {
    SpikeP q = P[iid];
    return makeSeg(q.bp, q.sp, S.lineW, float4(q.col), S.dash, S.dash > 0.0 ? 1.0 : 0.0, vid, U, float(q.w));
}

/// Dots (mode 0) and base dots (mode 2): one point primitive each.
vertex DotOut sphereDotVert(uint vid [[vertex_id]],
                            const device float4* unit [[buffer(0)]], const device float* vals [[buffer(1)]],
                            constant SphereU& S [[buffer(2)]], constant Uniforms& U [[buffer(3)]],
                            const device float* hist [[buffer(4)]],
                            texture2d<float> palTex [[texture(0)]]) {
    SpherePt q = spherePoint(vid, unit, vals, S, hist, palTex);
    if (S.mode == 0) {
        float r = S.dotR * q.proj * (0.6 + 1.6 * q.a);
        return makeDot(q.sp, 2.0 * r, float4(q.col, q.alpha), U, q.proj);
    }
    float r = S.dotR * q.p0 * 0.45;
    return makeDot(q.bp, 2.0 * r, float4(q.col, q.fade * 0.35 * S.alphaK), U, q.p0);
}

/// Per-point frequency band value with attack/release smoothing, sampled from a max-pyramid of the spectrum.
kernel void bandKernel(device float* vals [[buffer(0)]], const device float* pyr [[buffer(1)]],
                       constant uint* offs [[buffer(2)]], constant BandU& B [[buffer(3)]],
                       uint i [[thread_position_in_grid]]) {
    if (i >= B.count) return;
    float old = vals[i];
    if (B.frozen != 0) return;
    float n = float(B.count);
    float f0 = B.fMin * pow(B.ratio, float(i) / n);
    float f1 = B.fMin * pow(B.ratio, float(i + 1) / n);
    float fc = sqrt(f0 * f1);
    float b0 = f0 / B.binHz, b1 = f1 / B.binHz;
    float hb = float(B.halfBins);
    float a;
    if (b1 - b0 < 1.0) {
        float c = clamp(fc / B.binHz, 1.0, hb - 2.0);
        uint i0 = uint(c);
        float f = c - float(i0);
        a = mix(pyr[i0], pyr[i0 + 1], f);
    } else {
        uint L = min(B.levels - 1, uint(floor(log2(b1 - b0))));
        uint lo = uint(clamp(b0, 1.0, hb - 1.0)) >> L;
        uint hi = uint(clamp(b1, 1.0, hb - 1.0)) >> L;
        a = 0.0;
        for (uint k = lo; k <= hi; k++) a = max(a, pyr[offs[L] + k]);
    }
    float db = 20.0 * log10(a + 1e-9) + B.tilt * log2(fc / 1000.0);
    float v = min(1.5, max(0.0, (db - B.floorDB) / -B.floorDB) * B.gain);
    float k = v > old ? B.attack : B.release;
    vals[i] = old * k + v * (1.0 - k);
}

/// Copies the current band values into one column of the time-globe history ring.
kernel void pushKernel(device float* hist [[buffer(0)]], const device float* vals [[buffer(1)]],
                       constant uint2& P [[buffer(2)]], uint i [[thread_position_in_grid]]) {
    if (i < P.x) hist[P.y + i] = vals[i];
}

// ---------------------------------------------------------------- particles (Cymatics + Flow)

/// One square free-plate mode, normalised to [-1, 1]: m = (n, m, sign).
static float chladniMode(float2 p, float3 m) {
    float a = M_PI_F * p.x, b = M_PI_F * p.y;
    return 0.5 * (cos(m.x * a) * cos(m.y * b) + m.z * cos(m.y * a) * cos(m.x * b));
}

/// Plate displacement: crossfade from the previous mode (w0) to the current one (w1, w1.w = progress).
static float chladni(float2 p, constant SimU& U) {
    return mix(chladniMode(p, U.w0.xyz), chladniMode(p, U.w1.xyz), U.w1.w);
}

/// Sand on a vibrating plate: grains are kicked about in proportion to how much the plate moves under them,
/// plus a drift down ∇(f²), so they collect on the still nodal lines. Steps scale with the mode's wavelength.
kernel void cymaticsKernel(device float4* P [[buffer(0)]], constant SimU& U [[buffer(1)]], uint i [[thread_position_in_grid]]) {
    if (i >= U.count) return;
    float2 p = P[i].xy;
    float kA = length(U.w0.xy), kB = length(U.w1.xy);
    float ks = M_PI_F * max(mix(kA, kB, U.w1.w), 1.0);                  // spatial angular frequency
    float e = 0.02 / ks;
    float f = chladni(p, U);
    float fx = chladni(p + float2(e, 0), U) - chladni(p - float2(e, 0), U);
    float fy = chladni(p + float2(0, e), U) - chladni(p - float2(0, e), U);
    float2 g = 2.0 * f * float2(fx, fy) / (2.0 * e);                    // ∇(f²)
    float amp = abs(f);
    float2 jitter = float2(rnd(pcg(i * 2u + 1u), U.frame), rnd(pcg(i * 2u + 2u) ^ 0x68E31DA4u, U.frame + 0x1B56C4E9u)) - 0.5;
    // Reach (p0) scales how far grains are kicked, not how fast they settle: the figure must always form.
    float2 v = -g / (ks * ks) * 0.05 * U.speed
             + jitter * (amp + 0.01) * (U.shake + U.beat * 2.5) * 0.12 / ks * U.p0;
    v *= U.dtScale;
    p += v;
    if (any(p < 0.0) || any(p > 1.0) || rnd(i, U.frame + 777u) < 0.0003) {
        // x and y from independent streams (the old pair, frame + 11 / frame + 23, were correlated and dropped the
        // respawned grains on the plate's diagonal: a line through every figure)
        p = float2(rnd(pcg(i * 2u + 1u), U.frame), rnd(pcg(i * 2u + 2u) ^ 0x68E31DA4u, U.frame + 0x1B56C4E9u));
        v = 0.0;
    }
    P[i] = float4(p, v);
}

/// Curl-noise flow; every particle belongs to a frequency band and moves with that band's energy.
kernel void flowKernel(device float4* P [[buffer(0)]], const device float* vals [[buffer(1)]],
                       constant SimU& U [[buffer(2)]], uint i [[thread_position_in_grid]]) {
    if (i >= U.count) return;
    float2 p = P[i].xy;
    float frac = rnd(i, 12345u);
    float level = vals[min(uint(frac * float(U.bandCount)), U.bandCount - 1)];
    float3 q = float3(p.x * U.aspect * U.noiseScale, p.y * U.noiseScale, U.time * 0.12);
    const float e = 0.01;
    float t2 = U.turb;
    float n0 = vnoise(q) + t2 * 0.5 * vnoise(q * 2.3 + 7.1);
    float nx = vnoise(q + float3(e, 0, 0)) + t2 * 0.5 * vnoise((q + float3(e, 0, 0)) * 2.3 + 7.1);
    float ny = vnoise(q + float3(0, e, 0)) + t2 * 0.5 * vnoise((q + float3(0, e, 0)) * 2.3 + 7.1);
    float2 curl = float2(ny - n0, -(nx - n0)) / e;
    float speed = U.speed * (0.08 + level * 1.4);
    float2 v = curl * speed * 0.0016;
    v.x /= U.aspect;
    float2 d = p - 0.5;
    v += normalize(d + 1e-5) * U.beat * 0.006;                           // beat burst
    v *= U.dtScale * U.p0;                                              // p0 = Reach
    p = fract(p + v + 1.0);
    if (rnd(i, U.frame + 99u) < 0.0015) p = float2(rnd(i, U.frame + 5u), rnd(i, U.frame + 6u));
    P[i] = float4(p, v);
}

/// Field, Points style (FieldViz / FieldGPUDraw): steps every particle as FieldViz.simulate did on the CPU (spring
/// home, the bodies' solid cores and pull) and writes its dot as the CPU loop did, into the splat list's place.
struct FieldU {
    float4 view0; float4 view1; float4 view2;    // columns of the view matrix
    float2 center; float world; float lw;
    float spring; float damp; float dt; float ballR;
    float phase; float byFreq; float square; float stopCount;
    uint count; uint bodyCount; uint simulate; uint pad;
};

/// Palette.rgb on the GPU: the same linear interpolation between the palette's stops (S, stopCount of them).
static float3 paletteStops(constant float4* S, float n, float t) {
    float u = pingPong(t) * (n - 1.0);
    int i = min(int(u), int(n) - 2);
    float f = u - float(i);
    return S[i].xyz + (S[i + 1].xyz - S[i].xyz) * f;
}

kernel void fieldKernel(const device float3* H [[buffer(0)]], device float3* P [[buffer(1)]], device float3* V [[buffer(2)]],
                        device Seg* out [[buffer(3)]], constant FieldU& U [[buffer(4)]], constant float4* B [[buffer(5)]],
                        constant float4* S [[buffer(6)]], uint i [[thread_position_in_grid]]) {
    if (i >= U.count) return;
    float3 p = P[i], h = H[i];
    if (U.simulate != 0) {
        float3 force = (h - p) * U.spring;
        for (uint j = 0; j < U.bodyCount; j++) {
            float4 b0 = B[2 * j], b1 = B[2 * j + 1];   // (pos, r), (range, range², mass·k·reach)
            float3 d = p - b0.xyz;
            float r = b0.w;
            float d2 = length_squared(d);
            if (d2 >= b1.y) continue;
            float dist = max(sqrt(d2), 1e-4);
            float3 dir = d / dist;
            if (dist < r) {
                force += dir * (r - dist) * 60.0;                            // solid: no entry, push to the surface
            } else {
                float g = b1.z / (dist * dist + 0.02);                        // gravity-like pull toward the surface
                float fade = 1.0 - (dist - r) / (b1.x - r);
                force -= dir * g * fade * fade;
            }
        }
        float3 v = (V[i] + force * U.dt) * U.damp;
        V[i] = v;
        p = p + v * U.dt;
        P[i] = p;
    }
    float e = min(1.0, length(p - h) * 5.0);
    float tc = U.byFreq > 0.5 ? (h.x + U.ballR) / (2.0 * U.ballR) : 0.3 + 0.7 * e;
    float3 q = float3x3(U.view0.xyz, U.view1.xyz, U.view2.xyz) * p;
    float k = 3.6 / max(0.3, 3.6 - q.z);                                     // project() with camDist 3.6
    float2 pt = U.center + float2(q.x, -q.y) * U.world * k;
    Seg g;
    g.a = pt; g.b = pt;
    g.color = float4(paletteStops(S, U.stopCount, tc + U.phase), 0.4 + 0.6 * e);
    g.width = 2.0 * U.lw * k; g.dash = 0.0; g.cap = U.square; g.w = k;
    out[i] = g;
}

struct PartPt { float2 sp; float2 vpx; float4 color; };

static PartPt partPoint(uint iid, const device float4* P, const device float* vals, constant PartDrawU& D,
                        texture2d<float> palTex) {
    float4 s = P[iid];
    PartPt o;
    o.sp = D.origin + s.xy * D.extent;
    o.vpx = s.zw * D.extent;
    float speed = length(s.zw) * D.speedK;
    float t;
    float alpha;
    if (D.kind == 0) {   // cymatics
        t = D.colorByFreq > 0.5 ? D.domT + 0.35 * length(s.xy - 0.5) : min(speed, 1.0);
        alpha = D.alphaK * (0.55 + 0.45 * min(speed, 1.0));
    } else {             // flow
        float frac = rnd(iid, 12345u);
        float level = vals[min(uint(frac * float(D.bandCount)), D.bandCount - 1)];
        t = D.colorByFreq > 0.5 ? frac : min(speed, 1.0);
        alpha = D.alphaK * (0.25 + 0.75 * min(level, 1.0));
    }
    o.color = float4(pal(palTex, t + D.phase), alpha);
    return o;
}

/// Streaks: a quad per particle, stretched back along its velocity. Like the dots, it carries as little per vertex as
/// it can (see DotOut): with a million streaks the transformed vertices are what costs.
struct StreakOut {
    float4 pos [[position]];
    float2 local;
    half4 color [[flat]];           // premultiplied
    float2 lenHw [[flat]];          // length and half width, pixels
};

vertex StreakOut partVert(uint vid [[vertex_id]], uint iid [[instance_id]],
                          const device float4* P [[buffer(0)]], const device float* vals [[buffer(1)]],
                          constant PartDrawU& D [[buffer(2)]], constant Uniforms& U [[buffer(3)]],
                          texture2d<float> palTex [[texture(0)]]) {
    PartPt q = partPoint(iid, P, vals, D, palTex);
    float2 tail = q.sp;
    if (length(q.vpx) > 0.05) {
        tail = q.sp - q.vpx * D.streak;
        if (length(tail - q.sp) > D.extent.x * 0.25) tail = q.sp;        // skip wrap-around jumps
    }
    float3 ca = camXf(tail, U), cb = camXf(q.sp, U);
    float2 a = ca.xy * U.pxScale, b = cb.xy * U.pxScale;
    float wpx = D.dotR * 2.0 * U.pxScale * 0.5 * (ca.z + cb.z);
    float hw = max(wpx * 0.5, 0.5);
    float2 d = b - a;
    float len = length(d);
    float2 dir = len > 1e-4 ? d / len : float2(1.0, 0.0);
    float ext = hw + 0.5;
    float u = (vid & 1) ? len + ext : -ext;
    float v = (vid & 2) ? ext : -ext;
    float2 ndc = (a + dir * u + float2(-dir.y, dir.x) * v) / U.viewPx * 2.0 - 1.0;
    StreakOut o;
    o.pos = float4(ndc.x, -ndc.y, 0.0, 1.0);
    o.local = float2(u, v);
    float al = q.color.a * min(1.0, wpx);
    o.color = half4(float4(q.color.rgb * al, al));
    o.lenHw = float2(len, hw);
    return o;
}

fragment half4 streakFrag(StreakOut in [[stage_in]]) {
    float cu = clamp(in.local.x, 0.0, in.lenHw.x);
    float d = length(float2(in.local.x - cu, in.local.y)) - in.lenHw.y;
    return in.color * half(clamp(0.5 - d, 0.0, 1.0));
}

/// Dots: one point primitive per particle.
vertex DotOut partDotVert(uint vid [[vertex_id]],
                          const device float4* P [[buffer(0)]], const device float* vals [[buffer(1)]],
                          constant PartDrawU& D [[buffer(2)]], constant Uniforms& U [[buffer(3)]],
                          texture2d<float> palTex [[texture(0)]]) {
    PartPt q = partPoint(vid, P, vals, D, palTex);
    return makeDot(q.sp, D.dotR * 2.0, q.color, U);
}

// ---------------------------------------------------------------- full-screen passes

struct FSOut { float4 pos [[position]]; float2 uv; };

vertex FSOut fsVert(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    FSOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

/// Inverse of camXf: the scene point (window points) seen at screen point `sPt`, found by intersecting the view ray with the tilted plane.
static float2 camInv(float2 sPt, constant Uniforms& U) {
    float2 q = (sPt - U.center - U.pan) / U.zoom;
    q.y = -q.y;
    float3 c0 = float3(U.cam0.x, U.cam1.x, U.cam2.x), c1 = float3(U.cam0.y, U.cam1.y, U.cam2.y);
    float P = U.persp;
    float a = c0.x * P + q.x * c0.z, b = c1.x * P + q.x * c1.z;
    float c = c0.y * P + q.y * c0.z, d = c1.y * P + q.y * c1.z;
    float det = a * d - b * c;
    if (abs(det) < 1e-6) return float2(-1e6);
    float lx = (q.x * P * d - b * q.y * P) / det;
    float ly = (a * q.y * P - c * q.x * P) / det;
    return float2(U.center.x + lx, U.center.y - ly);
}

fragment float4 spectroFrag(FSOut in [[stage_in]], texture2d<float> hist [[texture(0)]],
                            texture2d<float> palTex [[texture(1)]], constant SpectroU& P [[buffer(0)]],
                            constant Uniforms& U [[buffer(1)]]) {
    float2 uv = camInv(in.pos.xy / U.pxScale, U) / (U.viewPx / U.pxScale);
    if (any(uv < 0.0) || any(uv > 1.0)) return float4(0.0);
    float x = uv.x;
    if (P.mirror > 0.5) x = abs(x - 0.5) * 2.0;
    float rowF = P.head - uv.y * (P.rows - 1.0);
    rowF = rowF - P.rows * floor(rowF / P.rows);
    float v;
    if (P.nearest > 0.5) {
        float bx = min(x * P.bands, P.bands - 1.0);
        v = hist.read(uint2(uint(bx), uint(rowF))).r;
        if (P.cellPx > 4.0) v *= step(0.14, fract(bx)) * step(0.25, fract(rowF));
    } else {
        constexpr sampler s(filter::linear, s_address::clamp_to_edge, t_address::repeat);
        v = hist.sample(s, float2(x, (rowF + 0.5) / P.rows)).r;
    }
    v = min(v, 1.0);
    float t = (P.colorByFreq > 0.5 ? x * 0.85 + v * 0.15 : v) + P.phase;
    float a = pow(v, 1.3);
    return float4(pal(palTex, t) * a, a);
}

/// MilkDrop-style feedback: previous frame resampled through an audio-driven zoom / spin / swirl / ripple / kaleidoscope.
fragment float4 fadeFrag(FSOut in [[stage_in]], texture2d<float> prev [[texture(0)]], constant WarpU& W [[buffer(0)]]) {
    float2 p = in.uv - 0.5;
    p.x *= W.aspect;
    float r = length(p);
    float a = atan2(p.y, p.x);
    a -= W.rot + W.swirl * exp(-r * 3.0);
    if (W.kaleido > 1.5) {
        float seg = 2.0 * M_PI_F / W.kaleido;
        a = fmod(a + 8.0 * M_PI_F, seg);
        a = abs(a - seg * 0.5);
    }
    r /= W.zoom;
    r += W.ripple * 0.003 * sin(r * 45.0 - W.time * 5.0);
    p = float2(cos(a), sin(a)) * r;
    p.x /= W.aspect;
    float2 uv = p + 0.5;
    float edge = step(0.0, uv.x) * step(uv.x, 1.0) * step(0.0, uv.y) * step(uv.y, 1.0);
    return prev.sample(linClamp, uv) * W.decay * edge;
}

/// Copies the media into the middle of a larger, transparent texture (premultiplied), leaving a margin for blur.
fragment float4 padFrag(FSOut in [[stage_in]], texture2d<float> src [[texture(0)]], constant float2& pad [[buffer(0)]]) {
    float2 m = (in.uv - pad) / (1.0 - 2.0 * pad);
    if (any(m < 0.0) || any(m > 1.0)) return float4(0.0);
    float4 t = src.sample(linClamp, m);
    return float4(t.rgb * t.a, t.a);
}

fragment float4 blurFrag(FSOut in [[stage_in]], texture2d<float> src [[texture(0)]], constant float2& step [[buffer(0)]]) {
    const float w[5] = { 0.227027, 0.1945946, 0.1216216, 0.054054, 0.016216 };
    float4 c = src.sample(linClamp, in.uv) * w[0];
    for (int i = 1; i < 5; i++) {
        c += src.sample(linClamp, in.uv + step * float(i)) * w[i];
        c += src.sample(linClamp, in.uv - step * float(i)) * w[i];
    }
    return c;
}

// ---- bloom: a pyramid. The scene is averaged down to ¼ size (every pixel counted, so thin lines neither flicker
// nor leave a grid pattern), halved a few more times, then added back up level by level. The result is a smooth glow
// with a tight core and a wide soft tail, for about the cost of the two blur passes it replaces.

/// ¼-size copy: each output pixel is the plain average of its 4×4 block (4 bilinear taps, each averaging 2×2).
fragment float4 box4Frag(FSOut in [[stage_in]], texture2d<float> src [[texture(0)]]) {
    float2 t = 1.0 / float2(src.get_width(), src.get_height());
    float4 c = src.sample(linClamp, in.uv + t * float2(-1.0, -1.0)) + src.sample(linClamp, in.uv + t * float2(1.0, -1.0))
             + src.sample(linClamp, in.uv + t * float2(-1.0, 1.0)) + src.sample(linClamp, in.uv + t * float2(1.0, 1.0));
    c *= 0.25;
    return select(c, float4(0.0), isnan(c) || isinf(c));
}

/// Half-size copy through a wide tent (16 bilinear taps over 8×8 source pixels): no aliasing, no shimmer.
fragment float4 bloomDownFrag(FSOut in [[stage_in]], texture2d<float> src [[texture(0)]]) {
    float2 t = 1.0 / float2(src.get_width(), src.get_height());
    const float o[4] = { -3.0, -1.0, 1.0, 3.0 };
    const float w[4] = { 0.125, 0.375, 0.375, 0.125 };
    float4 c = float4(0.0);
    for (int y = 0; y < 4; y++)
        for (int x = 0; x < 4; x++)
            c += src.sample(linClamp, in.uv + t * float2(o[x], o[y])) * (w[x] * w[y]);
    return c;
}

/// The next smaller level, enlarged through a 3×3 tent.
static float4 bloomTent(texture2d<float> low, float2 uv) {
    float2 t = 1.0 / float2(low.get_width(), low.get_height());
    float4 c = low.sample(linClamp, uv) * 4.0;
    c += (low.sample(linClamp, uv + t * float2(-1.0, 0.0)) + low.sample(linClamp, uv + t * float2(1.0, 0.0))
        + low.sample(linClamp, uv + t * float2(0.0, -1.0)) + low.sample(linClamp, uv + t * float2(0.0, 1.0))) * 2.0;
    c += low.sample(linClamp, uv + t * float2(-1.0, -1.0)) + low.sample(linClamp, uv + t * float2(1.0, -1.0))
       + low.sample(linClamp, uv + t * float2(-1.0, 1.0)) + low.sample(linClamp, uv + t * float2(1.0, 1.0));
    return c * (1.0 / 16.0);
}

/// Adds the enlarged smaller level onto this one (additive blend); `k` = how much the wider levels count.
fragment float4 bloomUpFrag(FSOut in [[stage_in]], texture2d<float> low [[texture(0)]], constant float& k [[buffer(0)]]) {
    return bloomTent(low, in.uv) * k;
}

/// Top of the pyramid: the ¼-size picture plus everything below it, into the texture the composite reads.
fragment float4 bloomTopFrag(FSOut in [[stage_in]], texture2d<float> low [[texture(0)]], texture2d<float> base [[texture(1)]],
                             constant float& k [[buffer(0)]]) {
    return base.sample(linClamp, in.uv) + bloomTent(low, in.uv) * k;
}

/// Media texture coordinates for a screen uv, honouring fill / fit / stretch. Outside the picture → alpha 0.
static float4 mediaAt(texture2d<float> tex, float2 uv, float screenAspect, constant CompU& C) {
    // user transform, in aspect-correct screen space (1 = screen height): offset, rotate, scale, kaleidoscope
    float2 p = (uv - 0.5) * float2(screenAspect, 1.0) - C.mediaXf.xy;
    float ca = cos(C.mediaXf.w), sa = sin(C.mediaXf.w);
    p = float2(ca * p.x + sa * p.y, -sa * p.x + ca * p.y) / max(C.mediaXf.z, 0.01);
    if (C.mediaKal.x >= 2.0) {
        float seg = 6.2831853 / C.mediaKal.x;
        float a = atan2(p.y, p.x) + 31.415926;
        a = fmod(a, seg);
        a = min(a, seg - a);
        p = length(p) * float2(cos(a), sin(a));
    }
    uv = p / float2(screenAspect, 1.0) + 0.5;

    float ai = C.media2.x;
    float2 s = float2(1.0);
    int fit = int(C.media.w + 0.5);
    if (fit == 0) s = screenAspect > ai ? float2(1.0, ai / screenAspect) : float2(screenAspect / ai, 1.0);
    else if (fit == 1) s = screenAspect > ai ? float2(screenAspect / ai, 1.0) : float2(1.0, ai / screenAspect);
    float2 m = (uv - 0.5) * s + 0.5;
    int tile = int(C.mediaKal.y + 0.5);
    if (tile == 1) m = fract(m);
    else if (tile == 2) m = 1.0 - abs(fract(m * 0.5) * 2.0 - 1.0);
    if (C.media2.y > 0.5) {
        // blurred copy: the picture sits inside a transparent margin, so its edges blur out too (premultiplied)
        float2 pf = C.media2.zw;
        float2 mp = pf + m * (1.0 - 2.0 * pf);
        if (tile == 0) {
            if (any(mp < 0.0) || any(mp > 1.0)) return float4(0.0);
        } else {
            mp = pf + m * (1.0 - 2.0 * pf);   // tiles stay seamless: sample inside the picture only
        }
        return tex.sample(linClamp, mp);
    }
    if (tile == 0 && (any(m < 0.0) || any(m > 1.0))) return float4(0.0);
    float4 t = tex.sample(linClamp, m);
    return float4(t.rgb, 1.0) * t.a;
}

static float luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

/// Red → yellow → green → cyan → blue → violet for t in 0…1.
static float3 spectral(float t) {
    float h = t * 0.8;
    return clamp(abs(fract(h + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
}

/// Inverse of the composite tonemap: the scene value that comes out as colour `c` on screen.
static float3 untone(float3 c) {
    float m = max(c.r, max(c.g, c.b));
    if (m < 1e-5) return c;
    return c / m * (-log(1.0 - min(m, 0.985)) / 1.3);
}

// ---------------------------------------------------------------- shader modes

/// Membrane height (z) and its gradient (xy) at sheet point p (sheet units: half the short window side, y up),
/// computed analytically in one pass over the bumps.
static float3 membraneH(float2 p, constant ShaderModeU& M, constant float* B) {
    float g0 = exp(-dot(p, p) / 0.7);
    float h = M.bass * 0.3 * g0;
    float2 grad = M.bass * 0.3 * g0 * (-2.0 * p / 0.7);
    int n = int(M.count);
    float wl = max(M.p1.x, 0.02);
    float k = 3.14159 / wl, s2 = wl * wl * 1.5;
    for (int i = 0; i < n; i++) {
        constant float* b = B + i * 6;
        float2 d = p - float2(b[0], b[1]);
        float r2 = dot(d, d);
        float rr = b[2] * b[2];
        // (terms below e^-16 of their size are left out: invisible, and most pixels are far from most bumps)
        if (r2 < 16.0 * rr) {
            float gb = b[3] * exp(-r2 / rr);
            h += gb;
            grad += gb * (-2.0 * d / rr);
        }
        if (b[5] > 1e-4) {
            float r = sqrt(r2) + 1e-5;
            float x = r - b[4];
            if (x * x > 16.0 * s2) continue;
            float env = exp(-x * x / s2);
            float c = cos(x * k), sn = sin(x * k);
            h += b[5] * c * env;
            float dr = b[5] * env * (-sn * k - c * 2.0 * x / s2);
            grad += dr * d / r;
        }
    }
    h += 0.03 * (vnoise(float3(p * 1.3, M.time * 0.12)) - 0.5) * (0.4 + M.level);
    return float3(grad, h);
}

fragment float4 membraneFrag(FSOut in [[stage_in]], constant ShaderModeU& M [[buffer(0)]], constant Uniforms& U [[buffer(1)]],
                             constant float* B [[buffer(2)]], constant CompU& C [[buffer(3)]],
                             texture2d<float> palTex [[texture(0)]], texture2d<float> mediaTex [[texture(1)]]) {
    float2 sp = camInv(in.uv * M.viewPt, U);
    if (sp.x < -1e5) return float4(0.0);
    float2 p = (sp - M.center) / M.world;
    p.y = -p.y;
    float3 hg = membraneH(p, M, B);
    float h = hg.z;
    float2 grad = hg.xy;
    if (M.p0.z > 0.001 && C.media.x >= 0.0) {
        // media relief: brightness as height, gradient by finite differences on the picture
        float aspect = M.viewPt.x / M.viewPt.y;
        const float e = 0.006;
        float2 uv = sp / M.viewPt, du = float2(e * M.world / M.viewPt.x, 0), dv = float2(0, e * M.world / M.viewPt.y);
        float k = 0.4 * M.p0.z;
        float m0 = luma(mediaAt(mediaTex, uv, aspect, C).rgb);
        float mx = luma(mediaAt(mediaTex, uv + du, aspect, C).rgb) - luma(mediaAt(mediaTex, uv - du, aspect, C).rgb);
        float my = luma(mediaAt(mediaTex, uv - dv, aspect, C).rgb) - luma(mediaAt(mediaTex, uv + dv, aspect, C).rgb);
        h += m0 * k;
        grad += float2(mx, my) / (2.0 * e) * k;
    }
    h *= M.p0.x;
    grad *= M.p0.x;
    float3 n = normalize(float3(-grad, 1.0));
    float3 L = normalize(float3(-0.55, 0.5, 0.55));
    float shade = 0.42 + 0.55 * dot(n, L);
    shade += pow(max(dot(reflect(-L, n), float3(0, 0, 1)), 0.0), 20.0) * 0.08;   // faint rubbery sheen
    shade *= 1.0 + 0.06 * (p.y - p.x) * 0.5;                                     // light falls off away from the lamp
    shade *= 1.0 + 0.1 * clamp(h, -1.0, 1.0);                                    // hollows a touch darker
    shade += (hash(in.pos.xy + fract(M.time * 3.1) * 400.0) - 0.5) * 0.035;       // fine grain of the rubber
    float3 grey = float3(0.79, 0.79, 0.8);
    float3 tint = pal(palTex, 0.5 + h * 0.8 + M.phase) * 1.05;
    float3 col = mix(grey, tint, M.p0.y) * max(shade, 0.0);
    return float4(untone(col), 1.0);
}

/// Spectral Fan: arcs on one side of the seam, beat rings on the other.
fragment float4 fanFrag(FSOut in [[stage_in]], constant ShaderModeU& M [[buffer(0)]], constant Uniforms& U [[buffer(1)]],
                        constant float* B [[buffer(2)]], texture2d<float> palTex [[texture(0)]]) {
    float2 sp = camInv(in.uv * M.viewPt, U);
    if (sp.x < -1e5) return float4(0.0);
    float2 p = (sp - M.center) / M.world;
    p.y = -p.y;
    float x = p.x * (M.p0.z > 0.5 ? -1.0 : 1.0);   // < 0: arcs, > 0: rings
    float r = length(p);
    int nb = int(M.p0.w);
    float sz = M.p1.y;
    float gr = hash(floor(in.pos.xy) + fract(M.time * 3.7) * 517.0);
    float3 col = float3(0.0);

    // dust clouds over everything
    float cloud = vnoise(float3(p * 2.2, M.time * 0.08)) * vnoise(float3(p * 5.1 + 3.7, M.time * 0.15 + 2.0));
    float speck = step(0.985 - 0.03 * min(M.level, 1.0), gr) * cloud * 2.0;
    col += pal(palTex, 0.05 + M.phase) * (speck + cloud * cloud * 0.12 * (0.3 + M.level)) ;

    if (x < 0.0) {
        float ang = atan2(p.y, -x);                                  // 0 straight out, ±π/2 up/down
        float spread = 1.0 - smoothstep(1.0, 1.5, abs(ang));
        float u = r * M.p0.x * 0.5 - M.p0.y * 4.0;                  // arc coordinate, scrolling outward
        float k = floor(u), fr = fract(u);
        float frac = clamp(r / 1.6, 0.0, 0.999);
        float lv = min(B[min(int(frac * float(nb)), nb - 1)], 1.3);
        float dash = vnoise(float3(ang * 24.0 / sz, k * 1.7, M.time * 0.5));
        float on = smoothstep(0.75 - 0.6 * min(lv, 1.0), 0.85 - 0.6 * min(lv, 1.0), dash);
        float w = 0.16 * sz;
        float line = exp(-pow((fr - 0.5) / w, 2.0));
        float t = (M.colorByFreq > 0.5 ? frac : min(lv, 1.0)) + M.phase;
        float a = line * on * (0.15 + lv) * spread * smoothstep(0.0, 0.04, r);
        col += pal(palTex, t) * a * (0.5 + 1.1 * gr) * 1.3;
        // soft glow of the whole fan
        col += pal(palTex, t) * lv * spread * 0.08 * exp(-r * 0.8);
    } else {
        int n = int(M.count);
        constant float* R = B + nb;
        float speed = M.p1.x;
        for (int i = 0; i < n; i++) {
            float age = R[i * 3], st = R[i * 3 + 1], ct = R[i * 3 + 2];
            float rr = age * speed;
            float w = (0.006 + 0.012 * age) * sz;
            float d = r - rr;
            float a = st * exp(-age / 1.4) * exp(-d * d / (w * w));
            float d2 = r - rr * 0.9;
            a += 0.4 * st * exp(-age / 1.0) * exp(-d2 * d2 / (w * w * 0.5));
            float3 rc = mix(float3(0.85, 0.88, 1.0), pal(palTex, 0.7 + ct * 0.3 + M.phase), 0.45);
            col += rc * a * (0.2 + 1.6 * gr * gr);
        }
        // faint standing rings behind
        float st = 0.5 + 0.5 * cos(r * 38.0 - M.p0.y * 10.0);
        col += pal(palTex, 0.8 + M.phase) * pow(st, 12.0) * 0.06 * (0.3 + M.level) * gr;
    }
    // the seam
    float ax = abs(x);
    float seam = exp(-pow(ax / 0.004, 2.0)) * (0.3 + 0.5 * M.level + 1.4 * M.beat) + exp(-ax / 0.05) * 0.12 * (M.level + M.beat);
    col += mix(float3(1.0, 0.95, 0.8), spectral(fract(p.y * 0.5 + 0.5)), 0.3) * seam;
    return float4(col, min(1.0, max(col.r, max(col.g, col.b))));
}

/// erf (Abramowitz–Stegun style fit, |error| < 1.3e-4).
static float glassErf(float x) {
    float x2 = x * x;
    return copysign(sqrt(1.0 - exp(-x2 * (1.2732395 + 0.147 * x2) / (1.0 + 0.147 * x2))), x);
}

/// One ring's signed distance in its own frame (l = the point relative to the ring, already rotated).
static float glassRingSD(float3 l, constant float* R, float sz) {
    float2 q2 = float2(length(l.xz) - R[3], l.y);
    if (R[15] > 0.5) {
        float2 dd = abs(q2) - float2(R[11], 0.022 * sz);
        return length(max(dd, 0.0)) + min(max(dd.x, dd.y), 0.0) - 0.01;
    }
    return length(q2) - R[7];
}

/// The off-screen (ray-marched) modes write their depth too (attachment 1 of rmTex's pass, rg16Float), carried into the
/// scene by copyFrag: inverse depth = `scale` / t for a hit at distance t along the ray (scale = the subject's distance /
/// −d.z, so 1 = the subject), weighted by the pixel's coverage like the scene pass (`sceneOut`). t = 0: no depth.
struct RmOut { float4 c [[color(0)]]; float4 d [[color(1)]]; };
static RmOut rmOut(float4 c, float t, float scale) {
    RmOut o;
    o.c = c;
    float a = clamp(c.a, 0.0, 1.0);
    o.d = t > 1e-4 ? float4(scale / t * a, a, 0.0, 0.0) : float4(0.0);
    return o;
}
/// Infinity's inverse-depth reference: a wall this far away (its units) counts as "the subject" (focus ½).
constant float INF_DOF_REF = 2.0;

/// Glass Stack: rings/discs as glowing glass shells (rendered off-screen at an adaptive resolution). Every ring only
/// adds light (no absorption), so the picture is a sum of one integral per ring along the ray: each ring is marched
/// on its own, over the stretch of the ray inside its bounding sphere, looking at nothing else. Between two samples
/// the shell's Gaussian exp(-sd²/w²) is integrated exactly for a distance that changes linearly (erf), so the steps
/// only have to follow the shape, not the thin glow (they were 0.4 w and every ring in reach was looked at each step).
fragment RmOut glassFrag(FSOut in [[stage_in]], constant ShaderModeU& M [[buffer(0)]],
                          constant float* B [[buffer(2)]], texture2d<float> palTex [[texture(0)]]) {
    float2 s = (in.uv * M.viewPt - M.center - M.pan) / M.zoom;
    float camD = M.p0.y;
    float3 o = float3(0.0, 0.0, camD);
    float3 d = normalize(float3(s.x, -s.y, 0.0) / M.world - o);
    float dz_ = camD / max(-d.z, 1e-3), tz_ = 0.0;   // depth of field: inverse depth = dz_ / t (1 = the centre)
    float3 ow = M.view0.xyz * o.x + M.view1.xyz * o.y + M.view2.xyz * o.z;
    float3 dw = normalize(M.view0.xyz * d.x + M.view1.xyz * d.y + M.view2.xyz * d.z);
    const float BR = 2.1;
    float b = dot(ow, dw), c = dot(ow, ow) - BR * BR, disc = b * b - c;
    if (disc < 0.0) return rmOut(float4(0.0), tz_, dz_);
    float sq = sqrt(disc);
    float t0 = max(-b - sq, 0.0), t1 = -b + sq;
    int n = min(int(M.count), 16);
    float sz = M.p0.z;
    float w0 = 0.016 * sz, soft = M.p0.x * 5.0;
    float wMax = w0 * (1.0 + soft * max(abs(t0 - camD), abs(t1 - camD)));
    float jit = hash(in.pos.xy + fract(M.time) * 91.0);
    float3 acc = float3(0.0);
    float tA_ = 0.0, gA_ = 0.0;   // glow-weighted distance (the glass is translucent: its depth = where the light is)
    for (int k = 0; k < n; k++) {
        constant float* R = B + k * 20;
        float3 cen = float3(R[0], R[1], R[2]);
        float3 oc = cen - ow;
        float along = dot(oc, dw);
        float rb = R[3] + max(R[7], R[11]) + 4.0 * wMax;
        float h2 = rb * rb - (dot(oc, oc) - along * along);
        if (h2 <= 0.0) continue;
        float hl = sqrt(h2);
        float ta = max(t0, along - hl), tb = min(t1, along + hl);
        if (ta >= tb) continue;
        // the ray in the ring's frame (linear in t)
        float3 r0 = float3(R[4], R[5], R[6]), r1 = float3(R[8], R[9], R[10]), r2 = float3(R[12], R[13], R[14]);
        float3 lo = float3(dot(r0, -oc), dot(r1, -oc), dot(r2, -oc)), ld = float3(dot(r0, dw), dot(r1, dw), dot(r2, dw));
        float t = ta - jit * w0;                          // dithered start: no rings of equal sample spacing
        float sd0 = glassRingSD(lo + ld * t, R, sz);
        float sum = 0.0;
        for (int i = 0; i < 64 && t < tb; i++) {
            float blur = 1.0 + soft * abs(t - camD);
            float h = min(clamp(0.6 * abs(sd0), 0.9 * w0 * blur, 0.15), tb - t + 1e-4);
            float sd1 = glassRingSD(lo + ld * (t + h), R, sz);
            float bm = 1.0 + soft * abs(t + 0.5 * h - camD);
            float iw = 1.0 / (w0 * bm);
            float a0 = sd0 * iw, a1 = sd1 * iw, da = a1 - a0;
            // ∫ exp(-sd²/w²) over the step for a linear sd: (√π/2)(erf(a1) - erf(a0)) / da; midpoint when nearly flat
            float am = 0.5 * (a0 + a1);
            float g = abs(da) < 0.25 ? exp(-am * am) : 0.88622693 * (glassErf(a1) - glassErf(a0)) / da;
            // the faint fill inside the glass: the part of the step with sd < 0
            float inside = sd0 < 0.0 ? (sd1 < 0.0 ? 1.0 : sd0 / (sd0 - sd1)) : (sd1 < 0.0 ? sd1 / (sd1 - sd0) : 0.0);
            sum += h * (g / bm + 0.03 * inside);
            tA_ += h * g / bm * (t + 0.5 * h); gA_ += h * g / bm;
            t += h; sd0 = sd1;
        }
        acc += float3(R[17], R[18], R[19]) * sum;
    }
    acc *= 6.0;
    tz_ = gA_ > 1e-6 ? tA_ / gA_ : 0.0;
    return rmOut(float4(acc, min(1.0, max(acc.r, max(acc.g, acc.b)))), tz_, dz_);
}

/// Diamond: the orbiting lights as seen in direction `d` (the stone's surroundings are otherwise dark).
static float3 diamondEnv(float3 d, constant float* Lt, int nl) {
    // a dim studio: soft brighter "ceiling", darker floor, so facets show even away from the lights
    float3 e = float3(0.05, 0.05, 0.06) * (0.35 + 0.65 * smoothstep(-0.4, 0.9, d.y));
    for (int i = 0; i < nl; i++) {
        constant float* L = Lt + i * 8;
        float c = max(dot(d, float3(L[0], L[1], L[2])), 0.0);
        e += float3(L[4], L[5], L[6]) * L[7] * (pow(c, L[3]) * 3.5 + pow(c, 4.0) * 0.18);
    }
    return e;
}

/// Ray vs convex solid (planes n·x ≤ w): entry/exit distances and the facets hit.
static float2 convexHit(float3 o, float3 d, constant float4* P, int n, thread int& inI) {
    float tn = -1e9, tf = 1e9;
    for (int i = 0; i < n; i++) {
        float dn = dot(P[i].xyz, d);
        float dist = P[i].w - dot(P[i].xyz, o);
        if (abs(dn) < 1e-7) { if (dist < 0.0) return float2(1.0, -1.0); continue; }
        float t = dist / dn;
        if (dn < 0.0) { if (t > tn) { tn = t; inI = i; } }
        else tf = min(tf, t);
    }
    return float2(tn, tf);
}

/// One wavelength through the stone: surface reflection, then refraction in and internal bounces,
/// letting light out (refracted) wherever it isn't totally internally reflected (up to 5 bounces).
/// `tIn` / `ii` = where the ray enters the stone and through which facet (from convexHit; the same for every wavelength).
static float3 diamondTrace(float3 o, float3 d, float tIn, int ii, constant float4* P, int n, constant float* Lt, int nl, float eta) {
    float r0 = (eta - 1.0) / (eta + 1.0); r0 *= r0;
    float3 p = o + d * tIn;
    float3 N = P[ii].xyz;
    float ci = clamp(-dot(d, N), 0.0, 1.0);
    float R = r0 + (1.0 - r0) * pow(1.0 - ci, 5.0);
    float3 col = diamondEnv(reflect(d, N), Lt, nl) * R;
    float3 dir = refract(d, N, 1.0 / eta);
    float w = 1.0 - R;
    for (int b = 0; b < 5; b++) {
        float tf = 1e9; int k = 0;
        for (int i = 0; i < n; i++) {
            float dn = dot(P[i].xyz, dir);
            if (dn <= 1e-6) continue;
            float t = (P[i].w - dot(P[i].xyz, p)) / dn;
            if (t > 1e-4 && t < tf) { tf = t; k = i; }
        }
        if (tf > 1e8) break;
        p += dir * tf;
        float3 Nn = P[k].xyz;
        float3 rd = refract(dir, -Nn, eta);
        if (dot(rd, rd) > 0.0) {
            float ct = clamp(dot(rd, Nn), 0.0, 1.0);
            float Rf = r0 + (1.0 - r0) * pow(1.0 - ct, 5.0);
            col += diamondEnv(rd, Lt, nl) * w * (1.0 - Rf);
            w *= Rf;
        }
        dir = reflect(dir, Nn);
        p += dir * 1e-4;
        if (w < 0.03) break;
    }
    return col;
}

fragment RmOut diamondFrag(FSOut in [[stage_in]], constant ShaderModeU& M [[buffer(0)]],
                            constant float* B [[buffer(2)]]) {
    float2 s = (in.uv * M.viewPt - M.center - M.pan) / M.zoom;
    float camD = M.p0.z;
    float3 o = float3(0.0, 0.0, camD);
    float3 d = normalize(float3(s.x, -s.y, 0.0) / M.world - o);
    float dz_ = camD / max(-d.z, 1e-3), tz_ = 0.0;   // depth of field: inverse depth = dz_ / t (1 = the centre)
    float3 ow = M.view0.xyz * o.x + M.view1.xyz * o.y + M.view2.xyz * o.z;
    float3 dw = normalize(M.view0.xyz * d.x + M.view1.xyz * d.y + M.view2.xyz * d.z);
    // bounding sphere: the stone is ~1.05 at rest; music + Movement can push, stretch and shift it to ~2
    float b = dot(ow, dw), c = dot(ow, ow) - 4.4, disc = b * b - c;
    if (disc < 0.0 || -b + sqrt(disc) < 0.0) return rmOut(float4(0.0), tz_, dz_);
    int n = int(M.count), nl = int(M.p0.x);
    constant float4* P = (constant float4*)B;
    constant float* Lt = B + n * 4;
    // Outline antialiasing: the length of the ray's path through the stone falls to zero at the silhouette, so that
    // length divided by how much it changes from one pixel to the next is the distance to the edge in pixels.
    // (Measured with two neighbouring rays; a screen-space derivative would make every pixel run the whole trace.)
    int i0 = 0, iTmp = 0;
    float2 tt0 = convexHit(ow, dw, P, n, i0);
    float thick = tt0.y - tt0.x;
    if (thick <= 0.0 || tt0.x < 0.0) return rmOut(float4(0.0), tz_, dz_);
    tz_ = tt0.x;
    float pxw = 1.0 / (M.p2.x * M.zoom * M.world);             // one target pixel on the image plane, world units
    float3 dx = normalize(float3(s.x / M.world + pxw, -s.y / M.world, 0.0) - o);
    float3 dy = normalize(float3(s.x / M.world, -s.y / M.world + pxw, 0.0) - o);
    float2 ttx = convexHit(ow, normalize(M.view0.xyz * dx.x + M.view1.xyz * dx.y + M.view2.xyz * dx.z), P, n, iTmp);
    float2 tty = convexHit(ow, normalize(M.view0.xyz * dy.x + M.view1.xyz * dy.y + M.view2.xyz * dy.z), P, n, iTmp);
    float edge = clamp(thick / max(length(float2(ttx.y - ttx.x, tty.y - tty.x) - thick), 1e-6), 0.0, 1.0);
    float fire = M.p0.y * 0.16;   // Rainbow: spread of the refractive index between red and blue
    float3 col;
    if (fire < 0.002) {
        col = diamondTrace(ow, dw, tt0.x, i0, P, n, Lt, nl, 2.417);
    } else {
        col = float3(diamondTrace(ow, dw, tt0.x, i0, P, n, Lt, nl, 2.417 - fire).r,
                     diamondTrace(ow, dw, tt0.x, i0, P, n, Lt, nl, 2.417).g,
                     diamondTrace(ow, dw, tt0.x, i0, P, n, Lt, nl, 2.417 + fire).b);
    }
    col *= edge;
    return rmOut(float4(col, min(1.0, max(col.r, max(col.g, col.b)))), tz_, dz_);
}

/// Orbs: distance to the scene, metaball style: the big sphere and the orbs are merged with a smooth minimum, so
/// orbs close to the sphere (or to each other) melt into it with a soft neck. `id` = whichever shape dominates
/// (-1 = the big sphere). Orb data, 8 floats each: centre xyz, radius, 0.5 / goo, goo (blend radius), colour t, level.
/// Only the orbs in `mask` (near the ray) are visited, in index order.
static float orbsMap(float3 p, constant float* B, int n, float R0, uint mask, thread int& id) {
    float d = R0 > 0.0 ? length(p) - R0 : 1e3;   // R0 = 0: no central sphere, just the orbs
    float best = d;
    id = -1;
    for (uint m = mask; m != 0u; m &= m - 1u) {
        int j = int(ctz(m));
        constant float* S = B + j * 8;
        float ds = length(p - float3(S[0], S[1], S[2])) - S[3];
        if (ds < best) { best = ds; id = j; }
        float k = S[5];
        float h = clamp(0.5 + (ds - d) * S[4], 0.0, 1.0);          // polynomial smooth minimum
        d = mix(ds, d, h) - k * h * (1.0 - h);
    }
    return d;
}

/// The field's exact gradient (normalised), carried through the smooth minimum: ∂smin/∂a = 1 − h, ∂smin/∂b = h. One
/// pass over the orbs instead of orbsNormal's four; used where the surface is only seen in a (blurred) reflection.
static float3 orbsGrad(float3 p, constant float* B, float R0, uint mask) {
    float d = 1e3;
    float3 g = float3(0.0, 1.0, 0.0);
    if (R0 > 0.0) { float L = length(p); d = L - R0; g = p / max(L, 1e-6); }
    for (uint m = mask; m != 0u; m &= m - 1u) {
        constant float* S = B + int(ctz(m)) * 8;
        float3 v = p - float3(S[0], S[1], S[2]);
        float L = length(v);
        float ds = L - S[3];
        float k = S[5];
        float h = clamp(0.5 + (ds - d) * S[4], 0.0, 1.0);
        g = mix(v / max(L, 1e-6), g, h);
        d = mix(ds, d, h) - k * h * (1.0 - h);
    }
    return normalize(g);
}

/// The field's gradient, carried analytically through the smooth minimum (one pass over the orbs instead of the
/// four of a finite-difference normal; the same direction up to the old 0.0015 step's error).
static float3 orbsNormal(float3 p, constant float* B, int n, float R0, uint mask) {
    const float2 k = float2(1.0, -1.0) * 0.0015;
    int id;
    return normalize(k.xyy * orbsMap(p + k.xyy, B, n, R0, mask, id) + k.yyx * orbsMap(p + k.yyx, B, n, R0, mask, id) +
                     k.yxy * orbsMap(p + k.yxy, B, n, R0, mask, id) + k.xxx * orbsMap(p + k.xxx, B, n, R0, mask, id));
}

/// Which orbs can matter along a ray: those whose reach (orb + blend radius + margin) the ray passes through.
/// `span` = the part of the ray inside any of those reach spheres (x = first entry ≥ 0, y = last exit): outside it
/// the masked field has no surface, so marches start at x and stop at y (a ray that misses ends at the last exit).
/// `skip` (≥ 0) = an orb left out of the span though kept in the mask: the one a reflected ray starts on, when it
/// leaves that sphere. The surface outside the other orbs' reach is that orb's own sphere (the blend only acts within
/// a blend radius of two orbs), and a ray outside a sphere moving away from its centre can't meet it again. So the
/// march can start where the ray first enters another orb's reach, instead of crawling away from its own surface.
static uint orbsMask(float3 o, float3 d, constant float* B, int n, thread float2& span, int skip = -1) {
    uint mask = 0u;
    span = float2(1e9, -1e9);
    for (int j = 0; j < n; j++) {
        constant float* S = B + j * 8;
        float3 oc = float3(S[0], S[1], S[2]) - o;
        float along = dot(oc, d);
        float reach = S[3] + S[5] + 0.02;
        float q = reach * reach - (dot(oc, oc) - along * along);
        if (along > -reach && q > 0.0) {
            mask |= 1u << uint(j);
            float sq = sqrt(q);
            if (along + sq > 0.0 && j != skip) span = float2(min(span.x, max(along - sq, 0.0)), max(span.y, along + sq));
        }
    }
    return mask;
}

/// The same, plus `wide` = the orbs within `reach + 0.13` of the ray (what the ambient occlusion probes can touch).
static uint orbsMask(float3 o, float3 d, constant float* B, int n, thread float2& span, thread uint& wide) {
    uint mask = 0u;
    wide = 0u;
    span = float2(1e9, -1e9);
    for (int j = 0; j < n; j++) {
        constant float* S = B + j * 8;
        float3 oc = float3(S[0], S[1], S[2]) - o;
        float along = dot(oc, d);
        float reach = S[3] + S[5] + 0.02;
        float perp2 = dot(oc, oc) - along * along;
        float q = reach * reach - perp2;
        if (along > -reach && q > 0.0) {
            mask |= 1u << uint(j);
            float sq = sqrt(q);
            if (along + sq > 0.0) span = float2(min(span.x, max(along - sq, 0.0)), max(span.y, along + sq));
        }
        float rw = reach + 0.13;
        if (along > -rw && perp2 < rw * rw) wide |= 1u << uint(j);
    }
    return mask;
}

/// Like orbsMarch for the camera ray, but a ray that only grazes a blob (passes within 1½ pixels) still returns its
/// closest point, with `cov` < 1: an antialiased silhouette. `pix` = size of a pixel per unit of distance from the
/// eye, `tBase` = the eye's distance to `o`.
static float orbsMarchAA(float3 o, float3 d, float tMax, int steps, float eps, float pix, float tBase,
                         constant float* B, int n, float R0, uint mask, thread int& id, thread float& cov) {
    float t = 0.0, best = 1e9, tBest = 0.0;
    for (int i = 0; i < steps && t < tMax; i++) {
        float h = orbsMap(o + d * t, B, n, R0, mask, id);
        float r = h / (pix * (tBase + t));
        if (r < best) { best = r; tBest = t; }
        if (h < eps) { cov = 1.0; return t; }
        t += h * 0.85;
    }
    cov = clamp(1.5 - best, 0.0, 1.0);
    return cov > 0.0 ? tBest : -1.0;
}

/// Marches from `o` along `d` until a surface or `tMax`; returns the distance (or -1).
static float orbsMarch(float3 o, float3 d, float tMax, int steps, float eps, constant float* B, int n, float R0, uint mask, thread int& id) {
    float t = 0.0;
    for (int i = 0; i < steps && t < tMax; i++) {
        float h = orbsMap(o + d * t, B, n, R0, mask, id);
        if (h < eps) return t;
        t += h * 0.85;   // the smooth blend underestimates a little: smaller steps avoid ripples in the necks
    }
    return -1.0;
}

/// Orbs: chrome metaballs, a big sphere that orbs melt into and out of (raymarched at an adaptive resolution). One
/// reflection bounce, so the blobs show up in each other; the necks between them get ambient occlusion.
fragment RmOut orbsFrag(FSOut in [[stage_in]], constant ShaderModeU& M [[buffer(0)]],
                         constant float* B [[buffer(2)]], texture2d<float> palTex [[texture(0)]],
                         texture2d<float> env [[texture(1)]]) {
    float2 s = (in.uv * M.viewPt - M.center - M.pan) / M.zoom;
    float camD = M.p0.x;
    float3 o = float3(0.0, 0.0, camD);
    float3 d = normalize(float3(s.x, -s.y, 0.0) / M.world - o);
    float dz_ = camD / max(-d.z, 1e-3), tz_ = 0.0;   // depth of field: inverse depth = dz_ / t (1 = the centre)
    float3 ow = M.view0.xyz * o.x + M.view1.xyz * o.y + M.view2.xyz * o.z;
    float3 dw = normalize(M.view0.xyz * d.x + M.view1.xyz * d.y + M.view2.xyz * d.z);
    float R0 = M.p1.x, BR = M.p1.y, tintAmt = M.p1.z;
    float b = dot(ow, dw), c = dot(ow, ow) - BR * BR, disc = b * b - c;
    if (disc < 0.0) return rmOut(float4(0.0), tz_, dz_);
    float sq = sqrt(disc);
    float t0 = max(-b - sq, 0.0), t1 = -b + sq;
    if (t1 < 0.0) return rmOut(float4(0.0), tz_, dz_);
    int n = int(M.count);
    int id;
    float pix = 1.0 / (M.p2.x * M.zoom * M.world * camD);   // world size of a target pixel, per unit of distance
    float eps = clamp(0.5 * pix * camD, 2e-4, 1.2 / M.world);  // half a pixel
    float2 span;
    uint maskAO;   // the ray's orbs plus any within the AO's reach (0.13)
    uint mask = orbsMask(ow, dw, B, n, span, maskAO);
    t0 = max(t0, span.x); t1 = min(t1, span.y);   // only where the ray's orbs can be
    if (t1 <= t0) return rmOut(float4(0.0), tz_, dz_);
    float cov;
    float t = orbsMarchAA(ow + dw * t0, dw, t1 - t0, 96, eps, pix, t0, B, n, R0, mask, id, cov);
    if (t < 0.0) return rmOut(float4(0.0), tz_, dz_);
    tz_ = t0 + t;
    float3 p = ow + dw * (t0 + t);
    if (cov < 1.0) orbsMap(p, B, n, R0, mask, id);        // grazing ray: `id` at the closest point
    float3 N = orbsNormal(p, B, n, R0, mask);
    // ambient occlusion: how much nearby geometry crowds the normal (the necks between the blobs)
    float occ = 0.0, wgt = 1.0;
    for (int i = 1; i <= 3; i++) {
        float h = 0.04 * float(i);
        int tmp;
        occ += (h - orbsMap(p + N * h, B, n, R0, maskAO, tmp)) * wgt;
        wgt *= 0.6;
    }
    float ao = clamp(1.0 - 4.0 * occ, 0.15, 1.0);
    float3 tint = id < 0 ? pal(palTex, M.p1.w) : pal(palTex, B[id * 8 + 6]);
    // world → view (rows), for the studio which is fixed to the viewer
    float3 Nv = float3(dot(M.view0.xyz, N), dot(M.view1.xyz, N), dot(M.view2.xyz, N));
    ChromeU K;
    K.turn = M.p0.z; K.blur = M.p0.w; K.tint = tintAmt; K.exposure = M.p0.y;
    if (dot(Nv, -d) < 0.0) Nv = -Nv;
    // Reflection = several rays spread over a cone (wider with Blur), each finding either another blob (shaded as
    // chrome itself) or the environment (at a blurrier mip level), averaged. So Blur softens the reflections of the
    // other blobs exactly like the environment; the per-pixel jitter makes very soft reflections slightly grainy.
    float3 Rw0 = reflect(dw, N);
    float3 T = normalize(cross(abs(Rw0.y) < 0.95 ? float3(0.0, 1.0, 0.0) : float3(1.0, 0.0, 0.0), Rw0));
    float3 Bt = cross(Rw0, T);
    int rays = K.blur < 0.01 ? 1 : (K.blur < 0.4 ? 3 : 4);
    float spread = 0.26 * K.blur;   // the mip level does most of the softening; the cone mainly blurs the other blobs
    float jit = hash(in.pos.xy + 1.3), rot = hash(in.pos.xy + 8.1) * 6.2832;
    ChromeU K2 = K;
    K2.blur = min(1.0, K.blur * 1.5);                                  // seen in a blurred mirror: softer still
    float3 o2 = p + N * (eps * 6.0);   // start clear of the surface, or the reflected ray re-hits it (rings)
    float3 refl = float3(0.0);
    for (int r = 0; r < rays; r++) {
        float rad = rays == 1 ? 0.0 : sqrt((float(r) + jit) / float(rays)) * spread;
        float a = float(r) * 2.39996 + rot;
        float3 Rw = normalize(Rw0 + (T * cos(a) + Bt * sin(a)) * rad);
        if (dot(Rw, N) < 0.0) Rw = reflect(Rw, N);
        float3 Rv = float3(dot(M.view0.xyz, Rw), dot(M.view1.xyz, Rw), dot(M.view2.xyz, Rw));
        float2 span2;
        int skip = id >= 0 && dot(Rw, p - float3(B[id * 8], B[id * 8 + 1], B[id * 8 + 2])) >= 0.0 ? id : -1;
        uint mask2 = orbsMask(p, Rw, B, n, span2, skip);
        int id2;
        float t2 = -1.0;
        if (span2.y > span2.x) {
            float ts = max(span2.x - eps * 6.0, 0.0);
            t2 = orbsMarch(o2 + Rw * ts, Rw, min(2.0 * BR, span2.y + eps * 6.0) - ts, 28, eps * 2.0, B, n, R0, mask2, id2);
            if (t2 >= 0.0) t2 += ts;
        }
        if (t2 < 0.0) {
            refl += chromeEnv(Rv, K, env, K.blur * 6.5);
        } else {
            float3 p2 = o2 + Rw * t2;
            float3 N2 = orbsGrad(p2, B, R0, mask2);
            float3 N2v = float3(dot(M.view0.xyz, N2), dot(M.view1.xyz, N2), dot(M.view2.xyz, N2));
            float3 tint2 = id2 < 0 ? pal(palTex, M.p1.w) : pal(palTex, B[id2 * 8 + 6]);
            if (dot(N2v, Rv) > 0.0) N2v = -N2v;
            // one blurrier environment sample is enough for a surface seen in a blurred mirror (cheaper than chromeShade)
            refl += chromeEnv(reflect(Rv, N2v), K2, env, K2.blur * 6.5) * chromeFresnel(N2v, -Rv, tint2, K) * 0.8;
        }
    }
    refl /= float(rays);
    return rmOut(float4(refl * chromeFresnel(Nv, -d, tint, K) * (ao * cov), cov), tz_, dz_);
}

/// Splashs: the ferrofluid height field. B = n×n cells over x, z ∈ ±1 (dish plane, y up), each
/// (height, ∂h/∂x, ∂h/∂z, ambient occlusion), bilinearly interpolated (so normals are smooth, not faceted).
static float4 ferroCell(const device float4* B, int n, float2 xz) {
    float2 g = (xz * 0.5 + 0.5) * float(n) - 0.5;   // xz already divided by the grid's extent
    float2 f = fract(g);
    int2 i = int2(floor(g));
    int2 i0 = clamp(i, 0, n - 1), i1 = clamp(i + 1, 0, n - 1);
    float4 a = B[i0.y * n + i0.x], b = B[i0.y * n + i1.x], c = B[i1.y * n + i0.x], d = B[i1.y * n + i1.x];
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

static float ferroH(const device float4* B, int n, float E, float3 p) {
    return (abs(p.x) >= E || abs(p.z) >= E) ? 0.0 : ferroCell(B, n, p.xz / E).x;
}

/// Splashs: raymarches the ferrofluid height field. Only the fluid is drawn: a black, oily mirror
/// (dielectric Fresnel, F0 ≈ 0.045) reflecting the chrome HDR environment.
fragment RmOut ferroFrag(FSOut in [[stage_in]], constant ShaderModeU& M [[buffer(0)]],
                          const device float4* B [[buffer(2)]], texture2d<float> palTex [[texture(0)]],
                          texture2d<float> env [[texture(1)]]) {
    float2 s = (in.uv * M.viewPt - M.center - M.pan) / M.zoom;
    float camD = M.p0.x;
    float3 o = float3(0.0, 0.0, camD);
    float3 d = normalize(float3(s.x, -s.y, 0.0) / M.world - o);
    float dz_ = camD / max(-d.z, 1e-3), tz_ = 0.0;   // depth of field: inverse depth = dz_ / t (1 = the centre)
    float3 ow = M.view0.xyz * o.x + M.view1.xyz * o.y + M.view2.xyz * o.z;
    float3 dw = normalize(M.view0.xyz * d.x + M.view1.xyz * d.y + M.view2.xyz * d.z);
    int n = int(M.count);
    float hTop = M.p1.x, E = M.p1.w;
    ChromeU K;
    K.turn = M.p0.z; K.blur = M.p0.w; K.tint = M.p1.y; K.exposure = M.p0.y;

    if (abs(dw.y) < 1e-5) return rmOut(float4(0.0), tz_, dz_);
    float tBot = -ow.y / dw.y;                       // the dish plane y = 0
    if (tBot < 0.0) return rmOut(float4(0.0), tz_, dz_);
    float tTop = max(0.0, (hTop - ow.y) / dw.y);
    float pix = 1.0 / (M.p2.x * M.zoom * M.world * camD);
    // march down through the slab between the highest spike and the dish
    float t = tTop, tPrev = tTop, tHit = tBot;
    for (int i = 0; i < 320 && t < tBot; i++) {
        float3 p = ow + dw * t;
        float dy = p.y - ferroH(B, n, E, p);
        if (dy < 0.0) {
            float lo = tPrev, hi = t;
            for (int k = 0; k < 7; k++) {
                float mid = 0.5 * (lo + hi);
                float3 q = ow + dw * mid;
                if (q.y - ferroH(B, n, E, q) < 0.0) hi = mid; else lo = mid;
            }
            tHit = hi;
            break;
        }
        tPrev = t;
        t += max(dy * 0.22, pix * t + 0.0008);   // spikes are steep (slope ~4): small steps
    }
    float3 p = ow + dw * tHit;
    tz_ = tHit;
    float3 V = -d;
    float4 c = (abs(p.x) < E && abs(p.z) < E) ? ferroCell(B, n, p.xz / E) : float4(0.0, 0.0, 0.0, 1.0);
    float ao = c.w;
    float3 fluidCol = float3(0.0);
    float wet = smoothstep(0.0004, 0.004, c.x);       // soft contact line instead of a jagged threshold
    if (wet > 0.0) {
        // ferrofluid: black oil, a sharp (or Blur-softened) mirror at grazing angles
        float3 N = normalize(float3(-c.y, 1.0, -c.z));   // gradients are per dish unit already
        float3 Nv = float3(dot(M.view0.xyz, N), dot(M.view1.xyz, N), dot(M.view2.xyz, N));
        if (dot(Nv, V) < 0.0) Nv = -Nv;
        float fres = 0.045 + 0.955 * pow(1.0 - clamp(dot(Nv, V), 0.0, 1.0), 5.0);
        float3 tint = pal(palTex, M.p1.z);
        float tm = max(tint.r, max(tint.g, tint.b));
        float3 tc = mix(float3(1.0), tm > 1e-4 ? tint / tm : float3(1.0), K.tint);
        float3 refl = chromeReflect(Nv, V, in.pos.xy, K, env);
        fluidCol = (float3(0.006, 0.005, 0.005) + refl * fres * tc) * mix(0.35, 1.0, ao);
    }
    // only the fluid is drawn (no dish): premultiplied, the soft contact line fades it out
    return rmOut(float4(fluidCol * wet, wet), tz_, dz_);
}

/// Real Metaballs: the ferrofluid as metaballs. `vol` is the particles' density splatted into a 3D grid over
/// x, y ∈ ±1, z ∈ ±depth/2 (p1.z); the fluid's surface is where it crosses `iso` (p1.w). Only the fluid is drawn:
/// black oil (Fresnel F0 ≈ 0.05) that mirrors the chrome HDR environment, with the palette tint and occlusion.
/// Real Metaballs: the texture is the particle fluid's density over the glass sphere's cube [-1, 1]³ (1 = inside
/// the liquid), splatted by `FerroGPU`.
/// At rest (S.x = 0…1) the density blends into a perfect sphere of radius S.y around (0, S.z, 0): the calm liquid is a flawless ball.
static float mbDensity(texture3d<float> vol, float3 p, float4 S) {
    float v = vol.sample(linClamp, p * 0.5 + 0.5).r;
    if (S.x <= 0.0) return v;
    float ball = clamp(0.5 + (S.y - length(p - float3(0.0, S.z, 0.0))) / 0.06, 0.0, 1.0);
    return mix(v, ball, S.x);
}

fragment RmOut metaballsFrag(FSOut in [[stage_in]], constant ShaderModeU& M [[buffer(0)]],
                              texture2d<float> palTex [[texture(0)]], texture2d<float> env [[texture(1)]],
                              texture3d<float> vol [[texture(2)]], device const uint* occBlk [[buffer(3)]]) {
    float2 s = (in.uv * M.viewPt - M.center - M.pan) / M.zoom;
    float camD = M.p0.x;
    float3 o = float3(0.0, 0.0, camD);
    float3 d = normalize(float3(s.x, -s.y, 0.0) / M.world - o);
    float dz_ = camD / max(-d.z, 1e-3), tz_ = 0.0;   // depth of field: inverse depth = dz_ / t (1 = the centre)
    float3 ow = M.view0.xyz * o.x + M.view1.xyz * o.y + M.view2.xyz * o.z;
    float3 dw = normalize(M.view0.xyz * d.x + M.view1.xyz * d.y + M.view2.xyz * d.z);
    float D = M.p1.z, iso = M.p1.w;
    float4 S = float4(M.p2.y, M.p2.z, M.p2.w, 0.0);   // at rest: blend into a sphere (amount, radius, centre y)
    ChromeU K;
    K.turn = M.p0.z; K.blur = M.p0.w; K.tint = M.p1.x; K.exposure = M.p0.y;

    // the glass sphere
    float bq = dot(ow, dw), cq = dot(ow, ow) - 1.0, disc = bq * bq - cq;
    if (disc <= 0.0) return rmOut(float4(0.0), tz_, dz_);
    float sq = sqrt(disc);
    float tEnter = max(0.0, -bq - sq), tExit = -bq + sq;
    if (tExit <= tEnter) return rmOut(float4(0.0), tz_, dz_);
    (void)D;

    float cell = 2.0 / float(vol.get_width());      // voxel
    float base = cell * 0.6;                        // march step (the surface is then found by bisection)
    float t = tEnter, tPrev = tEnter, dPrev = 0.0, dMax = 0.0;
    bool hit = false;
    float3 inv = 1.0 / select(dw, float3(1e-6), abs(dw) < 1e-6);
    for (int i = 0; i < 400 && t < tExit; i++) {
        float3 p = ow + dw * t;
        // empty 16³ block (no fluid anywhere in it): jump to where the ray leaves it
        int3 oc = clamp(int3(floor((p + 1.0) * 8.0)), int3(0), int3(15));
        if (occBlk[(oc.z * 16 + oc.y) * 16 + oc.x] == 0u && !(S.x > 0.0 && length(p - float3(0.0, S.z, 0.0)) < S.y + 0.15)) {
            float3 lo = float3(oc) * 0.125 - 1.0;
            float3 te = (select(lo, lo + 0.125, dw > 0.0) - ow) * inv;
            t = max(t + base * 0.25, min(te.x, min(te.y, te.z)) + 1e-4);
            tPrev = t; dPrev = 0.0;
            continue;
        }
        float dn = mbDensity(vol, p, S);
        if (dn >= iso) {
            float lo = tPrev, hi = t;
            for (int k = 0; k < 6; k++) {
                float mid = 0.5 * (lo + hi);
                if (mbDensity(vol, ow + dw * mid, S) >= iso) hi = mid; else lo = mid;
            }
            t = hi; hit = true; tz_ = t;
            break;
        }
        dMax = max(dMax, dn);
        tPrev = t; dPrev = dn;
        t += dn < 0.002 ? base * 2.5 : base;        // nothing near: bigger steps
    }
    if (!hit) {
        // a ray that just misses still gets a little coverage: soft, anti-aliased silhouettes
        float cov = smoothstep(iso * 0.55, iso, dMax);
        tz_ = 0.5 * (tEnter + tExit);
        return rmOut(float4(0.0, 0.0, 0.0, cov * 0.85), tz_, dz_);
    }
    float3 p = ow + dw * t;
    float e = cell;
    float3 g = float3(mbDensity(vol, p + float3(e, 0, 0), S) - mbDensity(vol, p - float3(e, 0, 0), S),
                      mbDensity(vol, p + float3(0, e, 0), S) - mbDensity(vol, p - float3(0, e, 0), S),
                      mbDensity(vol, p + float3(0, 0, e), S) - mbDensity(vol, p - float3(0, 0, e), S));
    float3 N = -normalize(g + float3(0.0, 0.0, 1e-7));
    // occlusion: fluid crowding the point from outside (the necks between drops, the inner side of arms)
    float occ = mbDensity(vol, p + N * 0.035, S) + 0.5 * mbDensity(vol, p + N * 0.07, S);
    float ao = clamp(1.0 - 0.9 * occ / max(iso, 1e-3), 0.3, 1.0);
    float3 Nv = float3(dot(M.view0.xyz, N), dot(M.view1.xyz, N), dot(M.view2.xyz, N));
    float3 V = -d;
    if (dot(Nv, V) < 0.0) Nv = normalize(Nv - V * (dot(Nv, V) * 1.01));
    float fres = 0.05 + 0.95 * pow(1.0 - clamp(dot(Nv, V), 0.0, 1.0), 5.0);
    float3 tint = pal(palTex, M.p1.y);
    float tm = max(tint.r, max(tint.g, tint.b));
    float3 tc = mix(float3(1.0), tm > 1e-4 ? tint / tm : float3(1.0), K.tint);
    float3 refl = chromeReflect(Nv, V, in.pos.xy, K, env);
    float3 col = (float3(0.004, 0.0035, 0.0035) + refl * fres * tc) * ao;
    return rmOut(float4(col, 1.0), tz_, dz_);
}

// ---------------------------------------------------------------- Infinity (an endless Mandelbox castle)

// Infinity's pipelines are specialised (Renderer.infinityPipe): structure, surface, speakers and the debug view are
// function constants, so each variant only holds its own code. As one shader with every structure inlined at a dozen
// call sites and every surface's loops, it held far fewer pixels in flight (it was register-bound).
constant int INF_KIND [[function_constant(0)]];      // structure: 0 Castle, 1 Vault, 2 Bubbles, 3 City
constant int INF_SURF [[function_constant(1)]];      // surface: 0 solid, 1 reflective, 2 glass, 3 milky
constant bool INF_SPK [[function_constant(2)]];      // speakers
constant int INF_DEBUG [[function_constant(3)]];     // AUDIOWATCH_INF_STEPS (0 = off)

/// Palette-coloured key and fill lights fixed to the viewer plus a Fresnel reflection of the HDR environment.
/// Everything in view space (N towards the viewer V).
static float3 infLit(float3 N, float3 V, float3 base, float gloss, float3 ca, float3 cb, ChromeU K, texture2d<float> env) {
    float3 L1 = normalize(float3(-0.55, 0.65, 0.5)), L2 = normalize(float3(0.7, -0.25, 0.4));
    float d1 = max(dot(N, L1), 0.0), d2 = max(dot(N, L2), 0.0);
    float sp = 16.0 + 150.0 * gloss;
    float s1 = pow(max(dot(N, normalize(L1 + V)), 0.0), sp), s2 = pow(max(dot(N, normalize(L2 + V)), 0.0), sp);
    float fres = pow(1.0 - clamp(dot(N, V), 0.0, 1.0), 5.0);
    float m = max(base.r, max(base.g, base.b));
    float3 tint = mix(float3(1.0), m > 1e-4 ? base / m : float3(1.0), K.tint);
    float3 refl = chromeEnv(reflect(-V, N), K, env, 1.0 + K.blur * 5.5);
    float3 col = base * (0.04 + d1 * (0.3 + 0.7 * ca) + d2 * cb * 0.8);
    col += (ca * s1 + cb * s2) * (0.25 + gloss);
    col += refl * tint * (0.03 + 0.97 * fres) * gloss;
    return col;
}

/// Speakers: loudspeaker drivers scattered through space (one, sometimes, per grid cell); where a driver's sphere
/// cuts the surface it shows as a disc: a recessed cone with a dust cap and a rolled surround, pushed out by its own
/// frequency band. Returns how far the surface is moved outwards; info = (radius 0…1 or 9 = none, band, random, level).
static float infSpeaker(float3 p, constant ShaderModeU& M, const device float* B, thread float4 &info) {
    info = float4(9.0, 0.0, 0.0, 0.0);
    float cs = 0.3;
    float3 g = floor(p / cs);
    int3 gi = int3(g);
    float hv = lattice(gi) / 0.45;
    if (hv > 1.0) return 0.0;
    // everything else about the driver comes from the same random number (this runs for every march step near a wall)
    float3 c = (fract(hv * float3(7.31, 13.77, 23.13)) - 0.5) * (0.2 * cs);
    float R = cs * (0.24 + 0.14 * hv);
    float rho = length(p - (g + 0.5) * cs - c) / R;
    if (rho >= 1.0) return 0.0;
    int nb = max(1, int(M.count));
    int band = min(nb - 1, int(fract(hv * 41.7) * float(nb)));
    float lv = B[band];
    float moving = 1.0 - smoothstep(0.72, 1.0, rho);
    float cone = -0.16 * (1.0 - smoothstep(0.26, 0.8, rho));
    float cap = 0.09 * max(0.0, 1.0 - (rho / 0.28) * (rho / 0.28));
    float sur = 0.035 * smoothstep(0.78, 0.87, rho) * smoothstep(0.98, 0.89, rho);
    info = float4(rho, float(band), hv, lv);
    return R * (cone + cap + sur + 0.1 * lv * moving);
}

static float infBox(float3 r, float2 hw, float h) {
    float3 q = abs(r - float3(0.0, 0.5 * h, 0.0)) - float3(hw.x, 0.5 * h, hw.y);
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}

/// City: towers on a street grid of lots 0.5775 wide, a street on every second lot line and an alley on the others,
/// standing on the ground at c.y = 0 and mirrored upside down above the camera's gap (a different city up there).
/// Sideways it is not mirrored: x and z come from p itself; z repeats after 256 lots, which the camera's wrap matches.
/// reach = skyline height, p0.z = how far every tower rises with its own band. trap: x = height² (floor bands),
/// y = lit windows (0 inside a window), z = the tower's random number.
static float infCity(float3 p, float cy, constant ShaderModeU& M, const device float* B, thread float3 &trap) {
    const float L = 0.5775;
    float2 g = floor(p.xz / L);
    float2 f = p.xz - (g + 0.5) * L;
    int m = int(floor(p.y / (2.0 * M.p1.x) + 0.5));          // which ground plane: every one has its own city
    int2 gi = int2(g);
    gi.y = ((gi.y % 256) + 256) % 256;
    float2 side = float2((gi.x & 1) == 0 ? 1.0 : -1.0, (gi.y & 1) == 0 ? 1.0 : -1.0);
    float hv = lattice(int3(gi.x + 7919 * m, 3, gi.y));
    float2 q = f - side * 0.0375;                              // the street side is wider than the alley side
    float2 hw = float2(0.216) - fract(hv * float2(13.7, 29.3)) * float2(0.07, 0.05);
    float tall = pow(fract(hv * 7.13), 2.4);                   // most are low, a few are towers
    int nb = max(1, int(M.count));
    int band = min(nb - 1, int(fract(hv * 41.7) * float(nb)));
    float H = 0.3 + (0.35 + 3.3 * tall) * M.reach + M.p0.z * B[band] * (0.15 + 0.5 * tall);
    H = min(H, 4.25);
    if (fract(hv * 3.71) < 0.08) H = 0.0;                      // a square
    float3 r = float3(q.x, cy, q.y);
    float db = 1e9;
    if (H > 0.0) {
        bool tower = H > 1.3;
        float h1 = tower ? H * 0.6 : H;
        db = infBox(r, hw, h1);
        if (tower) {
            db = min(db, infBox(r, hw * 0.74, H * 0.85));
            db = min(db, infBox(r, hw * 0.48, H));
            if (H > 2.8) db = min(db, infBox(r, float2(0.012), min(H + 0.3, 4.3)));   // a mast
        }
    }
    float2 e = L * 0.5 - abs(f);
    // never step past this lot (the next one may be taller) unless above the tallest tower there can be now
    float hMax = min(4.25, 0.3 + 3.65 * M.reach + M.p0.z * 0.65 * 1.2) + 0.3;
    float d = min(db, max(min(e.x, e.y) + 0.035, cy - hMax));
    d = min(d, cy - 0.12);                                     // the ground
    trap.x = cy * cy * 0.1;
    trap.z = hv;
    float wy = abs(fract(cy * 14.0) - 0.5), wx = abs(fract((q.x + q.y) * 18.0) - 0.5);
    float roof = cy < 0.14 ? 1.0 : 0.0;
    if (H > 0.0) {
        float top = H - cy, wall = min(hw.x - abs(q.x), hw.y - abs(q.y));
        if (top < wall && top < 0.03) roof = 1.0;
    }
    trap.y = roof > 0.5 ? 1.0 : max(0.0, max(wy - 0.22, wx - 0.2));
    return d;
}

/// The Mandelbox, mirrored into a lattice with half period p1.x. trap = (closest approach to the centre², closest
/// approach to an axis plane, which fold came closest 0…1): what the patterns are drawn from.
/// `lod` = how many folds are worth computing at this distance (see infLod). p2.w picks the structure:
/// 0 Castle (Mandelbox, scale p0.y > 1), 1 Vault (Mandelbox with a negative scale: a solid block, carved),
/// 2 Bubbles (sphere inversions, `reach` = their strength), 3 City (infCity). Vault and Bubbles live in a box of half
/// size 4.4 and are cut off at its faces, the City stays below 4.35, so the camera's gap is always empty.
/// `full` = also fill in the trap and speaker info (only the hit's are used: the march itself calls this with false,
/// which leaves out ~a third of the work per fold, then once more with true where it stopped).
static float infCastle(float3 p, int lod, constant ShaderModeU& M, const device float* B, thread float3 &trap, thread float4 &spk, bool full = true) {
    float S = M.p0.y, mr2 = M.p0.z, P = M.p1.x;
    int iters = min(int(M.p0.w), lod);
    const int kind = INF_KIND;
    float3 c = P - abs(P - (p - 2.0 * P * floor(p / (2.0 * P))));
    trap = float3(1e9, 1e9, 0.0);
    float d;
    if (kind <= 1) {
        float u = kind == 1 ? 2.2 : 1.0;
        float4 z = float4(c / u, 1.0), c4 = z;
        float4 sv = float4(S, S, S, abs(S)) / mr2;
        for (int i = 0; i < iters; i++) {
            z.xyz = clamp(z.xyz, -1.0, 1.0) * 2.0 - z.xyz;
            float r2 = dot(z.xyz, z.xyz);
            if (full) {
                if (r2 < trap.x) { trap.x = r2; trap.z = float(i) / M.p0.w; }
                float3 az = abs(z.xyz);
                trap.y = min(trap.y, min(az.x, min(az.y, az.z)));
            }
            z *= clamp(max(mr2 / r2, mr2), 0.0, 1.0);
            z = z * sv + c4;
        }
        d = ((length(z.xyz) - abs(S - 1.0)) / z.w - pow(abs(S), float(1 - iters))) * u;
        if (kind == 1) d = max(d, max(c.x, max(c.y, c.z)) - 4.4);
    } else if (kind == 2) {
        // Bubbles: sphere inversions in a lattice (an Apollonian packing): round shells nested in each other,
        // thickened a little so the finest ones melt into smooth curves. reach = how far each inversion reaches.
        float u = 1.4;
        float3 z = c / u;
        float sc = 1.0;
        int n = min(iters, 9);
        for (int i = 0; i < n; i++) {
            z = -1.0 + 2.0 * fract(0.5 * z + 0.5);
            float r2 = max(dot(z, z), 1e-4);
            if (full) {
                if (r2 < trap.x) { trap.x = r2; trap.z = float(i) / M.p0.w; }
                float3 az = abs(z);
                trap.y = min(trap.y, min(az.x, min(az.y, az.z)));
            }
            float k = M.reach / r2;
            z *= k; sc *= k;
        }
        d = (0.25 * abs(z.y) / sc - 0.004) * u;
        d = max(d, max(c.x, max(c.y, c.z)) - 4.4);
    } else {
        d = infCity(p, c.y, M, B, trap);
    }
    spk = float4(9.0, 0.0, 0.0, 0.0);
    if (INF_SPK) {
        if (d < 0.08) d -= infSpeaker(c, M, B, spk); else d -= 0.02;   // far away: just stay clear of the tallest cone
    }
    return d;
}

/// The distance alone (for marching).
static float infDE(float3 p, int lod, constant ShaderModeU& M, const device float* B) {
    float3 tr; float4 sp;
    return infCastle(p, lod, M, B, tr, sp, false);
}

/// Every fold shrinks the detail by the fold scale. Folds finer than a pixel at distance t only cost time and
/// shimmer (aliasing), so far-away walls are folded fewer times.
static int infLod(float pixT, constant ShaderModeU& M) {
    return clamp(int(log(5.0 / max(pixT, 1e-6)) / log(abs(M.p0.y))) + 1, 4, 14);
}

static float3 infNormal(float3 p, float e, int lod, constant ShaderModeU& M, const device float* B) {
    float2 k = float2(1.0, -1.0);
    return normalize(k.xyy * infDE(p + k.xyy * e, lod, M, B) + k.yyx * infDE(p + k.yyx * e, lod, M, B)
                   + k.yxy * infDE(p + k.yxy * e, lod, M, B) + k.xxx * infDE(p + k.xxx * e, lod, M, B));
}

/// A surface point's colour: the chosen pattern (base colour + lines that light up with a band), speakers on top,
/// lit by the two palette lights and the environment. N and the ray direction `wd` in world space. `base` = its colour.
static float3 infCastleShade(float3 N, float3 wd, float3 trap, float4 spk, float ao, float gloss, constant ShaderModeU& M,
                             const device float* B, texture2d<float> palTex, texture2d<float> env, ChromeU K,
                             float3 ca, float3 cb, thread float3 &base) {
    int pattern = int(M.p0.x);
    int nb = max(1, int(M.count));
    float tq = sqrt(trap.x);
    float fb = fract(tq * 1.7) * float(nb), line = 0.0, tcol = 0.9 * tq, dim = 1.0, wash = 0.0;
    if (pattern == 0) {            // Seams: bands of the fold, a bright seam between each two
        line = smoothstep(0.42, 0.5, abs(fract(fb) - 0.5)) + smoothstep(0.06, 0.0, abs(fract(tq * 3.4) - 0.5));
    } else if (pattern == 1) {     // Contours: fine contour lines on dark stone
        line = smoothstep(0.12, 0.0, abs(fract(tq * 14.0) - 0.5));
        dim = 0.45;
    } else if (pattern == 2) {     // Circuit: traces where the folds meet the axis planes
        fb = trap.z * float(nb);
        line = smoothstep(0.04, 0.0, trap.y);
        tcol = 0.3 + trap.z;
        dim = 0.35;
    } else if (pattern == 3) {     // Blocks: flat colour per fold depth, each depth glowing with its band
        fb = trap.z * float(nb);
        tcol = trap.z * 1.3;
        wash = 0.5;
    } else {                       // Plain: one colour, nothing drawn on it
        tcol = 0.0;
    }
    float lv = B[min(nb - 1, int(fb))];
    float tc = (M.colorByFreq > 0.5 ? tcol : lv) + M.phase;
    base = mix(pal(palTex, tc), float3(0.6), 0.25) * dim;
    float3 glow = pal(palTex, tc + 0.5) * line * (0.05 + 1.5 * lv * lv + 0.5 * M.beat) + pal(palTex, tc) * wash * lv * lv;
    if (spk.x < 1.0) {
        // a driver: graphite cone with fine rings, black surround, a metal rim in its band's colour, a glowing cap
        float3 bc = pal(palTex, (M.colorByFreq > 0.5 ? spk.y / float(max(1, nb - 1)) : spk.w) + M.phase);
        float rim = smoothstep(0.9, 0.94, spk.x);
        float cone = 0.13 + 0.05 * smoothstep(0.3, 0.5, abs(fract(spk.x * 9.0) - 0.5));
        float capM = smoothstep(0.3, 0.24, spk.x);
        base = mix(float3(spk.x > 0.78 ? 0.015 : cone), mix(bc, float3(0.8), 0.4), rim);
        glow = bc * (rim * (0.25 + 1.6 * spk.w) + capM * 0.8 * spk.w * spk.w);
        gloss = mix(0.2, 0.9, rim);
    }
    float3 Nv = float3(dot(M.view0.xyz, N), dot(M.view1.xyz, N), dot(M.view2.xyz, N));
    float3 Vv = -float3(dot(M.view0.xyz, wd), dot(M.view1.xyz, wd), dot(M.view2.xyz, wd));
    float3 c = infLit(Nv, Vv, base, gloss, ca, cb, K, env) * 1.6 + base * 0.25 * max(dot(Nv, Vv), 0.0);
    return (c + glow) * ao;
}

/// Infinity: a flight between endless Mandelbox castles, raymarched at an adaptive resolution. B = one level per
/// frequency band. p0 = pattern, fold scale, min radius², iterations; p1 = half period, surface (0 solid, 1 reflective,
/// 2 glass, 3 milky glass), speakers; view*.w = the camera's position; bass = chrome tint, p2.yz = chrome turn / blur.
constexpr sampler nearClamp(filter::nearest, address::clamp_to_edge);

/// Where a ray from the camera can start: past the empty gap the camera flies in (0.22 either side of the mirror
/// plane between two boxes, less the speakers' reach). Rays near the horizon would crawl along it for a hundred steps.
static float infStart(float3 ro, float3 rd, constant ShaderModeU& M) {
    float gy = ro.y - M.p1.x, gh = 0.18;
    return abs(gy) < gh ? max(0.02, ((rd.y > 0.0 ? gh : -gh) - gy) / max(abs(rd.y), 1e-5)) : 0.02;
}

/// Infinity's pre-pass, a quarter of the picture's size: marches one fat ray (a cone as wide as its own pixel plus
/// its neighbours') per block of pixels and writes how far it got before the castle came within the cone. Every ray
/// of the full picture inside that cone can start there, so it only does the last few steps itself.
fragment float4 infinityPreFrag(FSOut in [[stage_in]], constant ShaderModeU& M [[buffer(0)]],
                                const device float* B [[buffer(2)]]) {
    float2 s = (in.uv * M.viewPt - M.center - M.pan) / M.zoom;
    float3 dv = normalize(float3(s.x, -s.y, -M.world));
    float3 rd = normalize(M.view0.xyz * dv.x + M.view1.xyz * dv.y + M.view2.xyz * dv.z);
    float pix = 1.0 / (M.p2.x * M.zoom * M.world);        // one of this pass's (big) pixels, per unit of distance
    float3 ro = float3(M.view0.w, M.view1.w, M.view2.w);
    float sf = INF_SPK ? 0.82 : 0.9;
    float t = infStart(ro, rd, M);
    for (int i = 0; i < 64 && t < 14.0; i++) {
        float d = infDE(ro + rd * t, infLod(pix * t, M), M, B);
        if (d < pix * t * 1.5) break;                     // the castle is inside the cone now
        t += d * sf;
    }
    return float4(t, 0.0, 0.0, 1.0);
}

fragment RmOut infinityFrag(FSOut in [[stage_in]], constant ShaderModeU& M [[buffer(0)]],
                             const device float* B [[buffer(2)]], texture2d<float> palTex [[texture(0)]],
                             texture2d<float> env [[texture(1)]], texture2d<float> pre [[texture(2)]]) {
    float2 s = (in.uv * M.viewPt - M.center - M.pan) / M.zoom;
    float3 dv = normalize(float3(s.x, -s.y, -M.world));
    float dz_ = INF_DOF_REF / max(-dv.z, 1e-3), tz_ = 0.0;   // depth of field: inverse depth = dz_ / t
    float3 rd = normalize(M.view0.xyz * dv.x + M.view1.xyz * dv.y + M.view2.xyz * dv.z);
    float pix = 1.0 / (M.p2.x * M.zoom * M.world);        // a target pixel, per unit of distance
    const int surf = INF_SURF;
    ChromeU K;
    K.turn = M.p2.y; K.blur = surf == 3 ? max(M.p2.z, 0.8) : M.p2.z; K.tint = M.bass; K.exposure = 1.0;
    float3 ca = mix(float3(1.0), pal(palTex, M.phase + 0.08), 0.65), cb = pal(palTex, M.phase + 0.58);
    float3 ro = float3(M.view0.w, M.view1.w, M.view2.w);
    float sf = INF_SPK ? 0.82 : 0.9;                // the speakers' cones make the distance bound a little optimistic
    float3 trap; float4 spk;
    float t = infStart(ro, rd, M), d = 0.0;
    if (INF_DEBUG != 5) {
        // the pre-pass: the nearest of the four blocks around this pixel (minus a hair) is safe for this ray
        float4 g = pre.gather(nearClamp, in.uv);
        t = max(t, min(min(g.x, g.y), min(g.z, g.w)) * 0.99 - 0.004);
    }
    if (INF_DEBUG == 7) {
        // debug: where does the hit found from the pre-pass start differ from the one found the long way? (red = error)
        float ta = t, tb = infStart(ro, rd, M);
        for (int i = 0; i < 400 && ta < 14.0; i++) { d = infDE(ro + rd * ta, infLod(pix * ta, M), M, B); if (d < pix * ta) break; ta += d * sf; }
        for (int i = 0; i < 400 && tb < 14.0; i++) { d = infDE(ro + rd * tb, infLod(pix * tb, M), M, B); if (d < pix * tb) break; tb += d * sf; }
        float err = abs(min(ta, 14.0) - min(tb, 14.0));
        return rmOut(float4(err > 0.02 * tb ? 1.0 : 0.0, 0.15 * (1.0 - tb / 14.0), 0.0, 1.0), tz_, dz_);
    }
    if (t > 14.0) return rmOut(float4(0.0), tz_, dz_);
    bool hit = false;
    int steps = 0;
    for (int i = 0; i < 100; i++) {
        d = infDE(ro + rd * t, infLod(pix * t, M), M, B);
        if (d < pix * t) { hit = true; break; }
        t += d * sf;
        steps = i;
        if (t > 14.0) break;
    }
    if (INF_DEBUG == 1) return rmOut(float4(float3(float(steps) / 100.0, hit ? 0.3 : 0.0, t / 14.0), 1.0), tz_, dz_);   // debug: steps / hit / depth
    if (!hit) return rmOut(float4(0.0), tz_, dz_);
    tz_ = t;
    float fadeA = 1.0 - smoothstep(6.0, 14.0, t);
    float3 acc = float3(0.0);
    float trans = 1.0;                                    // how much of what lies behind still gets through
    float jit = hash(in.pos.xy + 3.7);
    int layers = surf >= 2 ? 3 : 1;
    for (int L = 0; L < layers; L++) {
        float3 p = ro + rd * t;
        float e = max(pix * t, 2e-5);
        int lod = infLod(pix * t, M);
        infCastle(p, lod, M, B, trap, spk);           // the hit's pattern and speaker (the march only looked at distances)
        float3 N = infNormal(p, e, lod, M, B);
        if (dot(N, rd) > 0.0) N = -N;
        float ao = L == 0 ? clamp(1.0 - float(steps) / 90.0, 0.0, 1.0)
                          * clamp(infDE(p + N * 0.06, lod, M, B) / 0.06, 0.2, 1.0) : 0.8;
        float fog = exp(-0.16 * t) * smoothstep(0.02, 0.12, t);
        float fres = pow(1.0 - clamp(-dot(N, rd), 0.0, 1.0), 5.0);
        float3 base;
        if (surf == 0) {
            acc = infCastleShade(N, rd, trap, spk, ao, 0.25, M, B, palTex, env, K, ca, cb, base) * fog;
            trans = 0.0;
            break;
        }
        if (surf == 1) {
            // Reflective: one more ray off the surface finds the rest of the castle (or the environment)
            float3 c = infCastleShade(N, rd, trap, spk, ao, 0.6, M, B, palTex, env, K, ca, cb, base);
            float3 R = reflect(rd, N);
            float tr = max(e * 8.0, 0.02);
            float3 trp; float4 spr;
            bool h2 = false;
            // Seen in a mirror, less detail is enough, and with Blur the mirror image is soft anyway: wider "pixels"
            // mean fewer folds and an earlier hit. A ray that hasn't arrived after 18 steps is skimming a wall.
            float pr = pix * (3.0 + 16.0 * K.blur);
            float d2 = 0.0;
            for (int i = 0; i < 18; i++) {
                d2 = infDE(p + R * tr, infLod(pr * (t + tr), M), M, B);
                if (d2 < pr * (t + tr)) { h2 = true; break; }
                tr += d2 * sf;
                if (tr > 5.0) break;
            }
            float3 rc;
            if (h2) {
                float3 p2 = p + R * tr;
                float e2 = max(pr * (t + tr), 1e-4);
                int l2 = infLod(pr * (t + tr), M);
                infCastle(p2, l2, M, B, trp, spr);
                float3 N2 = normalize(float3(infDE(p2 + float3(e2, 0.0, 0.0), l2, M, B),
                                             infDE(p2 + float3(0.0, e2, 0.0), l2, M, B),
                                             infDE(p2 + float3(0.0, 0.0, e2), l2, M, B)) - d2);
                if (dot(N2, R) > 0.0) N2 = -N2;
                float3 b2;
                rc = infCastleShade(N2, R, trp, spr, 1.0, 0.25, M, B, palTex, env, K, ca, cb, b2) * exp(-0.16 * tr) * (1.0 - smoothstep(3.0, 5.0, tr));
            } else {
                float3 Rv = float3(dot(M.view0.xyz, R), dot(M.view1.xyz, R), dot(M.view2.xyz, R));
                rc = chromeEnv(Rv, K, env, K.blur * 6.5);
            }
            float F = 0.4 + 0.6 * fres;
            float m = max(base.r, max(base.g, base.b));
            float3 tint = mix(float3(1.0), m > 1e-4 ? base / m : float3(1.0), K.tint);
            acc = (c * (0.5 * (1.0 - F)) + rc * tint * (1.3 * F) * ao) * fog;
            trans = 0.0;
            break;
        }
        // Glass / milky glass: this surface covers part of what is behind it, then the ray goes on through the solid
        float3 c = infCastleShade(N, rd, trap, spk, ao, surf == 2 ? 0.7 : 0.15, M, B, palTex, env, K, ca, cb, base);
        float a = spk.x < 1.0 ? 0.9 : (surf == 2 ? 0.2 + 0.7 * fres : 0.3 + 0.5 * fres);
        acc += c * (trans * a * fog);
        trans *= 1.0 - a;
        float ts = max(e * 4.0, 0.012), thick = 0.0;
        t += ts * (surf == 3 ? 1.0 + 2.0 * jit : 1.0);   // milky: a little noise in the depth softens what shows through
        bool outside = false;
        for (int i = 0; i < 10; i++) {
            d = infDE(ro + rd * t, lod, M, B);
            if (d > e * 2.0) { outside = true; break; }
            float st = max(abs(d), ts * 1.5);
            t += st; thick += st;
        }
        if (surf == 3) {
            // the solid is cloudy: the thicker it is, the more of its own (lit, whitened) colour and the less see-through
            float sc = 1.0 - exp(-thick * 10.0);
            float3 Nv = float3(dot(M.view0.xyz, N), dot(M.view1.xyz, N), dot(M.view2.xyz, N));
            float3 milk = mix(float3(0.85), base, 0.45) * (0.3 + 0.7 * ca * max(Nv.z, 0.0) + 0.4 * cb * max(-Nv.x, 0.0));
            acc += milk * (trans * sc * fog * ao);
            trans *= 1.0 - sc;
        } else {
            trans *= exp(-thick * 1.2);
        }
        if (!outside || trans < 0.04) { trans = 0.0; break; }   // too thick to see through
        hit = false;
        for (int i = 0; i < 40; i++) {
            d = infDE(ro + rd * t, infLod(pix * t, M), M, B);
            if (d < pix * t) { hit = true; break; }
            t += d * sf;
            if (t > 14.0) break;
        }
        if (!hit) break;                                  // open sky behind: the background shows through
        if (L == layers - 1) trans = 0.0;
    }
    return rmOut(float4(acc * fadeA, (1.0 - trans) * fadeA), tz_, dz_);
}

/// Adds the off-screen raymarched picture to the scene. It is usually smaller than the window, so it is enlarged
/// with a Catmull-Rom (bicubic) filter, 9 bilinear taps: much crisper than plain bilinear, and exact at 1:1.
/// Also carries the source's depth (texture 1, rg16Float as the scene pass writes it; a blank texture = no depth) into the
/// scene's depth attachment, enlarged bilinearly.
fragment SceneOut copyFrag(FSOut in [[stage_in]], texture2d<float> src [[texture(0)]], texture2d<float> depthSrc [[texture(1)]]) {
    float2 size = float2(src.get_width(), src.get_height());
    float2 sp = in.uv * size;
    float2 tc = floor(sp - 0.5) + 0.5;
    float2 f = sp - tc;
    float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    float2 w3 = f * f * (-0.5 + 0.5 * f);
    float2 w12 = w1 + w2;
    float2 t0 = (tc - 1.0) / size, t3 = (tc + 2.0) / size, t12 = (tc + w2 / w12) / size;
    float4 c = src.sample(linClamp, float2(t0.x, t0.y)) * (w0.x * w0.y) + src.sample(linClamp, float2(t12.x, t0.y)) * (w12.x * w0.y)
             + src.sample(linClamp, float2(t3.x, t0.y)) * (w3.x * w0.y)
             + src.sample(linClamp, float2(t0.x, t12.y)) * (w0.x * w12.y) + src.sample(linClamp, float2(t12.x, t12.y)) * (w12.x * w12.y)
             + src.sample(linClamp, float2(t3.x, t12.y)) * (w3.x * w12.y)
             + src.sample(linClamp, float2(t0.x, t3.y)) * (w0.x * w3.y) + src.sample(linClamp, float2(t12.x, t3.y)) * (w12.x * w3.y)
             + src.sample(linClamp, float2(t3.x, t3.y)) * (w3.x * w3.y);
    SceneOut o;
    o.c = max(c, 0.0);   // the filter's negative lobes must not darken what's underneath
    o.d = depthSrc.sample(linClamp, in.uv);
    return o;
}

// ---------------------------------------------------------------- distort (post-processing)
// Organic displacement of the finished picture. p and the returned offset are in screen heights.

static float2 dGrad(float2 i) {
    float h = fract(sin(dot(i, float2(127.1, 311.7))) * 43758.5453) * 6.2831853;
    return float2(cos(h), sin(h));
}
/// Gradient noise, about −0.7…0.7.
static float dNoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float a = dot(dGrad(i), f), b = dot(dGrad(i + float2(1, 0)), f - float2(1, 0));
    float c = dot(dGrad(i + float2(0, 1)), f - float2(0, 1)), d = dot(dGrad(i + float2(1, 1)), f - float2(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}
static float dFbm(float2 p, int oct) {
    float v = 0.0, a = 0.5;
    for (int k = 0; k < oct; k++) {
        v += a * dNoise(p);
        p = float2x2(1.6, 1.2, -1.2, 1.6) * p;   // rotate + scale: no axis-aligned artefacts
        a *= 0.5;
    }
    return v;
}
/// Curl of a noise potential: divergence-free, so it swirls instead of bunching up.
static float2 dCurl(float2 p, float t) {
    const float e = 0.02;
    float2 q = p + float2(0.0, t * 0.05);
    float nx = dFbm(q + float2(0, e), 3) - dFbm(q - float2(0, e), 3);
    float ny = dFbm(q + float2(e, 0), 3) - dFbm(q - float2(e, 0), 3);
    return float2(nx, -ny) / (2.0 * e);
}

static float2 distortOffset(float2 p, float aspect, constant CompU& C) {
    int style = int(C.dist.x + 0.5);
    float amt = C.dist.y * (1.0 + 0.6 * C.dist.w);   // the beat pushes it
    float t = C.dist.z;
    switch (style) {
        case 1: {   // Liquid: iq's domain warping, two levels
            float2 q = p * 1.1;
            float2 a = float2(dFbm(q + t * 0.11, 3), dFbm(q + float2(5.2, 1.3) - t * 0.09, 3));
            float2 b = float2(dFbm(q + 2.2 * a + float2(1.7, 9.2) + t * 0.07, 3), dFbm(q + 2.2 * a + float2(8.3, 2.8) - t * 0.05, 3));
            return b * amt * 0.3;
        }
        case 2: {   // Water ripples: rings from drifting sources (analytic gradient of the height field)
            float2 g = float2(0.0);
            for (int k = 0; k < 5; k++) {
                float fk = float(k);
                float2 c = float2(aspect * 0.5, 0.5) + float2(sin(t * 0.13 + fk * 2.1) * aspect * 0.42, cos(t * 0.11 + fk * 1.7) * 0.42);
                float2 d = p - c;
                float r = length(d) + 1e-4;
                float k1 = 34.0 + 9.0 * fk;
                float fall = exp(-r * 2.2) / (1.0 + r * 6.0) * smoothstep(0.0, 0.08, r);   // calm right at the source
                g += (d / r) * cos(r * k1 - t * (3.2 + 0.4 * fk)) * fall;
            }
            g += float2(dNoise(p * 9.0 + t * 0.3), dNoise(p * 9.0 + float2(4.1, 7.3) - t * 0.3)) * 0.15;   // a little chop
            return g * amt * 0.09;
        }
        case 3: {   // Heat haze: fine rising shimmer, stronger lower down (p.y grows downward)
            float2 q = float2(p.x * 7.0, p.y * 3.5 + t * 1.6);
            float n = dNoise(q) + 0.5 * dNoise(q * 2.3 + float2(3.1, t * 1.1));
            float m = dNoise(float2(p.x * 3.0, p.y * 6.0 + t * 1.2));
            float w = mix(0.35, 1.0, smoothstep(0.0, 1.0, p.y));
            return float2(n, m * 0.5) * amt * 0.045 * w;
        }
        case 4: {   // Melt: the picture slides down in uneven drips, anchored at the top
            float x = p.x;
            float drip = dNoise(float2(x * 2.2, t * 0.06)) + 0.6 * dNoise(float2(x * 5.5 + 7.0, t * 0.09 + 3.0));
            drip = pow(max(drip + 0.3, 0.0), 1.5);                   // smooth, rounded drips (sag where it's positive)
            float sag = smoothstep(-0.5, 1.0, p.y);                  // the top barely moves, the bottom hangs furthest
            float wob = dNoise(float2(x * 2.5 + 1.7, p.y * 3.0 - t * 0.3));
            return float2(wob * 0.12, -(drip * 1.3 + 0.06)) * amt * 0.45 * sag;
        }
        case 5: {   // Bubble glass: animated Voronoi cells, each a dome lens (no jump at the seams)
            float2 q = p * 5.0;
            float2 i = floor(q), f = fract(q);
            float d1 = 8.0, d2 = 8.0;
            float2 c1 = float2(0.0);
            for (int y = -1; y <= 1; y++)
                for (int x = -1; x <= 1; x++) {
                    float2 o = float2(x, y);
                    float2 h = float2(fract(sin(dot(i + o, float2(127.1, 311.7))) * 43758.5453),
                                      fract(sin(dot(i + o, float2(269.5, 183.3))) * 43758.5453));
                    float2 pt = o + 0.5 + 0.38 * sin(t * 0.35 + 6.2831853 * h);
                    float dd = length(pt - f);
                    if (dd < d1) { d2 = d1; d1 = dd; c1 = pt; } else if (dd < d2) { d2 = dd; }
                }
            float edge = smoothstep(0.0, 0.25, d2 - d1);           // 0 on a seam
            float2 v = (f - c1);                                    // from the cell's centre
            return -v * edge * amt * 0.18;   // v is in cells (1/5 screen height): magnifies each cell up to ~×10 at 1
        }
        case 6: {   // Eddies: follow a curl-noise current for a few steps
            float2 q = p * 1.6;
            float2 o = float2(0.0);
            float step = amt * 0.035;
            for (int k = 0; k < 4; k++) o += dCurl(q + o * 1.6, t) * step;
            return o;
        }
        default: return float2(0.0);
    }
}

static float dHash(float2 i) { return fract(sin(dot(i, float2(127.1, 311.7))) * 43758.5453); }

/// Rain: keep the strongest drop covering this pixel (static or sliding). d = from the drop's centre, r = radius, both in the same units.
static void dDrop(float2 d, float r, float present, thread float &bestM, thread float2 &bestD, thread float &bestR) {
    float m = smoothstep(r, r * 0.8, length(d)) * present;
    if (m > bestM) { bestM = m; bestD = d; bestR = r; }
}

/// rg = offset (screen heights), b = light added, a = brightness multiplier.
static float4 distortField(float2 p0, float aspect, constant CompU& C) {
    int style = int(C.dist.x + 0.5);
    float amt = C.dist.y * (1.0 + 0.6 * C.dist.w);   // the beat pushes it
    float t = C.dist.z;
    float sc = C.dist2.x;
    float2 mid = float2(aspect * 0.5, 0.5);
    float2 p = (p0 - mid) / sc + mid;                  // Scale: bigger features around the middle of the screen
    switch (style) {
        case 8: {   // Rain on glass (own take on the effect; see Codrops' "Rain & Water Effect Experiments")
            float bestM = 0.0, bestR = 1.0;
            float2 bestD = float2(0.0);
            // Scale maps lower than the other styles (slider 1 = 0.15 of the old size, 0.25…4 → near-pixel drops … 0.6× the
            // old default); drops are laid out in p0 so the lens offset (× cell) shrinks with them.
            float cell = 0.11 * 0.15 * sc;
            // resting drops, appearing and drying up: only a few (most drops run, below)
            {
                float2 q = p0 / cell;
                float2 i = floor(q), f = fract(q);
                float2 c = 0.3 + 0.4 * float2(dHash(i), dHash(i + 17.0));
                float r = 0.14 + 0.24 * dHash(i + 7.0);
                float life = fract(t * 0.04 * (0.6 + dHash(i + 3.0)) + dHash(i + 5.0));
                float present = smoothstep(0.0, 0.06, life) * smoothstep(1.0, 0.7, life) * step(dHash(i + 11.0), 0.12);
                dDrop((f - c) * float2(1.0, 1.0), r, present, bestM, bestD, bestR);
                // a second, smaller layer for density
                float2 q2 = p0 / (cell * 0.45) + 3.7;
                float2 i2 = floor(q2), f2 = fract(q2);
                float2 c2 = 0.3 + 0.4 * float2(dHash(i2 + 2.0), dHash(i2 + 9.0));
                float life2 = fract(t * 0.07 + dHash(i2 + 1.0));
                float pr2 = smoothstep(0.0, 0.1, life2) * smoothstep(1.0, 0.6, life2) * step(dHash(i2 + 4.0), 0.08);
                dDrop((f2 - c2) * 0.45, 0.07 + 0.08 * dHash(i2), pr2, bestM, bestD, bestR);
            }
            // running drops: 4 layers of columns (different widths and offsets), one drop per column and layer, sliding
            // down in fits and starts and leaving a trail of droplets. Most drops on the glass are these.
            for (int L = 0; L < 4; L++) {
                float fl = float(L);
                float colW = cell * (2.0 + 0.7 * fl);
                float xs = p0.x / colW + fl * 0.37;
                float col = floor(xs);
                float fx = fract(xs);
                float hs = dHash(float2(col, 1.0 + fl * 13.0));
                float hr = dHash(float2(col, 2.0 + fl * 13.0));
                float run = t * (0.12 + 0.2 * hs) + hs * 7.0 + fl * 0.31;
                float stopGo = run + 0.25 * sin(run * 6.2831853 * 2.0) / 6.2831853;   // speeds up and slows down
                float y = (fract(stopGo) * 1.5 - 0.25) / colW;                           // in column units, falls down
                float qy = p0.y / colW;
                float cx = 0.5 + 0.25 * sin(qy * 2.3 + hs * 20.0) * 0.4 + (hs - 0.5) * 0.3;
                float present = step(0.15, hs);
                float rad = 0.28 + 0.2 * hr;
                float2 d = float2(fx - cx, (qy - y) * 0.75);
                dDrop(d * colW / cell, rad, present, bestM, bestD, bestR);
                float behind = y - qy;   // > 0 above the drop
                if (behind > 0.0 && behind < 1.6) {
                    float k = 7.0;
                    float fy = fract(qy * k) - 0.5;
                    float tr = 0.16 * (1.0 - behind / 1.6) * step(0.3, dHash(float2(col + fl * 101.0, floor(qy * k))));
                    dDrop(float2(fx - cx, fy / k) * colW / cell, tr, present, bestM, bestD, bestR);
                }
            }
            if (bestM <= 0.0) return float4(0, 0, 0, 1);
            // a drop is a strong lens: it shows the picture flipped and shrunk around its centre
            float2 off = -bestD * (1.0 + 2.0 * amt) * cell * bestM;
            float rr = length(bestD) / bestR;
            float rim = mix(1.0, 0.55, smoothstep(0.55, 1.0, rr) * bestM);
            float2 hp = bestD / bestR - float2(-0.35, -0.4);
            float hl = exp(-dot(hp, hp) / 0.03) * 0.7 * bestM;
            return float4(off, hl, rim);
        }
        case 9: {   // Gravity lens: drifting point masses; source position β = θ − θE²·θ/|θ|² (thin-lens equation)
            float2 off = float2(0.0);
            float mul = 1.0, add = 0.0;
            for (int k = 0; k < 3; k++) {
                float fk = float(k);
                float2 c = mid + float2(sin(t * 0.07 + fk * 2.4) * aspect * 0.36, sin(t * 0.09 * (1.0 + 0.3 * fk) + fk * 1.3) * 0.34);
                float2 d = p0 - c;   // unscaled: Scale is the size of the holes
                float r2 = dot(d, d) + 1e-6;
                float tE = (0.05 + 0.03 * fk) * sc * (0.3 + 0.9 * amt);
                off += -d * (tE * tE) / r2;
                float r = sqrt(r2), rs = tE * 0.45;
                mul *= smoothstep(rs * 0.9, rs * 1.05, r);                            // the black hole itself
                add += exp(-pow((r - rs * 1.12) / (rs * 0.08), 2.0)) * 0.35;           // thin photon ring
            }
            float l = length(off), lim = 0.6;
            if (l > lim) off *= lim / l;   // keep the far side of the screen within reach
            return float4(off, add, mul);
        }
        default: return float4(distortOffset(p, aspect, C) * sqrt(sc), 0.0, 1.0);   // the pattern grows with Scale, its push a little
    }
}

/// The displacement field at ¼ size (rg = offset in screen heights, b = added light, a = multiplier); smooth, so the
/// composite samples it bilinearly.
fragment float4 distortFrag(FSOut in [[stage_in]], constant CompU& C [[buffer(0)]], constant float2& tsz [[buffer(1)]]) {
    return distortField(in.pos.xy / tsz.y, tsz.x / tsz.y, C);
}

// ---- depth of field (Camera group). Screen space: the lens focuses on the middle of the picture and the circle of
// confusion grows towards the edges (most modes have no per-pixel depth). The scene is halved into a mipmapped copy,
// gathered there through a bokeh-shaped kernel, then blended back over the sharp full-size scene by the local blur.

struct DofU {
    float4 a;   // Centre: max blur radius (full-size px); Depth: blur px per unit of inverse depth. Bokeh shape, blur noise, time
    float4 b;   // full-size width, height, pixels per point, Depth: 1 = empty pixels are infinitely far (3D modes)
    float4 c;   // this gather pass: blur radii it covers (full-size px) x = from, y = to; Depth: z = focus (inverse depth), w = max radius
    float4 e;   // x = Depth gather: taps per half-size px of reach (2.4 half size, 1.2 quarter size); y = Range (sharp zone, 0…1)
};

// The gather runs twice over the same mip chain: half size for small blurs (near the focus zone) and quarter size for
// big ones (a quarter of the pixels, half the taps each); the combine blends the two by the blur radius there.
constant float DOF_SPLIT_A = 22.0, DOF_SPLIT_B = 36.0;
constant int DOF_DEPTH_TAPS = 64;   // Depth gather: most taps per pixel
constant float DOF_SPLIT_C = 70.0, DOF_SPLIT_D = 90.0;   // Depth: quarter-size pass below D, eighth-size above C   // full-size px: half-size pass below B, quarter-size above A

/// Blur radius (full-size pixels) at uv: 0 in the middle, rising faster towards the edges and corners.
static float dofCoc(float2 uv, constant DofU& D) {
    float2 q = (uv - 0.5) * float2(D.b.x / D.b.y, 1.0) * 2.0;
    float r = D.e.y;   // Range: the sharp disc grows (0.22 → 1.17 half-heights), the ramp to the edges steepens so they still blur
    float d = min(max(length(q) - (0.22 + 0.95 * r), 0.0) / (1.45 - 0.6 * r), 1.3);
    return D.a.x * d * sqrt(d);
}

#ifdef DOF_TEST
/// Debug (AUDIOWATCH_SHADER_DEFS=DOF_TEST): the scene replaced by sparse bright dots, to judge the bokeh shapes.
static float4 dofTestScene(float2 px) {
    float2 cell = floor(px / 150.0), f = px - (cell + 0.5) * 150.0;
    float h = hashU(int2(cell), 7u);
    float r = 1.5 + 3.0 * h;
    float a = clamp(r - length(f), 0.0, 1.0) * (0.6 + 3.0 * hashU(int2(cell), 9u));
    float3 col = 0.5 + 0.5 * cos(6.2831853 * (h + float3(0.0, 0.33, 0.67)));
    return float4(col * a, a);
}
#endif

/// Trilinear: the gather reads between mip levels (linClamp has no mip filter, so it would ignore `level`).
constexpr sampler dofMip(filter::linear, mip_filter::linear, address::clamp_to_edge);

/// Half-size copy of the scene (each pixel = its 2×2 block); the mip chain is built after it.
fragment float4 dofDownFrag(FSOut in [[stage_in]], texture2d<float> src [[texture(0)]]) {
    float4 c = src.sample(linClamp, in.uv);
#ifdef DOF_TEST
    float2 fp = in.pos.xy * 2.0;
    c = 0.25 * (dofTestScene(fp) + dofTestScene(fp + float2(1, 0)) + dofTestScene(fp + float2(0, 1)) + dofTestScene(fp + 1.0));
#endif
    return select(c, float4(0.0), isnan(c) || isinf(c));
}

/// The blurred picture at half size: a gather of the mipmapped half-size scene through the bokeh kernel, a Vogel
/// spiral (golden-angle steps, radius √t: evenly filled disc) bent into the aperture's shape. Taps read a mip level a
/// bit wider than the gap between them, so small bright dots cover the whole disc instead of showing the taps.
/// Taps far brighter than the disc's average weigh more, so highlights open into visible shapes.
/// Shapes: 0 circle, 1 soap bubble (bright rim), 2 hexagon, 3 pentagon, 4 cat's eye, 5 anamorphic, 6 mirror ring.
fragment float4 dofGatherFrag(FSOut in [[stage_in]], texture2d<float> src [[texture(0)]], constant DofU& D [[buffer(0)]]) {
    float2 hs = float2(src.get_width(), src.get_height());
    float cocFull = dofCoc(in.uv, D);
    if (cocFull < D.c.x || cocFull > D.c.y) return float4(0.0);   // the other pass covers this pixel
    float coc = cocFull * hs.y / D.b.y;   // half-size pixels (the mip chain's level 0)
    float4 c0 = src.sample(linClamp, in.uv, level(0.0));
    if (coc < 0.5) return c0;
    int shape = int(D.a.y + 0.5);
    float noise = D.a.z;
    // taps ∝ the blur radius (the quarter-size pass keeps the count: fewer taps = toothed disc edges, dimmer highlights)
    int n = clamp(int(8.0 + coc * 2.4), 8, 128);
    // each tap reads a mip level a bit wider than the gap between taps (else the taps show as lumps inside the disc);
    // blur noise reads finer levels: the gaps show as grain
    float lod = max(log2(coc * sqrt(3.14159 / float(n))) + 0.9 - 1.2 * noise, 0.0);
    // the disc's average brightness (one read of a mip level as wide as the disc): taps far brighter than it are
    // isolated highlights and get most of the weight, so they open into a visible shape instead of fading to nothing
    float mean = luma(src.sample(dofMip, in.uv, level(log2(coc * 1.6))).rgb) + 1e-4;
    // the spiral turned per pixel (a hash, fixed in time): its outer taps would otherwise give every disc a toothed
    // edge (interleaved gradient noise showed as diagonal hatching in bright discs). Blur noise turns it anew every frame.
    float rot = hashU(int2(in.pos.xy), 0x5bd1e995u) * 6.2831853;
    if (noise > 0.0) rot += hashU(int2(in.pos.xy), uint(D.a.w * 120.0)) * 6.2831853 * min(1.0, noise * 4.0);
    // aperture blades: a tap's radius is scaled by apothem / cos(its angle from the middle of its blade's edge)
    int blades = shape == 2 ? 6 : shape == 3 ? 5 : 0;
    float seg = 6.2831853 / float(max(blades, 1)), apothem = cos(0.5 * seg);
    float ang = rot + 0.35 + 64.0 * 6.2831853;   // blades turned a bit (fixed, whatever `rot` is)
    // cat's eye: the disc cut by a second one offset along the radius (both offset by ± half: symmetric lemon)
    float2 q = (in.uv - 0.5) * float2(hs.x / hs.y, 1.0);
    float2 radial = shape == 4 ? normalize(q + 1e-5) * 0.55 * smoothstep(0.1, 0.9, length(q)) : float2(0.0);
    float2 px = coc / hs;
    const float2 golden = float2(cos(2.39996323), sin(2.39996323));
    float2 dir = float2(cos(rot), sin(rot));
    float invN = 1.0 / float(n);
    float4 acc = float4(0.0), plain = float4(0.0);
    float wsum = 0.0, psum = 0.0;
    for (int i = 0; i < n; i++, dir = float2(dir.x * golden.x - dir.y * golden.y, dir.x * golden.y + dir.y * golden.x), ang += 2.39996323) {
        float t = (float(i) + 0.5) * invN;
        float r = shape == 6 ? sqrt(0.4 + 0.6 * t) : sqrt(t);   // mirror ring: a hollow disc
        float2 o = dir * r;
        float g = 1.0;   // light the tap carries: bright rims (scales the value, not the weight, or a lone highlight
                         // would normalise it away; averages ~1 over the disc so plain areas keep their brightness)
        if (shape == 1) g = 0.35 + 1.3 * r * r;   // soap bubble: brighter towards the rim (r⁴ showed the outer taps as teeth)
        else if (shape == 6) g = 0.45 + 0.8 * r * r;
        else if (blades > 0) o *= apothem / cos(ang - seg * floor(ang / seg) - 0.5 * seg); else if (shape == 5) o.x *= 0.5;                      // anamorphic: tall ovals
        else if (shape == 4 && (length_squared(o - radial) > 1.0 || length_squared(o + radial) > 1.0)) continue;
        float4 s = src.sample(dofMip, in.uv + o * px, level(lod)) * g;
        plain += s;
        psum += 1.0;
        float h = max(luma(s.rgb) / mean - 1.5, 0.0);
        float w = 1.0 + 2.0 * h * h;
        acc += s * w;
        wsum += w;
    }
    if (wsum <= 0.0) return c0;
    // highlights' share lifted (the wide taps dilute a small bright dot)
    plain /= psum;
    return max(plain + (acc / wsum - plain) * (2.5 - 1.2 * noise), 0.0);
}

/// Full size: the sharp scene where the blur is under a pixel, the half-size bokeh pass elsewhere, then blur noise
/// (grain multiplied by the light, so black stays black) in proportion to how blurred each pixel is.
fragment float4 dofCombineFrag(FSOut in [[stage_in]], texture2d<float> sharp [[texture(0)]],
                               texture2d<float> blurred [[texture(1)]], texture2d<float> blurredQ [[texture(2)]],
                               constant DofU& D [[buffer(0)]]) {
    float2 px = in.pos.xy;
    float4 c = sharp.read(uint2(px));
#ifdef DOF_TEST
    c = dofTestScene(px);
#endif
    float coc = dofCoc(in.uv, D);
    float t = smoothstep(0.6, 2.5, coc);
    if (t > 0.0) {
        // enlarged through a small tent that widens with the blur: smooths the taps' leftover pattern (fine stripes,
        // toothed disc edges) without softening the near-focus zone
        float q = smoothstep(DOF_SPLIT_A, DOF_SPLIT_B, coc);
        // the gather's per-pixel spiral turn leaves a fringe about one tap gap wide on disc edges: the tent is that wide
        float cocH = coc * 0.5;
        float gap = cocH * sqrt(3.14159 / float(clamp(int(8.0 + cocH * 2.4), 8, 128)));   // half-size px, as in the gather
        float2 e = max(0.55 * gap, 0.6) / float2(blurred.get_width(), blurred.get_height());
        float4 b = float4(0.0);
        if (q < 1.0)
            b = 0.25 * (blurred.sample(linClamp, in.uv + float2(e.x, e.y * 0.35)) + blurred.sample(linClamp, in.uv - float2(e.x, e.y * 0.35))
                      + blurred.sample(linClamp, in.uv + float2(-e.x * 0.35, e.y)) + blurred.sample(linClamp, in.uv + float2(e.x * 0.35, -e.y)));
        if (q > 0.0) {
            float4 bq = 0.25 * (blurredQ.sample(linClamp, in.uv + float2(e.x, e.y * 0.35)) + blurredQ.sample(linClamp, in.uv - float2(e.x, e.y * 0.35))
                              + blurredQ.sample(linClamp, in.uv + float2(-e.x * 0.35, e.y)) + blurredQ.sample(linClamp, in.uv + float2(e.x * 0.35, -e.y)));
            b = mix(b, bq, q);
        }
        c = mix(c, b, t);
    }
    if (D.a.z > 0.0 && coc > 0.6) {
        float b = min(coc / (0.05 * D.b.y), 1.5);
        uint seed = uint(D.a.w * 120.0) ^ 0x6d2b79f5u;
        // fixed cell size (a size varying with the blur made floor(px / cell) run in streaks away from the corner)
        float g = grainAt(int2(floor(px / max(1.0, D.b.z * 0.9))), seed);
        c.rgb *= max(1.0 + g * D.a.z * b * 0.9, 0.0);
    }
    return select(c, float4(0.0), isnan(c) || isinf(c));
}


// ---- depth of field, Depth focus: real depth. The scene pass wrote inverse depth (1 = the subject / orbit centre,
// 0 = infinity) × coverage and the coverage into an rg16Float target; flat modes write none and use their scene plane
// (tilted by the orbit). Blur radius = (blur px per unit) × (inverse depth − the focus's), signed: > 0 = nearer than the
// focus. Passes: dofPrepFrag (half size: light + signed radius) → mips → dofTileFrag (max radius of the lit pixels per
// 16 px tile) → dofDilateFrag (× 2: how far blur can reach into each tile) → dofDepthGatherFrag (half / quarter size,
// scatter-as-gather) → dofDepthCombineFrag.

/// A flat mode's scene plane (tilted by the orbit): inverse depth at window point sPt (1 = its centre; 0 = above the horizon).
static float planeW(float2 sPt, constant Uniforms& U) {
    float2 q = (sPt - U.center - U.pan) / U.zoom;
    q.y = -q.y;
    float3 c0 = float3(U.cam0.x, U.cam1.x, U.cam2.x), c1 = float3(U.cam0.y, U.cam1.y, U.cam2.y);
    float P = U.persp;
    float a = c0.x * P + q.x * c0.z, b = c1.x * P + q.x * c1.z;
    float c = c0.y * P + q.y * c0.z, d = c1.y * P + q.y * c1.z;
    float det = a * d - b * c;
    if (abs(det) < 1e-6) return 0.0;
    float lx = (q.x * P * d - b * q.y * P) / det;
    float ly = (a * q.y * P - c * q.x * P) / det;
    float dz = P - (U.cam2.x * lx + U.cam2.y * ly);
    return dz > 1.0 ? P / dz : 0.0;
}

/// Inverse depth of a pixel from the depth target's (Σ w·coverage, Σ coverage); where little or nothing was written:
/// infinitely far (3D modes, D.b.w = 1) or the scene plane (flat modes).
static float dofPixelW(float2 dp, float2 sPt, constant DofU& D, constant Uniforms& U) {
    float bg = D.b.w > 0.5 ? 0.0 : planeW(sPt, U);
    if (dp.y <= 1e-4) return bg;
    return dp.y > 2e-3 ? dp.x / dp.y : bg;   // faint light still has its depth (a blend toward bg pushed faint dots away)
}

/// Signed blur radius from inverse depth: 0 within ±Range (inverse-depth units) of the focus, growing beyond it.
static float dofCocW(float w, constant DofU& D) {
    float d = w - D.c.z;
    return clamp(D.a.x * sign(d) * max(abs(d) - D.e.y, 0.0), -D.c.w, D.c.w);
}

struct DofPrepOut { float4 c [[color(0)]]; float k [[color(1)]]; float l [[color(2)]]; };

/// Half size: the scene (each pixel = its 2×2 block), the signed blur radius (full-size px) and, for the tiles, that
/// radius's size where the pixel is lit (0 where it's dark: dark pixels send no light anywhere).
fragment DofPrepOut dofPrepFrag(FSOut in [[stage_in]], texture2d<float> scene [[texture(0)]], texture2d<float> depth [[texture(1)]],
                                constant DofU& D [[buffer(0)]], constant Uniforms& U [[buffer(1)]]) {
    DofPrepOut o;
    float4 c = scene.sample(linClamp, in.uv);
#ifdef DOF_TEST
    float2 fp = in.pos.xy * 2.0;
    c = 0.25 * (dofTestScene(fp) + dofTestScene(fp + float2(1, 0)) + dofTestScene(fp + float2(0, 1)) + dofTestScene(fp + 1.0));
#endif
    o.c = select(c, float4(0.0), isnan(c) || isinf(c));
    o.k = dofCocW(dofPixelW(depth.sample(linClamp, in.uv).rg, in.uv * U.viewPx / U.pxScale, D, U), D);
    float4 ch = float4(half4(o.c));                     // as the tiles used to read it back from the half-float texture
    o.l = max(ch.r, max(ch.g, max(ch.b, ch.a * 0.1))) > 0.002 ? abs(float(half(o.k))) : 0.0;
    return o;
}

constexpr sampler nearestClamp(filter::nearest, address::clamp_to_edge);

/// One texel per 16×16 full-size pixels (8×8 of the half-size radii): the largest blur radius of its lit pixels
/// (dofPrepFrag's `l`), read as 16 gathers of 2×2 texels (edge texels repeat beyond the border, as clamped reads did).
fragment float dofTileFrag(FSOut in [[stage_in]], texture2d<float> lit [[texture(0)]]) {
    float2 inv = 1.0 / float2(lit.get_width(), lit.get_height());
    float2 o = floor(in.pos.xy) * 8.0 + 1.0;             // the shared corner of the first 2×2 block
    float4 m = float4(0.0);
    for (int y = 0; y < 4; y++) for (int x = 0; x < 4; x++)
        m = max(m, lit.gather(nearestClamp, (o + float2(2 * x, 2 * y)) * inv));
    return max(max(m.x, m.y), max(m.z, m.w));
}

/// The tiles' radii spread over the tiles they reach (one axis per pass: `dir`, reach in tiles = D.c.x).
fragment float dofDilateFrag(FSOut in [[stage_in]], texture2d<float> tiles [[texture(0)]], constant DofU& D [[buffer(0)]],
                             constant int2& dir [[buffer(1)]]) {
    int2 p = int2(in.pos.xy), sz = int2(tiles.get_width(), tiles.get_height());
    int r = int(D.c.x);
    float m = tiles.read(uint2(p)).r;
    for (int i = 1; i <= r; i++) {
        float reach = (float(i) - 1.0) * 16.0;   // the nearest pixel of a tile i away
        float a = tiles.read(uint2(clamp(p + dir * i, int2(0), sz - 1))).r;
        float b = tiles.read(uint2(clamp(p - dir * i, int2(0), sz - 1))).r;
        if (a > reach) m = max(m, a);
        if (b > reach) m = max(m, b);
    }
    return m;
}

/// Bilinear in one mip level (the nearest): half the texture reads of trilinear; the Depth gather is bound by them.
constexpr sampler dofMipN(filter::linear, mip_filter::nearest, address::clamp_to_edge);

struct DofGatherOut { float4 c [[color(0)]]; float m [[color(1)]]; };

/// Taps for a spiral of `radiusH` half-size px in a pass with `perH` taps per half-size px (at most DOF_DEPTH_TAPS).
static int dofTaps(float radiusH, float perH, int cap) { return clamp(int(8.0 + radiusH * perH), 8, cap); }

struct DofAcc { float4 acc; float wsum; float near; };

/// One ring of the gather: a golden-angle spiral filling the annulus rIn … rOut (full-size px) evenly, `n` taps, each
/// standing for `area` (its share of the whole gather disc). A tap adds its light when its own blur disc covers this
/// pixel: its distance ≤ its radius in the aperture's shape (polygon: apothem / cos of the angle inside the blade; cat's
/// eye: two discs offset ± along the radius; anamorphic: tall ovals; mirror ring: hollow), and its rim brightness
/// (bubble, ring) follows its own disc. A tap farther away than this pixel can't spread over it by more than twice
/// this pixel's own blur (a sharp thing in front hides what's behind it).
/// `R2` = the whole gather disc's radius² (the areas are shares of it): a tap's light is spread over its own disc, so it
/// counts R² / (its radius)² — the result is then the same whatever the reach R (it changes from tile to tile; when it
/// didn't count, spill and the near-focus blend changed at tile edges: straight cuts between sharp and blurred).
static void dofRing(thread DofAcc& A, texture2d<float> src, texture2d<float> cocT, float2 uv, float2 hs, float toHalf,
                    float rIn, float rOut, int n, float area, float rot, int shape, float2 radial, float k0,
                    float invMean, float noise, float R2) {
    float a2 = rIn * rIn / (rOut * rOut);
    float gap = sqrt(3.14159 * (rOut * rOut - rIn * rIn) / float(n));     // full-size px
    // one mip level whose texels are about one gap wide (0.7 … 1.4×): the bilinear tent then just closes the gaps.
    // (Wider levels made a small highlight's disc an oval or a ring, depending on where it sat on the coarse texel grid.)
    float lodN = floor(max(log2(gap * toHalf) - 1.2 * noise, 0.0) + 0.5) + 0.01;
    float soft = 0.5 * gap;
    int blades = shape == 2 ? 6 : shape == 3 ? 5 : 0;
    float seg = 6.2831853 / float(max(blades, 1)), apothem = cos(0.5 * seg);
    float ang = rot + 0.35 + 64.0 * 6.2831853;
    const float2 golden = float2(cos(2.39996323), sin(2.39996323));
    float2 dir = float2(cos(rot), sin(rot));
    float2 toUV = toHalf / hs;
    float invN = 1.0 / float(n);
    for (int i = 0; i < n; i++, dir = float2(dir.x * golden.x - dir.y * golden.y, dir.x * golden.y + dir.y * golden.x), ang += 2.39996323) {
        float rad = rOut * sqrt(a2 + (1.0 - a2) * (float(i) + 0.5) * invN);   // full-size px, shape-normalised
        float2 off = dir * rad;
        if (blades > 0) off *= apothem / cos(ang - seg * floor(ang / seg) - 0.5 * seg);
        else if (shape == 5) off.x *= 0.5;
        float2 tuv = uv + off * toUV;
        float kt = cocT.sample(dofMipN, tuv, level(lodN)).r;
        float ct = abs(kt);
        if (kt < k0 - 0.5) ct = min(ct, 2.0 * abs(k0));      // farther than this pixel: can't spill over it
        float cov = smoothstep(rad - soft, rad + soft, ct);
        float u = rad / max(ct, 1e-3);                       // where this pixel lies in the tap's own disc (0 centre, 1 rim)
        float g = 1.0;
        if (shape == 1) g = 0.55 + 0.9 * u * u * u * u;       // soap bubble: brighter rim (mean ~1)
        else if (shape == 6) { g = 0.45 + 0.8 * u * u; cov *= smoothstep(0.55, 0.7, u); }   // mirror ring: hollow
        else if (shape == 4) {                                // cat's eye: the lens of two offset discs, in its own disc's size
            float2 o = dir * u;
            if (length_squared(o - radial) > 1.0 || length_squared(o + radial) > 1.0) cov = 0.0;
        }
        if (cov <= 0.0) continue;
        float4 s = src.sample(dofMipN, tuv, level(lodN)) * g;
        float ca = cov * area * R2 / max(ct * ct, 1.0);
        // highlights (taps far brighter than the disc's average) weigh more and shine brighter, so they open into
        // visible shapes instead of fading into the background (the wide taps dilute a small bright dot)
        float h = max(luma(s.rgb) * invMean - 1.5, 0.0);
        float w = ca * (1.0 + 2.0 * h * h);
        A.acc += s * (w * (1.0 + (1.5 - 1.2 * noise) * min(h, 1.0)));
        A.wsum += w;
        // spill counts fully only where the nearer tap's disc reaches well past this pixel: on a surface whose blur grows
        // about one pixel per pixel (a street, a floor running away from the camera) every pixel is just reached by the
        // rim of the discs below it, and an all-or-nothing count flipped the blend from sharp to blurred within 2-3 rows
        if (kt > k0 + 1.0) A.near += ca * smoothstep(0.0, max(2.0, 0.25 * ct), ct - rad);
    }
}

/// Scatter-as-gather over the largest blur that can reach this pixel (R, from the tiles), in two rings: a dense inner
/// disc of this pixel's own blur (its own bokeh needs the detail) and, where bigger blurs reach it from nearer things,
/// a sparser outer ring out to R (those discs are big: sparse taps catch them). With one spiral over R the pixel's own
/// disc got only a few taps where a much blurrier area was near (discs came out as rings and ovals).
/// m = how much of the result is blur from nearer things spilling over this pixel (the combine uses the blurred
/// result there even where the pixel itself is sharp).
fragment DofGatherOut dofDepthGatherFrag(FSOut in [[stage_in]], texture2d<float> src [[texture(0)]], texture2d<float> cocT [[texture(1)]],
                                         texture2d<float> tiles [[texture(2)]], constant DofU& D [[buffer(0)]]) {
    DofGatherOut o;
    o.m = 0.0;
    float R = tiles.sample(nearestClamp, in.uv).r;     // full-size px: the reach (≥ every blur that can get here)
    // which size draws this pixel goes by the tiles' reach interpolated between tile centres (the combine's level
    // weights use the same, so levels blend smoothly instead of switching at tile edges)
    float Rl = tiles.sample(linClamp, in.uv).r;
    float2 hs = float2(src.get_width(), src.get_height());
#ifdef DOF_SKIPGATHER
    o.c = src.sample(linClamp, in.uv); return o;      // debug: timing without the gather
#endif
    if (Rl < D.c.x || Rl > D.c.y) {
        // the other pass covers this pixel; still leave a stand-in of about the right blur (a mip level), not black:
        // the combine's filtering reaches across tile edges into these texels (black showed as stepped dark outlines)
        o.c = src.sample(dofMip, in.uv, level(max(log2(R * hs.y / D.b.y * 0.7), 0.0)));
        return o;
    }
    float4 c0 = src.sample(linClamp, in.uv, level(0.0));
    o.c = c0;
    if (R < 1.0) return o;
    float k0 = cocT.sample(linClamp, in.uv).r;
    float toHalf = hs.y / D.b.y;
    float Rh = R * toHalf;
    int shape = int(D.a.y + 0.5);
    float noise = D.a.z;
    // the surroundings' average brightness, over an area ~3× the disc: a highlight is a tap far brighter than that.
    // (Over just the disc, a highlight raised the average more at its disc's centre than at the rim: a dim highlight
    // fell below the threshold in the middle and its disc came out hollow.)
    float invMean = 1.0 / (luma(src.sample(dofMip, in.uv, level(log2(Rh) + 1.6)).rgb) + 1e-4);
    float rot = hashU(int2(in.pos.xy), 0x5bd1e995u) * 6.2831853;
    if (noise > 0.0) rot += hashU(int2(in.pos.xy), uint(D.a.w * 120.0)) * 6.2831853 * min(1.0, noise * 4.0);
    float2 qv = (in.uv - 0.5) * float2(hs.x / hs.y, 1.0);
    float2 radial = shape == 4 ? normalize(qv + 1e-5) * 0.55 * smoothstep(0.1, 0.9, length(qv)) : float2(0.0);
    // the pixel itself (its own light, unless it is blurred: then its disc's taps carry it)
    float own = 1.0 - smoothstep(0.6, 2.5, abs(k0));
    DofAcc A;
    A.acc = c0 * own; A.wsum = own; A.near = 0.0;
    float r1 = max(abs(k0) * 1.15, 1.5);
    if (R <= 1.5 * r1) {
        dofRing(A, src, cocT, in.uv, hs, toHalf, 0.0, R, dofTaps(Rh, D.e.x, DOF_DEPTH_TAPS), 1.0 / float(dofTaps(Rh, D.e.x, DOF_DEPTH_TAPS)),
                rot, shape, radial, k0, invMean, noise, R * R);
    } else {
        int n1 = dofTaps(r1 * toHalf, D.e.x, DOF_DEPTH_TAPS), n2 = dofTaps(Rh, 0.5 * D.e.x, DOF_DEPTH_TAPS / 2);
        float f1 = r1 * r1 / (R * R);                        // the inner disc's share of the gather disc
        dofRing(A, src, cocT, in.uv, hs, toHalf, 0.0, r1, n1, f1 / float(n1), rot, shape, radial, k0, invMean, noise, R * R);
        dofRing(A, src, cocT, in.uv, hs, toHalf, r1, R, n2, (1.0 - f1) / float(n2), rot + 1.3, shape, radial, k0, invMean, noise, R * R);
    }
    if (A.wsum <= 1e-7) return o;
    // (not "plain + (weighted − plain) × k": that extrapolation went darker where more taps caught the highlight,
    // i.e. towards a disc's centre: hollow discs)
    o.c = max(A.acc / A.wsum, 0.0);
    o.m = smoothstep(0.0, 0.35, A.near);
    return o;
}

/// One gather level's blur at uv, through a tent about half its tap gap wide (`perH` = its taps per half-size px of reach).
static float4 dofLevel(texture2d<float> t, float2 uv, float Rh, float perH, float2 halfSize) {
    float gap = Rh * sqrt(3.14159 / float(dofTaps(Rh, perH, DOF_DEPTH_TAPS)));
    float2 e = max(0.55 * gap, 0.6) / halfSize;
    return 0.25 * (t.sample(linClamp, uv + float2(e.x, e.y * 0.35)) + t.sample(linClamp, uv - float2(e.x, e.y * 0.35))
                 + t.sample(linClamp, uv + float2(-e.x * 0.35, e.y)) + t.sample(linClamp, uv + float2(e.x * 0.35, -e.y)));
}

/// Full size: sharp where this pixel is in focus and nothing nearer spills over it, else the gathered blur (half,
/// quarter or eighth size by the reach R), then blur noise ∝ the blur.
fragment float4 dofDepthCombineFrag(FSOut in [[stage_in]], texture2d<float> sharp [[texture(0)]],
                                    texture2d<float> blurH [[texture(1)]], texture2d<float> blurQ [[texture(2)]],
                                    texture2d<float> mixH [[texture(3)]], texture2d<float> mixQ [[texture(4)]],
                                    texture2d<float> tiles [[texture(5)]], texture2d<float> depth [[texture(6)]],
                                    texture2d<float> blurE [[texture(7)]], texture2d<float> mixE [[texture(8)]],
                                    constant DofU& D [[buffer(0)]], constant Uniforms& U [[buffer(1)]]) {
    float2 px = in.pos.xy;
    float4 c = sharp.read(uint2(px));
#ifdef DOF_TEST
    c = dofTestScene(px);
#endif
    float k = dofCocW(dofPixelW(depth.read(uint2(px)).rg, px / U.pxScale, D, U), D);
    float R = tiles.sample(linClamp, in.uv).r;          // interpolated between tile centres, as the gather's level choice
    // level weights (each level's textures are only valid where its pass ran: never read one with weight 0, as
    // its stale contents could be NaN and NaN × 0 is still NaN)
    float qa = smoothstep(DOF_SPLIT_A, DOF_SPLIT_B, R), qc = smoothstep(DOF_SPLIT_C, DOF_SPLIT_D, R);
    float wH = 1.0 - qa, wQ = qa * (1.0 - qc), wE = qc;
    float m = 0.0;
    if (wH > 0.0) m += wH * mixH.sample(linClamp, in.uv).r;
    if (wQ > 0.0) m += wQ * mixQ.sample(linClamp, in.uv).r;
    if (wE > 0.0) m += wE * mixE.sample(linClamp, in.uv).r;
    float t = max(smoothstep(0.6, 2.5, abs(k)), m);
    if (t > 0.0) {
        // the tent follows the denser spiral that drew this pixel: its own blur's when the reach is much bigger
        float r1 = max(abs(k) * 1.15, 1.5);
        float Rh = (R <= 1.5 * r1 ? R : r1) * 0.5;
        float2 hsz = float2(blurH.get_width(), blurH.get_height());
        float4 b = float4(0.0);
        if (wH > 0.0) b += wH * dofLevel(blurH, in.uv, Rh, 2.4, hsz);
        if (wQ > 0.0) b += wQ * dofLevel(blurQ, in.uv, Rh, 1.2, hsz);
        if (wE > 0.0) b += wE * dofLevel(blurE, in.uv, Rh, 0.6, hsz);
        c = mix(c, b, t);
    }
#ifdef DOF_SHOWDEPTH
    // debug (AUDIOWATCH_SHADER_DEFS=DOF_SHOWDEPTH): red = nearer than the focus, blue = farther, brightness = blur radius;
    // green = blur spilling over from nearer things
    return float4(saturate(k / (0.25 * D.c.w)), m, saturate(-k / (0.25 * D.c.w)), 1.0) * (0.25 + 0.75 * saturate(luma(c.rgb) * 4.0 + c.a));
#endif
    float blur = max(abs(k) * smoothstep(0.6, 2.5, abs(k)), m * R);
    if (D.a.z > 0.0 && blur > 0.6) {
        float bn = min(blur / (0.05 * D.b.y), 1.5);
        uint seed = uint(D.a.w * 120.0) ^ 0x6d2b79f5u;
        float gr = grainAt(int2(floor(px / max(1.0, D.b.z * 0.9))), seed);
        c.rgb *= max(1.0 + gr * D.a.z * bn * 0.9, 0.0);
    }
    return select(c, float4(0.0), isnan(c) || isinf(c));
}

/// The Forest's depth (reversed-Z infinite projection: depth = near / distance, 0 = sky) → inverse depth (ref = the
/// distance that counts as "the subject", metres) for the off-screen depth target.
fragment float4 forestDepthFrag(FSOut in [[stage_in]], depth2d<float> dt [[texture(0)]], constant float2& k [[buffer(0)]]) {
    float d = dt.read(uint2(in.pos.xy));
    return float4(d * k.y / k.x, 1.0, 0.0, 0.0);      // k = (near, ref)
}

/// The City's distance (its G-buffer's colour .a; negative = sky) → inverse depth (k.y = ref, metres).
fragment float4 cityDepthFrag(FSOut in [[stage_in]], texture2d<float> g [[texture(0)]], constant float2& k [[buffer(0)]]) {
    float t = g.read(uint2(in.pos.xy)).a;
    return float4(t > 0.0 ? k.y / t : 0.0, 1.0, 0.0, 0.0);
}

// The composite is specialised per frame's feature set (Renderer.compositePipe): with every effect compiled in (the
// "all on" variant, used while a specialised one compiles) it cost ~2.5× as much at 3600×2250, even with all of
// them switched off at run time. Each constant only gates code that also checks its own setting at run time.
constant bool CF_GLOW [[function_constant(10)]];
constant bool CF_MEDIA [[function_constant(11)]];      // media layer
constant bool CF_DISP [[function_constant(12)]];       // media displacement
constant bool CF_DIST [[function_constant(13)]];       // distortion field
constant bool CF_ABER [[function_constant(14)]];       // chromatic aberration
constant bool CF_FRINGE [[function_constant(15)]];
constant bool CF_SOFT [[function_constant(16)]];
constant bool CF_STREAK [[function_constant(17)]];
constant bool CF_GRADE [[function_constant(18)]];      // contrast, hue rotation, posterize, invert
constant bool CF_GRAIN [[function_constant(19)]];      // film grain
constant bool CF_FX [[function_constant(20)]];         // pixelate, scanlines, flicker band, vignette, rounded corners

fragment float4 compositeFrag(FSOut in [[stage_in]], texture2d<float> scene [[texture(0)]],
                              texture2d<float> bloom [[texture(1)]],
                              texture2d<float> mediaTex [[texture(2)]],
                              texture2d<float> softTex [[texture(3)]],
                              texture2d<float> streakTex [[texture(4)]],
                              texture2d<float> distTex [[texture(5)]],
                              constant CompU& C [[buffer(0)]]) {
    float2 px = in.pos.xy;
    float2 size = float2(scene.get_width(), scene.get_height());
    float aspect = size.x / size.y;
    bool hasMedia = C.media.x >= 0.0;

    // where to read the scene: distort, pixelate, then displace by the media's brightness
    float2 dp = px;
    float4 dfield = float4(0, 0, 0, 1);
    if (CF_DIST && C.dist.x > 0.5 && C.dist.y > 0.0) {
        dfield = distTex.sample(linClamp, px / size);
        dp = px + dfield.xy * size.y;
        dp = size - abs(size - abs(dp));   // mirror at the edges instead of smearing the border pixels
    }
    float2 sp = dp;
    if (CF_FX && C.fx.y > 1.0) sp = (floor(dp / C.fx.y) + 0.5) * C.fx.y;
    if (CF_MEDIA && CF_DISP && hasMedia && C.media.z > 0.0) {
        float2 e = float2(3.0) / size;
        float2 uv0 = sp / size;
        float lx = luma(mediaAt(mediaTex, uv0 + float2(e.x, 0), aspect, C).rgb) - luma(mediaAt(mediaTex, uv0 - float2(e.x, 0), aspect, C).rgb);
        float ly = luma(mediaAt(mediaTex, uv0 + float2(0, e.y), aspect, C).rgb) - luma(mediaAt(mediaTex, uv0 - float2(0, e.y), aspect, C).rgb);
        float l0 = luma(mediaAt(mediaTex, uv0, aspect, C).rgb);
        // edges push sideways, brightness pushes outward from the centre
        sp += (float2(lx, ly) * 4.0 + normalize(uv0 - 0.5 + 1e-4) * (l0 - 0.5)) * C.media.z;
    }
    float2 uv = sp / size;
    // dark solid things (Real Metaballs' black fluid) cover the background: the scene's alpha is their coverage
    float occ = C.mediaKal.z > 0.0 ? clamp(scene.sample(linClamp, uv).a, 0.0, 1.0) : 0.0;
    float3 c;
    if (CF_ABER && C.fx.x > 0.0) {
        float2 o = (uv - 0.5) * 2.0 * C.fx.x / size;
        c = float3(scene.sample(linClamp, uv + o).r, scene.sample(linClamp, uv).g, scene.sample(linClamp, uv - o).b);
        if (CF_GLOW && C.glow > 0.0) c += float3(bloom.sample(linClamp, uv + o).r, bloom.sample(linClamp, uv).g, bloom.sample(linClamp, uv - o).b) * C.glow * 2.2;
    } else {
        c = scene.sample(linClamp, uv).rgb;
        if (CF_GLOW && C.glow > 0.0) c += bloom.sample(linClamp, uv).rgb * C.glow * 2.2;
    }
    // edge fringe: re-read the scene along the edge normal (from the blurred copy) with a spread of spectral weights
    if (CF_FRINGE && C.fx2.z > 0.0) {
        float2 e = 2.0 / float2(softTex.get_width(), softTex.get_height());
        float lx = luma(softTex.sample(linClamp, uv + float2(e.x, 0)).rgb) - luma(softTex.sample(linClamp, uv - float2(e.x, 0)).rgb);
        float ly = luma(softTex.sample(linClamp, uv + float2(0, e.y)).rgb) - luma(softTex.sample(linClamp, uv - float2(0, e.y)).rgb);
        float2 g = float2(lx, ly);
        float gm = length(g);
        if (gm > 1e-4) {
            float2 off = -g / gm * C.fx2.z / size * smoothstep(0.0, 0.06, gm);
            float3 acc = float3(0.0), wsum = float3(0.0);
            for (int k = 0; k < 7; k++) {
                float t = float(k) / 6.0;
                float3 w = spectral(t);
                acc += scene.sample(linClamp, uv + off * (t * 2.0 - 1.0)).rgb * w;
                wsum += w;
            }
            float3 fr = acc / wsum;
            c += fr - scene.sample(linClamp, uv).rgb;
        }
    }
    // soft focus: blend toward a wide blur (and a little halation on top); streak: long vertical smear
    if (CF_SOFT && C.fx2.x > 0.0) {
        float3 sf = softTex.sample(linClamp, uv).rgb;
        c = mix(c, sf * 1.1, C.fx2.x * 0.75) + sf * C.fx2.x * 0.35;
    }
    if (CF_STREAK && C.fx2.y > 0.0) c += streakTex.sample(linClamp, uv).rgb * C.fx2.y * 2.5;
    c *= C.sceneGain;
    c = select(c, float3(0.0), isnan(c) || isinf(c));   // never let a bad sample poison the frame
    // Hue-preserving tonemap: compress brightness by the max channel so dense overlaps keep their palette colour
    float m = max(c.r, max(c.g, c.b));
    if (m > 1e-5) c *= (1.0 - exp(-m * 1.3)) / m;

    // media layer
    float mediaAlpha = 0.0;
    if (CF_MEDIA && hasMedia) {
        float4 mt = mediaAt(mediaTex, (C.fx.y > 1.0 ? sp : dp) / size, aspect, C);
        float3 mi = mt.rgb;
        float op = C.media.y;
        float lit = max(clamp(max(c.r, max(c.g, c.b)), 0.0, 1.0), occ);
        switch (int(C.media.x + 0.5)) {
            case 0: c += mi * op * (1.0 - lit); mediaAlpha = op * mt.a; break;                       // behind
            case 1: c += mi * op; mediaAlpha = op * mt.a; break;                                     // add
            case 2: c = mix(c, 1.0 - (1.0 - c) * (1.0 - mi), op); mediaAlpha = op * mt.a; break;     // screen
            case 3: {                                                                                // overlay
                float3 ov = select(1.0 - 2.0 * (1.0 - mi) * (1.0 - c), 2.0 * mi * c, mi < 0.5);
                c = mix(c, ov + c * 0.35, op); mediaAlpha = op * mt.a; break;
            }
            case 4: c = mix(c, c * mi, op); break;                                                   // multiply
            case 5: c *= mix(1.0, luma(mi), op); break;                                              // mask
            case 6: c = mix(c, abs(c - mi), op); mediaAlpha = op * mt.a; break;                      // difference
            default: break;                                                                          // hidden
        }
    }

    // distortion shading (3D caustics + glints, raindrop rims, black holes)
    if (CF_DIST) c = c * dfield.a + dfield.b * mix(float3(1.0), C.ink.rgb, 0.25);

    // colour grade
    c *= exp2(C.grade.x * 1.5);
    if (CF_GRADE && C.grade.y != 1.0) {
        // contrast curve through (0,0), (½,½), (1,1): black stays black, so transparent windows stay clear
        float3 x = clamp(c, 0.0, 1.0);
        float3 lo = 0.5 * pow(2.0 * x, C.grade.y);
        float3 hi = 1.0 - 0.5 * pow(2.0 * (1.0 - x), C.grade.y);
        c = select(hi, lo, x < 0.5) + max(c - 1.0, 0.0);
    }
    c = max(mix(float3(luma(c)), c, C.grade.z), 0.0);
    if (CF_GRADE && C.grade.w != 0.0) {
        float a = C.grade.w * 6.2831853;
        float3 k = float3(0.57735);
        c = c * cos(a) + cross(k, c) * sin(a) + k * dot(k, c) * (1.0 - cos(a));
        c = max(c, 0.0);
    }
    if (CF_GRADE && C.fx.z >= 2.0) c = floor(c * (C.fx.z - 1.0) + 0.5) / (C.fx.z - 1.0);
    if (CF_GRADE && C.fx.w > 0.0) c = mix(c, 1.0 - min(c, 1.0), C.fx.w);

    if (CF_FX) {
        // rolling refresh band
        float bd = (in.uv.y - C.bandY) / 0.08;
        c += C.ink.rgb * C.flicker * 0.06 * exp(-bd * bd);
        // scanlines
        float line = fract(px.y / (3.0 * C.pxScale));
        c *= 1.0 - C.scan * 0.55 * smoothstep(0.42, 0.62, line);
        // flicker
        c *= 1.0 - C.flickerRand;
    }
    c = max(c, 0.0);
    // background colour underneath the (additive) light
    float lit = max(clamp(max(c.r, max(c.g, c.b)), 0.0, 1.0), occ);
    c += C.bg.rgb * C.bgOpacity * (1.0 - lit);
    float alpha = max(lit + C.bgOpacity * (1.0 - lit), mediaAlpha);
    // film grain: signed (triangular) noise, so it shows on bright and grey areas too
    if (CF_GRAIN && C.fx2.w > 0.0) {
        // Size 1 ≈ one cell per 1.25 px; bigger sizes blend between lattice points so grain clumps instead of turning into squares.
        float cellPx = 1.25 * C.pxScale * max(C.grainSize, 0.5);
        uint seed = uint(C.time * 120.0);   // new grain every frame
        float gn;
        if (C.grainSize <= 1.05) {
            gn = grainAt(int2(floor(px / cellPx)), seed);
        } else {
            // Coarse grain: smooth noise on a lattice turned ~37° (hides the square grid), plus some fine grain for texture.
            float2 g = float2x2(0.8, -0.6, 0.6, 0.8) * (px / cellPx);
            int2 i = int2(floor(g));
            float2 f = fract(g);
            f = f * f * (3.0 - 2.0 * f);
            float a = grainAt(i, seed), b = grainAt(i + int2(1, 0), seed);
            float d = grainAt(i + int2(0, 1), seed), e = grainAt(i + int2(1, 1), seed);
            float coarse = mix(mix(a, b, f.x), mix(d, e, f.x), f.y) * 1.5;   // blending lowers contrast; give it back
            float fine = grainAt(int2(floor(px / (1.25 * C.pxScale))), seed ^ 0x51ed27u);
            gn = coarse * 0.8 + fine * 0.3;
        }
        c = max(c + gn * C.fx2.w * 0.14, 0.0);
    }
    if (CF_FX) {
        // vignette
        float2 q = (in.uv - 0.5) * float2(size.x / size.y, 1.0);
        c *= 1.0 - C.vignette * 0.85 * smoothstep(0.3, 1.0, length(q));
        // rounded CRT corners
        float r = C.cornerR;
        float2 h = size * 0.5;
        float2 pp = abs(px - h) - (h - r);
        float d = length(max(pp, 0.0)) + min(max(pp.x, pp.y), 0.0) - r;
        float mask = clamp(0.5 - d, 0.0, 1.0);
        c *= mask;
        alpha = mix(C.bgOpacity, alpha, mask);
    }
    // Dither to the 8-bit output (±1 step of triangular noise, new every frame): smooth glows and dark gradients
    // would otherwise show bands. Pure black stays pure black, so transparent windows stay clear.
    // (one 32-bit hash split into two 16-bit uniform numbers: their sum is the triangular noise, at half the cost)
    uint ds = uint(C.time * 120.0) * 2654435761u;
    uint dh = uint(int(px.x)) * 1597334673u ^ uint(int(px.y)) * 3812015801u ^ ds;
    dh = (dh ^ (dh >> 16)) * 0x7feb352du;
    dh = (dh ^ (dh >> 15)) * 0x846ca68bu;
    dh ^= dh >> 16;
    float dn = (float(dh & 0xffffu) + float(dh >> 16) - 65535.0) * (1.0 / (65536.0 * 255.0));
    c += dn * smoothstep(float3(0.0), float3(2.0 / 255.0), c);
    return float4(clamp(c, 0.0, alpha), alpha);
}
"""#
