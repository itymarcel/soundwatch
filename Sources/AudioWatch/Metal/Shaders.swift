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
struct Seg { float2 a; float2 b; float4 color; float width; float dash; float cap; float pad; };

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
    float time; float pxScale; float flickerRand; float pad;
    float4 grade;    // brightness, contrast, saturation, hue (turns)
    float4 fx;       // aberration px, pixel size px, posterize levels, invert
    float4 media;    // blend (-1 = none), opacity, displace px, fit
    float4 media2;   // media aspect, padded (blurred) texture flag, pad fraction x, y
    float4 mediaXf;  // offset x, y (screen heights), scale, angle
    float4 mediaKal; // kaleidoscope segments, tile mode
    float4 fx2;      // soft focus, streak, edge fringe px, film grain
};

struct ShaderModeU {
    float4 view0; float4 view1; float4 view2;
    float2 viewPt; float2 center;
    float2 pan; float zoom; float world;
    float time; float phase; float colorByFreq; float level;
    float bass; float beat; float reach; float count;
    float4 p0; float4 p1;
};

// ---------------------------------------------------------------- helpers

constexpr sampler linClamp(filter::linear, address::clamp_to_edge);

static float pingPong(float t) { float m = t - 2.0 * floor(t * 0.5); return m <= 1.0 ? m : 2.0 - m; }

static float3 pal(texture2d<float> p, float t) {
    return p.sample(linClamp, float2((pingPong(t) * 255.0 + 0.5) / 256.0, 0.5)).rgb;
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

// ---------------------------------------------------------------- segments (lines, dots, rects)

struct SegOut {
    float4 pos [[position]];
    float2 local;
    float4 color;
    float len; float hw; float dash; float cap; float dashBase; float alphaK;
};

static SegOut makeSeg(float2 aPt, float2 bPt, float widthPt, float4 color, float dashPt, float cap,
                      uint vid, constant Uniforms& U) {
    SegOut o;
    float s = U.pxScale;
    float3 ca = camXf(aPt, U), cb = camXf(bPt, U);
    float2 a = ca.xy * s, b = cb.xy * s;
    float wpx = widthPt * s * 0.5 * (ca.z + cb.z);
    float hw = max(wpx * 0.5, 0.5);
    float2 d = b - a;
    float len = length(d);
    float2 dir = len > 1e-4 ? d / len : float2(1.0, 0.0);
    float2 nrm = float2(-dir.y, dir.x);
    float ext = hw + 1.0;
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

// ---------------------------------------------------------------- shaded triangles (3D surfaces)

struct TriV { float2 p; float2 pad; float4 color; };
struct TriOut { float4 pos [[position]]; float4 color; };

/// Pre-projected, pre-lit triangle vertices (window points); only pan/zoom is applied here.
vertex TriOut triVert(uint vid [[vertex_id]], const device TriV* T [[buffer(0)]], constant Uniforms& U [[buffer(1)]]) {
    TriV t = T[vid];
    float2 px = camXf(t.p, U).xy * U.pxScale;
    float2 ndc = px / U.viewPx * 2.0 - 1.0;
    TriOut o;
    o.pos = float4(ndc.x, -ndc.y, 0.0, 1.0);
    o.color = t.color;
    return o;
}

fragment float4 triFrag(TriOut in [[stage_in]]) {
    return float4(in.color.rgb * in.color.a, in.color.a);       // premultiplied
}

vertex SegOut segVert(uint vid [[vertex_id]], uint iid [[instance_id]],
                      const device Seg* segs [[buffer(0)]], constant Uniforms& U [[buffer(1)]]) {
    Seg g = segs[iid];
    return makeSeg(g.a, g.b, g.width, g.color, g.dash, g.cap, vid, U);
}

fragment float4 segFrag(SegOut in [[stage_in]]) {
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
    return float4(in.color.rgb * a, a);
}

// ---------------------------------------------------------------- sphere (fully GPU)

vertex SegOut sphereVert(uint vid [[vertex_id]], uint iid [[instance_id]],
                         const device float4* unit [[buffer(0)]], const device float* vals [[buffer(1)]],
                         constant SphereU& S [[buffer(2)]], constant Uniforms& U [[buffer(3)]],
                         const device float* hist [[buffer(4)]],
                         texture2d<float> palTex [[texture(0)]]) {
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
    float proj = S.cam / (S.cam - q.z * disp);
    float2 sp = S.center + float2(q.x, -q.y) * disp * S.R * proj;
    float fade = 0.15 + 0.85 * (q.z + 1.0) * 0.5;
    float t = (S.colorByFreq > 0.5 ? frac : min(a, 1.0)) + S.phase;
    float3 col = pal(palTex, t);
    float alpha = fade * (0.3 + 0.7 * min(a * 1.2, 1.0)) * S.alphaK;

    if (S.mode == 0) {
        float r = S.dotR * proj * (0.6 + 1.6 * a);
        return makeSeg(sp, sp, 2.0 * r, float4(col, alpha), 0.0, S.square, vid, U);
    }
    float p0 = S.cam / (S.cam - q.z);
    float2 bp = S.center + float2(q.x, -q.y) * S.R * p0;
    if (S.mode == 1) {
        return makeSeg(bp, sp, S.lineW, float4(col, alpha), S.dash, S.dash > 0.0 ? 1.0 : 0.0, vid, U);
    }
    float r = S.dotR * p0 * 0.45;
    return makeSeg(bp, bp, 2.0 * r, float4(col, fade * 0.35 * S.alphaK), 0.0, S.square, vid, U);
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
    float2 jitter = float2(rnd(i, U.frame * 2u), rnd(i, U.frame * 2u + 1u)) - 0.5;
    // Reach (p0) scales how far grains are kicked, not how fast they settle: the figure must always form.
    float2 v = -g / (ks * ks) * 0.05 * U.speed
             + jitter * (amp + 0.01) * (U.shake + U.beat * 2.5) * 0.12 / ks * U.p0;
    v *= U.dtScale;
    p += v;
    if (any(p < 0.0) || any(p > 1.0) || rnd(i, U.frame + 777u) < 0.0003) {
        p = float2(rnd(i, U.frame + 11u), rnd(i, U.frame + 23u));
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

vertex SegOut partVert(uint vid [[vertex_id]], uint iid [[instance_id]],
                       const device float4* P [[buffer(0)]], const device float* vals [[buffer(1)]],
                       constant PartDrawU& D [[buffer(2)]], constant Uniforms& U [[buffer(3)]],
                       texture2d<float> palTex [[texture(0)]]) {
    float4 s = P[iid];
    float2 sp = D.origin + s.xy * D.extent;
    float2 vpx = s.zw * D.extent;
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
    float3 col = pal(palTex, t + D.phase);
    if (D.streak > 0.0 && length(vpx) > 0.05) {
        float2 tail = sp - vpx * D.streak;
        if (length(tail - sp) > D.extent.x * 0.25) tail = sp;            // skip wrap-around jumps
        return makeSeg(tail, sp, D.dotR * 2.0, float4(col, alpha), 0.0, 0.0, vid, U);
    }
    return makeSeg(sp, sp, D.dotR * 2.0, float4(col, alpha), 0.0, D.square, vid, U);
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
static float3 membraneH(float2 p, constant ShaderModeU& M, const device float* B) {
    float g0 = exp(-dot(p, p) / 0.7);
    float h = M.bass * 0.3 * g0;
    float2 grad = M.bass * 0.3 * g0 * (-2.0 * p / 0.7);
    int n = int(M.count);
    float wl = max(M.p1.x, 0.02);
    float k = 3.14159 / wl, s2 = wl * wl * 1.5;
    for (int i = 0; i < n; i++) {
        const device float* b = B + i * 6;
        float2 d = p - float2(b[0], b[1]);
        float r2 = dot(d, d);
        float rr = b[2] * b[2];
        float gb = b[3] * exp(-r2 / rr);
        h += gb;
        grad += gb * (-2.0 * d / rr);
        if (b[5] > 1e-4) {
            float r = sqrt(r2) + 1e-5;
            float x = r - b[4];
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
                             const device float* B [[buffer(2)]], constant CompU& C [[buffer(3)]],
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
                        const device float* B [[buffer(2)]], texture2d<float> palTex [[texture(0)]]) {
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
        const device float* R = B + nb;
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

/// Glass Stack: raymarched rings/discs as glowing glass shells (rendered at a third of the resolution).
fragment float4 glassFrag(FSOut in [[stage_in]], constant ShaderModeU& M [[buffer(0)]],
                          const device float* B [[buffer(2)]], texture2d<float> palTex [[texture(0)]]) {
    float2 s = (in.uv * M.viewPt - M.center - M.pan) / M.zoom;
    float camD = M.p0.y;
    float3 o = float3(0.0, 0.0, camD);
    float3 d = normalize(float3(s.x, -s.y, 0.0) / M.world - o);
    float3 ow = M.view0.xyz * o.x + M.view1.xyz * o.y + M.view2.xyz * o.z;
    float3 dw = normalize(M.view0.xyz * d.x + M.view1.xyz * d.y + M.view2.xyz * d.z);
    const float BR = 2.1;
    float b = dot(ow, dw), c = dot(ow, ow) - BR * BR, disc = b * b - c;
    if (disc < 0.0) return float4(0.0);
    float sq = sqrt(disc);
    float t = max(-b - sq, 0.0), t1 = -b + sq;
    t += hash(in.pos.xy + fract(M.time) * 91.0) * 0.02;
    int n = int(M.count);
    float sz = M.p0.z;
    float3 acc = float3(0.0);
    for (int it = 0; it < 90 && t < t1; it++) {
        float3 q = ow + dw * t;
        float blur = 1.0 + M.p0.x * 5.0 * abs(t - camD);
        float w = 0.016 * sz * blur;
        float minAbs = 1e3;
        float3 dens = float3(0.0);
        for (int j = 0; j < n; j++) {
            const device float* R = B + j * 20;
            float3 rel = q - float3(R[0], R[1], R[2]);
            float bound = length(rel) - (R[3] + max(R[7], R[11]) + 4.0 * w);
            if (bound > 0.0) { minAbs = min(minAbs, bound + 3.0 * w); continue; }
            float3 l = float3(dot(float3(R[4], R[5], R[6]), rel), dot(float3(R[8], R[9], R[10]), rel), dot(float3(R[12], R[13], R[14]), rel));
            float2 q2 = float2(length(l.xz) - R[3], l.y);
            float sd;
            if (R[15] > 0.5) {
                float2 dd = abs(q2) - float2(R[11], 0.022 * sz);
                sd = length(max(dd, 0.0)) + min(max(dd.x, dd.y), 0.0) - 0.01;
            } else {
                sd = length(q2) - R[7];
            }
            minAbs = min(minAbs, abs(sd));
            float shell = exp(-sd * sd / (w * w)) / blur;
            float fill = sd < 0.0 ? 0.03 : 0.0;
            dens += pal(palTex, R[17]) * (shell + fill) * (0.35 + 0.9 * R[16]);
        }
        float h = clamp(0.6 * minAbs, 0.4 * w, 0.15);
        acc += dens * h;
        t += h;
    }
    acc *= 6.0;
    return float4(acc, min(1.0, max(acc.r, max(acc.g, acc.b))));
}

/// Diamond: the orbiting lights as seen in direction `d` (the stone's surroundings are otherwise dark).
static float3 diamondEnv(float3 d, const device float* Lt, int nl) {
    // a dim studio: soft brighter "ceiling", darker floor, so facets show even away from the lights
    float3 e = float3(0.05, 0.05, 0.06) * (0.35 + 0.65 * smoothstep(-0.4, 0.9, d.y));
    for (int i = 0; i < nl; i++) {
        const device float* L = Lt + i * 8;
        float c = max(dot(d, float3(L[0], L[1], L[2])), 0.0);
        e += float3(L[4], L[5], L[6]) * L[7] * (pow(c, L[3]) * 3.5 + pow(c, 4.0) * 0.18);
    }
    return e;
}

/// Ray vs convex solid (planes n·x ≤ w): entry/exit distances and the facets hit.
static float2 convexHit(float3 o, float3 d, const device float4* P, int n, thread int& inI) {
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
static float3 diamondTrace(float3 o, float3 d, const device float4* P, int n, const device float* Lt, int nl, float eta) {
    int ii = 0;
    float2 tt = convexHit(o, d, P, n, ii);
    if (tt.x > tt.y || tt.x < 0.0) return float3(-1.0);
    float r0 = (eta - 1.0) / (eta + 1.0); r0 *= r0;
    float3 p = o + d * tt.x;
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

fragment float4 diamondFrag(FSOut in [[stage_in]], constant ShaderModeU& M [[buffer(0)]],
                            const device float* B [[buffer(2)]]) {
    float2 s = (in.uv * M.viewPt - M.center - M.pan) / M.zoom;
    float camD = M.p0.z;
    float3 o = float3(0.0, 0.0, camD);
    float3 d = normalize(float3(s.x, -s.y, 0.0) / M.world - o);
    float3 ow = M.view0.xyz * o.x + M.view1.xyz * o.y + M.view2.xyz * o.z;
    float3 dw = normalize(M.view0.xyz * d.x + M.view1.xyz * d.y + M.view2.xyz * d.z);
    // bounding sphere: the stone is ~1.05 at rest; music + Movement can push, stretch and shift it to ~2
    float b = dot(ow, dw), c = dot(ow, ow) - 4.4, disc = b * b - c;
    if (disc < 0.0 || -b + sqrt(disc) < 0.0) return float4(0.0);
    int n = int(M.count), nl = int(M.p0.x);
    const device float4* P = (const device float4*)B;
    const device float* Lt = B + n * 4;
    float fire = M.p0.y * 0.16;   // Rainbow: spread of the refractive index between red and blue
    float3 col;
    if (fire < 0.002) {
        col = diamondTrace(ow, dw, P, n, Lt, nl, 2.417);
        if (col.x < 0.0) return float4(0.0);
    } else {
        float3 r = diamondTrace(ow, dw, P, n, Lt, nl, 2.417 - fire);
        if (r.x < 0.0) return float4(0.0);
        float3 g = diamondTrace(ow, dw, P, n, Lt, nl, 2.417);
        float3 bl = diamondTrace(ow, dw, P, n, Lt, nl, 2.417 + fire);
        col = float3(r.r, g.g, bl.b);
    }
    return float4(col, min(1.0, max(col.r, max(col.g, col.b))));
}

/// Adds a (smaller) texture over the scene, upsampled.
fragment float4 copyFrag(FSOut in [[stage_in]], texture2d<float> src [[texture(0)]]) {
    return src.sample(linClamp, in.uv);
}

fragment float4 compositeFrag(FSOut in [[stage_in]], texture2d<float> scene [[texture(0)]],
                              texture2d<float> bloom [[texture(1)]],
                              texture2d<float> mediaTex [[texture(2)]],
                              texture2d<float> softTex [[texture(3)]],
                              texture2d<float> streakTex [[texture(4)]],
                              constant CompU& C [[buffer(0)]]) {
    float2 px = in.pos.xy;
    float2 size = float2(scene.get_width(), scene.get_height());
    float aspect = size.x / size.y;
    bool hasMedia = C.media.x >= 0.0;

    // where to read the scene: pixelate, then displace by the media's brightness
    float2 sp = px;
    if (C.fx.y > 1.0) sp = (floor(px / C.fx.y) + 0.5) * C.fx.y;
    if (hasMedia && C.media.z > 0.0) {
        float2 e = float2(3.0) / size;
        float2 uv0 = sp / size;
        float lx = luma(mediaAt(mediaTex, uv0 + float2(e.x, 0), aspect, C).rgb) - luma(mediaAt(mediaTex, uv0 - float2(e.x, 0), aspect, C).rgb);
        float ly = luma(mediaAt(mediaTex, uv0 + float2(0, e.y), aspect, C).rgb) - luma(mediaAt(mediaTex, uv0 - float2(0, e.y), aspect, C).rgb);
        float l0 = luma(mediaAt(mediaTex, uv0, aspect, C).rgb);
        // edges push sideways, brightness pushes outward from the centre
        sp += (float2(lx, ly) * 4.0 + normalize(uv0 - 0.5 + 1e-4) * (l0 - 0.5)) * C.media.z;
    }
    float2 uv = sp / size;
    float3 c;
    if (C.fx.x > 0.0) {
        float2 o = (uv - 0.5) * 2.0 * C.fx.x / size;
        c = float3(scene.sample(linClamp, uv + o).r, scene.sample(linClamp, uv).g, scene.sample(linClamp, uv - o).b);
        if (C.glow > 0.0) c += float3(bloom.sample(linClamp, uv + o).r, bloom.sample(linClamp, uv).g, bloom.sample(linClamp, uv - o).b) * C.glow * 2.2;
    } else {
        c = scene.sample(linClamp, uv).rgb;
        if (C.glow > 0.0) c += bloom.sample(linClamp, uv).rgb * C.glow * 2.2;
    }
    // edge fringe: re-read the scene along the edge normal (from the blurred copy) with a spread of spectral weights
    if (C.fx2.z > 0.0) {
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
    if (C.fx2.x > 0.0) {
        float3 sf = softTex.sample(linClamp, uv).rgb;
        c = mix(c, sf * 1.1, C.fx2.x * 0.75) + sf * C.fx2.x * 0.35;
    }
    if (C.fx2.y > 0.0) c += streakTex.sample(linClamp, uv).rgb * C.fx2.y * 2.5;
    c *= C.sceneGain;
    c = select(c, float3(0.0), isnan(c) || isinf(c));   // never let a bad sample poison the frame
    // Hue-preserving tonemap: compress brightness by the max channel so dense overlaps keep their palette colour
    float m = max(c.r, max(c.g, c.b));
    if (m > 1e-5) c *= (1.0 - exp(-m * 1.3)) / m;

    // media layer
    float mediaAlpha = 0.0;
    if (hasMedia) {
        float4 mt = mediaAt(mediaTex, (C.fx.y > 1.0 ? sp : px) / size, aspect, C);
        float3 mi = mt.rgb;
        float op = C.media.y;
        float lit = clamp(max(c.r, max(c.g, c.b)), 0.0, 1.0);
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

    // colour grade
    c *= exp2(C.grade.x * 1.5);
    if (C.grade.y != 1.0) {
        // contrast curve through (0,0), (½,½), (1,1): black stays black, so transparent windows stay clear
        float3 x = clamp(c, 0.0, 1.0);
        float3 lo = 0.5 * pow(2.0 * x, C.grade.y);
        float3 hi = 1.0 - 0.5 * pow(2.0 * (1.0 - x), C.grade.y);
        c = select(hi, lo, x < 0.5) + max(c - 1.0, 0.0);
    }
    c = max(mix(float3(luma(c)), c, C.grade.z), 0.0);
    if (C.grade.w != 0.0) {
        float a = C.grade.w * 6.2831853;
        float3 k = float3(0.57735);
        c = c * cos(a) + cross(k, c) * sin(a) + k * dot(k, c) * (1.0 - cos(a));
        c = max(c, 0.0);
    }
    if (C.fx.z >= 2.0) c = floor(c * (C.fx.z - 1.0) + 0.5) / (C.fx.z - 1.0);
    if (C.fx.w > 0.0) c = mix(c, 1.0 - min(c, 1.0), C.fx.w);

    // rolling refresh band
    float bd = (in.uv.y - C.bandY) / 0.08;
    c += C.ink.rgb * C.flicker * 0.06 * exp(-bd * bd);
    // scanlines
    float line = fract(px.y / (3.0 * C.pxScale));
    c *= 1.0 - C.scan * 0.55 * smoothstep(0.42, 0.62, line);
    // flicker
    c *= 1.0 - C.flickerRand;
    c = max(c, 0.0);
    // background colour underneath the (additive) light
    float lit = clamp(max(c.r, max(c.g, c.b)), 0.0, 1.0);
    c += C.bg.rgb * C.bgOpacity * (1.0 - lit);
    float alpha = max(lit + C.bgOpacity * (1.0 - lit), mediaAlpha);
    // film grain: signed (triangular) noise, so it shows on bright and grey areas too
    if (C.fx2.w > 0.0) {
        float2 cell = floor(px / (1.25 * C.pxScale));
        float tg = fract(C.time * 5.13) * 731.0;
        float gn = hash(cell + tg) + hash(cell + tg + 17.31) - 1.0;
        c = max(c + gn * C.fx2.w * 0.14, 0.0);
    }
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
    return float4(min(c, alpha), alpha);
}
"""#
