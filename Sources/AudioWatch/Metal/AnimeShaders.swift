import Foundation

// Anime mode: MSL source (own library, compiled at runtime by AnimeGPU).
// Pass 1 `anLayersFrag` draws the layer stack at the chosen resolution (front-to-back, premultiplied, each layer a
// procedural painting in our own designs: painted skies, cel-shaded clouds, wind-swept meadows, particles, manga
// speed lines, slashes, auras …) through the camera: roll + zoom for all, pan / push-in scaled by each layer's depth
// (parallax). Each layer is a card in 3D (its own plane, `view.w` apart), ray-cast from the orbit camera. Pass 2 `anPostFrag` scales it to the window (Catmull-Rom), adds the film look (diffusion glow,
// grain, gate weave, faded warm blacks, vignette), impact frames and letterbox bars.
// `ANU` ↔ `ANUniforms`, `ANL` ↔ `ANLayerUniforms` (AnimeGPU.swift): keep them in step.

let animeShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct ANU {
    float4 res;      // width, height (pixels), aspect, layer count
    float4 music;    // bass, mid, treble (relative levels 0…1), loudness 0…1
    float4 hits;     // kick, snare, hat pulses, beat pulse
    float4 time;     // seconds (stepped with the drawings), wind strength, wind phase (integrated), gust
    float4 cam;      // camera x, y (layer units at depth 1), zoom, roll (rad)
    float4 cam2;     // push-in travel, unused, unused, sideways travel (only repeating layers follow it)
    float4 post;     // film look, impact frame (1 while shown), letterbox, impact style (0…1)
    float4 outp;     // output width, height, frame counter, 0
    float4 bands[4]; // 16 relative band levels
    float4 pal[4];   // the palette at 0, ⅓, ⅔, 1
    float4 rot[3];   // orbit camera rotation rows (view → world = these as columns)
    float4 view;     // orbit zoom, pan x / y (NDC), gap between the layer planes
};
struct ANL {
    float4 a;   // kind, style, opacity, music amount (react)
    float4 b;   // offset x, y (layer units), scale, rotation (rad)
    float4 c;   // clock, hue turn, depth, drawing seed
    float4 e;   // per kind (slashes, bursts, meteors: ages and seeds)
    float4 f;   // per kind; f.w = 1: the layer repeats sideways (follows the camera's endless pan)
};

struct ANOut { float4 position [[position]]; };

vertex ANOut anVert(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    ANOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

constexpr sampler anLin(filter::linear, address::clamp_to_edge);
constexpr sampler anMip(filter::linear, mip_filter::linear, address::clamp_to_edge);
constant float PI = 3.14159265;
constant float TAU = 6.2831853;

// ---------------------------------------------------------------- helpers

static uint ihash(uint x) {
    x ^= x >> 16; x *= 0x7feb352dU; x ^= x >> 15; x *= 0x846ca68bU; x ^= x >> 16;
    return x;
}
static float hash1(int n) { return float(ihash(uint(n) * 747796405U + 2891336453U)) * (1.0 / 4294967296.0); }
static float hash2(int2 c) { return float(ihash(uint(c.x) * 1597334677U ^ ihash(uint(c.y) + 0x9E3779B9U))) * (1.0 / 4294967296.0); }
static float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    int2 c = int2(i);
    float a = hash2(c), b = hash2(c + int2(1, 0)), d = hash2(c + int2(0, 1)), e = hash2(c + int2(1, 1));
    return mix(mix(a, b, f.x), mix(d, e, f.x), f.y);
}
static float fbm(float2 p) {
    float s = 0.0, a = 0.5;
    for (int i = 0; i < 4; i++) { s += a * vnoise(p); p = p * 2.03 + float2(17.1, 9.3); a *= 0.5; }
    return s / 0.9375;
}
static float2 rot2(float2 p, float a) { float s = sin(a), c = cos(a); return float2(c * p.x - s * p.y, s * p.x + c * p.y); }
static float sdBox(float2 p, float2 b) { float2 d = abs(p) - b; return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0); }
static float sdSeg(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    float h = saturate(dot(pa, ba) / dot(ba, ba));
    return length(pa - ba * h);
}
static float sdTrap(float2 p, float r1, float r2, float he) {
    float2 k1 = float2(r2, he), k2 = float2(r2 - r1, 2.0 * he);
    p.x = abs(p.x);
    float2 ca = float2(p.x - min(p.x, (p.y < 0.0) ? r1 : r2), abs(p.y) - he);
    float2 cb = p - k1 + k2 * saturate(dot(k1 - p, k2) / dot(k2, k2));
    float s = (cb.x < 0.0 && ca.y < 0.0) ? -1.0 : 1.0;
    return s * sqrt(min(dot(ca, ca), dot(cb, cb)));
}
static float sdTri(float2 p, float2 p0, float2 p1, float2 p2) {
    float2 e0 = p1 - p0, e1 = p2 - p1, e2 = p0 - p2;
    float2 v0 = p - p0, v1 = p - p1, v2 = p - p2;
    float2 pq0 = v0 - e0 * saturate(dot(v0, e0) / dot(e0, e0));
    float2 pq1 = v1 - e1 * saturate(dot(v1, e1) / dot(e1, e1));
    float2 pq2 = v2 - e2 * saturate(dot(v2, e2) / dot(e2, e2));
    float s = sign(e0.x * e2.y - e0.y * e2.x);
    float2 d = min(min(float2(dot(pq0, pq0), s * (v0.x * e0.y - v0.y * e0.x)),
                       float2(dot(pq1, pq1), s * (v1.x * e1.y - v1.y * e1.x))),
                   float2(dot(pq2, pq2), s * (v2.x * e2.y - v2.y * e2.x)));
    return -sqrt(d.x) * sign(d.y);
}
static float smin(float a, float b, float k) {
    float h = saturate(0.5 + 0.5 * (b - a) / k);
    return mix(b, a, h) - k * h * (1.0 - h);
}
/// Coverage of a signed distance (negative inside), antialiased over `w`.
static float cov(float d, float w) { return saturate(0.5 - d / max(w, 1e-5)); }
static float4 pm(float3 c, float a) { return float4(c * a, a); }
/// Front-to-back: what's already there (`acc`) stays in front of `f`.
static float4 under(float4 acc, float4 f) { return acc + (1.0 - acc.a) * f; }
static float3 hueRot(float3 c, float a) {
    float3x3 toYIQ = float3x3(float3(0.299, 0.596, 0.211), float3(0.587, -0.274, -0.523), float3(0.114, -0.322, 0.312));
    float3x3 toRGB = float3x3(float3(1.0, 1.0, 1.0), float3(0.956, -0.272, -1.106), float3(0.621, -0.647, 1.703));
    float3 y = toYIQ * c;
    float s = sin(a), co = cos(a);
    y.yz = float2(co * y.y - s * y.z, s * y.y + co * y.z);
    return toRGB * y;
}
static float luma(float3 c) { return dot(c, float3(0.299, 0.587, 0.114)); }
static float bandOf(constant ANU& U, int i) { i = clamp(i, 0, 15); return U.bands[i >> 2][i & 3]; }
static float wrapPi(float a) { return a - TAU * floor((a + PI) / TAU); }

struct Ctx {
    float2 p;     // layer coordinates (y up; the horizon at 0, the screen ±0.5 high at scale 1), camera parallax included
    float2 pg;    // the same without the camera's sideways / vertical move (ground planes do their own perspective)
    float panX;   // the camera's x × this layer's depth (layer units)
    float px;     // one pixel in layer units
    float t;      // the layer's clock (Speed × music, stepped with the drawings)
    float r;      // the layer's Music amount
    int style;
    float time;   // seconds (stepped)
    float asp;    // screen aspect
    float2 c0;    // the screen's centre in layer coordinates
    float seed;   // drawing number (effects redrawn per drawing)
    float4 e, f;  // per kind
};

// ---------------------------------------------------------------- 0 sky

static float3 skyGrad(int s, float g) {
    float3 z, m, h;
    switch (s) {
        case 1: z = float3(0.26, 0.34, 0.68); m = float3(0.90, 0.58, 0.55); h = float3(1.00, 0.72, 0.38); break;
        case 2: z = float3(0.18, 0.14, 0.42); m = float3(0.86, 0.42, 0.52); h = float3(1.00, 0.66, 0.38); break;
        case 3: z = float3(0.04, 0.06, 0.20); m = float3(0.24, 0.22, 0.48); h = float3(0.86, 0.52, 0.56); break;
        case 4: z = float3(0.01, 0.015, 0.06); m = float3(0.03, 0.06, 0.16); h = float3(0.10, 0.16, 0.32); break;
        case 5: z = float3(0.20, 0.01, 0.03); m = float3(0.70, 0.07, 0.05); h = float3(1.00, 0.50, 0.18); break;
        case 6: z = float3(0.40, 0.45, 0.52); m = float3(0.55, 0.59, 0.64); h = float3(0.74, 0.76, 0.78); break;
        default: z = float3(0.09, 0.32, 0.82); m = float3(0.32, 0.60, 0.95); h = float3(0.80, 0.91, 0.98); break;
    }
    float3 c = mix(h, m, smoothstep(0.0, 0.45, g));
    return mix(c, z, smoothstep(0.35, 1.0, g));
}

static float4 anSky(Ctx c, constant ANU& U) {
    float2 p = c.p;
    float g = saturate(p.y / 0.62);
    float br = (fbm(float2(p.x * 1.3, p.y * 7.0) + 3.1) - 0.5) * 0.07;   // soft brush strokes in the paint
    float3 col = skyGrad(c.style, saturate(g + br * (1.0 - g)));
    float3 glow = c.style == 4 ? float3(0.12, 0.18, 0.35) : c.style == 5 ? float3(1.0, 0.45, 0.15) : float3(1.0, 0.85, 0.65);
    col += glow * exp(-max(p.y, 0.0) * 9.0) * (0.08 + 0.3 * U.hits.w * c.r);
    if (c.style == 6) col = mix(col, col * 0.88 + 0.07, smoothstep(0.4, 0.8, fbm(p * float2(2.0, 5.0) + float2(c.t * 0.02, 0.0))));
    if (c.style == 3 || c.style == 4) {
        const float cs = 0.011;
        float2 cell = floor(p / cs);
        int2 ic = int2(cell);
        float h = hash2(ic);
        if (h > 0.93) {
            float2 sp = (cell + 0.25 + 0.5 * float2(hash2(ic + 5), hash2(ic + 9))) * cs;
            float tw = 0.55 + 0.45 * sin(c.time * (1.0 + 3.0 * hash2(ic + 3)) + h * 50.0) + U.music.z * c.r * 0.5;
            float d = length(p - sp);
            col += float3(0.9, 0.92, 1.0) * saturate(1.0 - d / max(c.px * 1.2, 0.0012)) * tw
                 * smoothstep(0.04, 0.15, p.y) * (c.style == 4 ? 1.0 : 0.5);
        }
    }
    return float4(col, 1.0);
}

// ---------------------------------------------------------------- 1 clouds

/// A row of cumulus clouds: each cell holds a stack of puffs (smooth union), flat-bottomed at y = 0.
static float cloudSD(float2 p, float W, float swell, int seedOff) {
    float ci = floor(p.x / W);
    float d = 1e3;
    for (int k = -1; k <= 1; k++) {
        int cell = int(ci) + k;
        int hs = cell * 7 + seedOff;
        if (hash1(hs + 3) < 0.22) continue;
        float cx = (float(cell) + 0.5 + (hash1(hs + 5) - 0.5) * 0.35) * W;
        float sz = W * (0.55 + 0.45 * hash1(hs + 11)) * (1.0 + swell);
        // the cloud's bounds: far enough outside, its puffs can't be the nearest
        // (a lower bound of the distance; only distances under a few pixels need to be exact)
        float bd = max(abs(p.x - cx) - sz * 0.75, p.y - sz * 0.72);
        if (bd > 0.02) { d = min(d, bd); continue; }
        float tall = hash1(hs + 13);
        for (int j = 0; j < 9; j++) {
            float a = hash1(hs * 13 + j * 5), b = hash1(hs * 13 + j * 5 + 1);
            int row = j < 3 ? 0 : (j < 5 ? 1 : 2);
            float fx = j < 3 ? float(j - 1) * 0.26 : (j < 5 ? (float(j) - 3.5) * 0.22 : j < 7 ? (float(j) - 5.5) * 0.14 : (float(j) - 7.5) * 0.36);
            float r = sz * (row == 0 ? 0.17 : row == 1 ? 0.15 : 0.12) * (0.8 + 0.4 * a);
            if (row == 2 && tall < 0.35) r *= 0.6;
            float2 cp = float2(cx + sz * (fx + (b - 0.5) * 0.1), r * 0.55 + float(row) * sz * (0.12 + 0.1 * tall));
            if (j >= 7) { r = sz * 0.07 * (0.7 + 0.6 * a); cp = float2(cx + sz * fx, sz * (0.2 + 0.06 * b)); }   // small bumps on the shoulders
            d = smin(d, length(p - cp) - r, sz * 0.05);
        }
    }
    return max(d, -p.y);
}

static float4 cloudRow(Ctx c, float2 p, float W, float sw, int seed, float haze, float px) {
    float d = cloudSD(p, W, sw, seed);
    if (d > px * 2.0) return 0.0;
    float e = max(px, W * 0.004);
    float dx = cloudSD(p + float2(e, 0.0), W, sw, seed) - d;
    float dy = cloudSD(p + float2(0.0, e), W, sw, seed) - d;
    float2 n = normalize(float2(dx, dy) + 1e-6);
    int s = c.style;
    float2 Ld = s == 1 ? normalize(float2(0.6, -0.45)) : normalize(float2(-0.45, 0.9));
    float ndl = dot(n, Ld);
    // two flat tones with a hard edge; deeper inside a puff counts as turned away (each puff reads as a ball)
    float lit = smoothstep(-0.05, 0.05, ndl + 0.3 + d * 5.0 / W);
    float3 cl, cs, crim, hz;
    if (s == 1) { cl = float3(1.0, 0.70, 0.45); cs = float3(0.52, 0.30, 0.52); crim = float3(1.0, 0.92, 0.62); hz = float3(0.92, 0.55, 0.55); }
    else if (s == 3) { cl = float3(0.60, 0.62, 0.69); cs = float3(0.28, 0.29, 0.37); crim = float3(0.80, 0.82, 0.86); hz = float3(0.50, 0.53, 0.58); }
    else { cl = float3(1.0, 1.0, 0.98); cs = float3(0.67, 0.75, 0.92); crim = float3(1.0, 1.0, 1.0); hz = float3(0.75, 0.86, 0.97); }
    float3 col = mix(cs, cl, lit);
    col = mix(col, crim, smoothstep(-W * 0.03, -W * 0.004, d) * saturate(ndl) * 0.8);
    col *= mix(0.86, 1.0, smoothstep(0.0, W * 0.12, p.y));
    col = mix(col, hz, haze);
    return pm(col, cov(d, px));
}

static float4 anClouds(Ctx c, constant ANU& U) {
    float2 p = c.p;
    float sw = c.r * (U.music.w * 0.12 + U.hits.x * 0.05);
    if (c.style == 2) {
        float2 q = p + float2(c.t * 0.03, 0.0);
        float w = fbm(float2(q.x * 1.6, q.y * 12.0) + fbm(q * 3.0) * 1.5);
        float env = smoothstep(-0.05, 0.08, p.y) * smoothstep(0.5, 0.2, p.y);
        float a = smoothstep(0.52, 0.72, w) * env * 0.6 * (1.0 + sw);
        float3 col = mix(float3(0.86, 0.90, 1.0), float3(1.0), smoothstep(0.6, 0.8, w));
        return pm(col, saturate(a));
    }
    // near row in front of a smaller, hazier far row that drifts slower; sunset clouds are stretched long and flat
    if (c.style == 1) { p.x *= 0.45; }
    float4 acc = cloudRow(c, p + float2(c.t * 0.03, 0.0), 0.62, sw, 0, 0.0, c.px);
    if (acc.a < 0.999) {
        float k = 1.9;
        float2 fp = (p - float2(0.0, 0.07)) * k + float2(c.t * 0.025 - c.panX * 0.5 * k, 0.0);
        acc = under(acc, cloudRow(c, fp, 0.62, sw, 911, 0.35, c.px * k));
    }
    return acc;
}

// ---------------------------------------------------------------- 2 sun & moon

static float4 anSun(Ctx c, constant ANU& U) {
    float2 p = c.p;
    float bass = U.music.x * c.r;
    float d = length(p);
    int s = c.style;
    if (s == 0) {
        float r0 = 0.045 * (1.0 + 0.15 * bass);
        float core = cov(d - r0, c.px);
        float3 g = float3(1.0, 0.92, 0.75) * (0.5 * exp(-max(d - r0, 0.0) / 0.045) + 0.2 * exp(-d / 0.2))
                 * (1.0 + 0.5 * bass + 0.3 * U.hits.w * c.r);
        float ang = atan2(p.y, p.x);
        float rays = pow(abs(cos(ang * 4.0 + c.t * 0.05)), 40.0) * 0.6 + pow(abs(cos(ang * 7.0 - c.t * 0.08 + 1.0)), 80.0) * 0.4;
        g += float3(1.0, 0.95, 0.85) * rays * exp(-d / (0.16 + 0.1 * bass)) * 0.8;
        g += float3(0.7, 0.85, 1.0) * exp(-abs(p.y) / 0.0035) * exp(-abs(p.x) / 0.5) * 0.5;   // anamorphic streak
        // flare ghosts along the line from the sun through the screen's centre
        const float ks[5] = { 0.35, 0.7, 1.15, 1.5, 1.9 };
        const float rs[5] = { 0.012, 0.035, 0.02, 0.06, 0.03 };
        const float3 cs[5] = { float3(0.5, 1.0, 0.6), float3(1.0, 0.6, 0.3), float3(0.6, 0.5, 1.0), float3(0.3, 0.8, 1.0), float3(1.0, 0.4, 0.6) };
        for (int i = 0; i < 5; i++) {
            float dd = length(p - c.c0 * ks[i]);
            float r = rs[i] * (1.0 + 0.3 * bass);
            float ring = smoothstep(r, r * 0.85, dd) * (0.35 + 0.65 * smoothstep(r * 0.5, r, dd));
            g += cs[i] * ring * 0.12;
        }
        return float4(g * (1.0 - core), 0.0) + pm(float3(1.0, 0.99, 0.95), core);
    }
    if (s == 1) {
        float R = 0.26 * (1.0 + 0.06 * bass);
        float3 disc = mix(float3(1.0, 0.16, 0.07), float3(1.0, 0.42, 0.16), saturate(p.y / R * 0.5 + 0.5));
        float a = cov(d - R, c.px);
        float bands = 0.0;
        for (int i = 0; i < 3; i++) {
            float yb = R * (-0.45 + 0.42 * float(i)) + 0.01 * sin(p.x * 6.0 + c.t * 0.1 + float(i));
            float th = R * (0.035 + 0.02 * float(i)) * (0.6 + 0.4 * vnoise(float2(p.x * 8.0 + c.t * 0.05, float(i) * 7.0)));
            bands = max(bands, cov(abs(p.y - yb) - th, c.px));
        }
        disc = mix(disc, float3(0.42, 0.03, 0.05), bands * 0.85);
        float3 halo = float3(1.0, 0.25, 0.1) * (0.35 * exp(-max(d - R, 0.0) / 0.06) + 0.2 * exp(-max(d - R, 0.0) / 0.3)) * (1.0 + 0.6 * bass);
        return pm(disc, a) + float4(halo * (1.0 - a), 0.0);
    }
    float R = 0.075 * (1.0 + 0.05 * bass);
    float a = cov(d - R, c.px);
    float3 m = float3(0.96, 0.95, 0.86);
    float maria = fbm(p / R * 1.3 + 4.0);
    m = mix(m, float3(0.80, 0.80, 0.76), smoothstep(0.5, 0.62, maria) * 0.8);
    float hs = 1.0;
    if (s == 3) { a *= cov(-(length(p - float2(R * 0.45, R * 0.22)) - R * 0.92), c.px); hs = 0.6; }
    float3 halo = float3(0.7, 0.8, 1.0) * (0.25 * exp(-max(d - R, 0.0) / 0.05) + 0.1 * exp(-d / 0.35)) * (1.0 + 0.4 * bass) * hs;
    return pm(m, a) + float4(halo * (1.0 - a), 0.0);
}

// ---------------------------------------------------------------- 3 light rays

static float4 anRays(Ctx c, constant ANU& U) {
    float2 p = c.p;
    int s = c.style;
    float2 o = s == 1 ? float2(0.0) : float2(0.0, 0.75);
    float2 v = p - o;
    float r = length(v);
    float ang = s == 1 ? atan2(v.y, v.x) : atan2(v.x, -v.y);
    float k = s == 1 ? 9.0 : 14.0;
    float tt = c.t * (s == 2 ? 0.25 : 0.06);
    float st = smoothstep(0.42, 0.75, fbm(float2(ang * k + tt, tt * 0.5)));
    if (s == 2) st *= 0.6 + 0.4 * sin(ang * 30.0 + c.t * 1.3);
    float fall = s == 1 ? exp(-r / 0.6) : smoothstep(1.5, 0.1, r);
    float vis = s == 1 ? 1.0 : smoothstep(0.8, 0.2, abs(ang));
    float I = st * fall * vis * (0.55 + 0.6 * U.hits.w * c.r + 0.3 * U.music.w * c.r);
    float3 col = s == 2 ? float3(0.7, 0.95, 1.0) : float3(1.0, 0.92, 0.75);
    return float4(col * I * 0.5, I * 0.1);
}

// ---------------------------------------------------------------- 4 stars

/// A four-point star glint: core, long thin cross, short diagonals.
static float glint(float2 d, float sz, float px) {
    float w = max(px * 0.8, sz * 0.05);
    float cr = exp(-abs(d.x) / w) * exp(-abs(d.y) / sz) + exp(-abs(d.y) / w) * exp(-abs(d.x) / sz);
    float2 r = rot2(d, 0.785398);
    float dg = (exp(-abs(r.x) / w) * exp(-abs(r.y) / (sz * 0.4)) + exp(-abs(r.y) / w) * exp(-abs(r.x) / (sz * 0.4))) * 0.5;
    float core = exp(-length(d) / max(px, sz * 0.08));
    return cr + dg + core;
}

static float3 meteor(float2 p, int seed, float age, float px) {
    const float life = 0.9;
    if (age < 0.0 || age > life) return 0.0;
    float2 s0 = float2(hash1(seed * 3 + 1) * 1.6 - 0.6, 0.12 + 0.3 * hash1(seed * 3 + 2));
    float2 dir = normalize(float2(-0.8 - 0.4 * hash1(seed * 3 + 3), -0.45));
    float2 head = s0 + dir * age * 0.9;
    float len = 0.1 + 0.14 * smoothstep(0.0, 0.3, age);
    float2 tail = head - dir * len;
    float d = sdSeg(p, tail, head);
    float along = saturate(dot(p - tail, dir) / len);
    return float3(1.0, 0.95, 0.85) * exp(-d / max(px, 0.0012)) * along * along * (1.0 - age / life) * 1.4;
}

static float4 anStars(Ctx c, constant ANU& U) {
    float2 p = c.p;
    float3 col = 0.0;
    float tr = U.music.z * c.r;
    float v = dot(p, normalize(float2(0.45, 1.0))), u = dot(p, normalize(float2(1.0, -0.45)));
    float band = c.style == 2 ? exp(-v * v / 0.012) : 0.0;
    // small stars
    const float cs = 0.014;
    float2 cell = floor(p / cs);
    int2 ic = int2(cell);
    float h = hash2(ic);
    if (h > 0.72 - 0.3 * band) {
        float2 sp = (cell + 0.2 + 0.6 * float2(hash2(ic + 5), hash2(ic + 9))) * cs;
        float tw = 0.55 + 0.45 * sin(c.time * (0.8 + 4.0 * hash2(ic + 3)) + h * 60.0);
        tw = saturate(tw + tr * (hash2(ic + 13) > 0.5 ? 0.7 : 0.0));
        float sz = max(c.px * (0.6 + 1.0 * hash2(ic + 17)), 0.0006);
        col += mix(float3(0.75, 0.82, 1.0), float3(1.0, 0.9, 0.8), hash2(ic + 11)) * saturate(1.2 - length(p - sp) / sz) * tw;
    }
    // bright cross-shaped glints
    const float gs = 0.16;
    int2 gc = int2(floor(p / gs));
    for (int j = -1; j <= 1; j++) for (int i = -1; i <= 1; i++) {
        int2 k = gc + int2(i, j);
        float hh = hash2(k + 101);
        if (hh > 0.42) continue;
        float2 sp = (float2(k) + 0.15 + 0.7 * float2(hash2(k + 103), hash2(k + 107))) * gs;
        float tw = saturate((0.5 + 0.5 * sin(c.time * (0.6 + 2.0 * hash2(k + 109)) + hh * 40.0)) * (1.0 + tr));
        float sz = (0.01 + 0.022 * hash2(k + 113)) * (0.6 + 0.4 * tw);
        col += glint(p - sp, sz, c.px) * tw * 0.6 * mix(float3(1.0), float3(0.75, 0.85, 1.0), hash2(k + 117));
    }
    if (c.style == 2) {
        float dust = fbm(float2(u * 2.5, v * 8.0) + 5.0);
        float3 mw = mix(float3(0.35, 0.25, 0.6), float3(0.9, 0.75, 0.95), dust) * band * smoothstep(0.3, 0.8, dust) * 0.6;
        float lane = smoothstep(0.55, 0.7, fbm(float2(u * 4.0, v * 20.0) + 11.0)) * exp(-v * v / 0.002);
        col += mw * (1.0 - 0.8 * lane);
    }
    if (c.style == 1) {
        for (int m = 0; m < 2; m++) {
            float f = c.t / 1.6 + float(m) * 0.5;
            int si = int(floor(f)) * 2 + m;
            if (hash1(si) > 0.55) continue;
            col += meteor(p, si, fract(f) * 1.6, c.px);
        }
        col += meteor(p, int(c.e.y * 100000.0), c.e.x, c.px);
    }
    return float4(col, 0.0);
}

// ---------------------------------------------------------------- 5 mountains

static float ridgeH(float x, int i, int s) {
    float h = 0.0, a = 1.0, fr = 1.2 + float(i) * 0.6;
    for (int o = 0; o < 4; o++) {
        float n = vnoise(float2(x * fr, float(i) * 13.0 + float(o) * 3.7));
        if (s != 2) n = 1.0 - abs(n * 2.0 - 1.0);
        h += a * n; a *= 0.45; fr *= 2.1;
    }
    return h / 1.7;
}

static float4 anMountains(Ctx c, constant ANU& U) {
    float2 p = c.p;
    int s = c.style;
    float3 base, lit, haze;
    if (s == 1) { base = float3(0.28, 0.32, 0.46); lit = float3(0.46, 0.52, 0.66); haze = float3(0.72, 0.80, 0.93); }
    else if (s == 2) { base = float3(0.20, 0.42, 0.22); lit = float3(0.42, 0.63, 0.30); haze = float3(0.66, 0.80, 0.86); }
    else if (s == 3) { base = float3(0.10, 0.06, 0.16); lit = float3(0.24, 0.13, 0.27); haze = float3(0.80, 0.46, 0.55); }
    else { base = float3(0.24, 0.36, 0.62); lit = float3(0.42, 0.56, 0.80); haze = float3(0.72, 0.84, 0.96); }
    float4 acc = 0.0;
    for (int i = 3; i >= 0; i--) {
        float near = float(i) / 3.0;
        float x = p.x + c.panX * (0.45 + 0.55 * near - 1.0);
        float amp = (s == 2 ? 0.07 : 0.17) * (1.1 - 0.35 * near);
        float y0 = 0.015 - 0.04 * near;
        float top = y0 + amp * ridgeH(x, i, s);
        float a = cov(p.y - top, c.px);
        if (a <= 0.0) continue;
        // lit faces: the ridge's slope, carried down the mountainside on a slant (gullies); flat further down
        float faceK = smoothstep(top - 0.22, top - 0.06, p.y);
        float litF = 0.0;
        if (faceK > 0.0) {
            float xs = x - (top - p.y) * 0.55 + (fbm(p * float2(30.0, 14.0) + float(i)) - 0.5) * 0.012;
            float e = 0.004;
            litF = smoothstep(-0.002, 0.002, ridgeH(xs + e, i, s) - ridgeH(xs - e, i, s));
        }
        float sl = litF * 2.0 - 1.0;
        float3 col = mix(base, lit, litF * faceK);
        if (s == 1) {
            float snowline = top - 0.03 - 0.05 * vnoise(float2(x * 18.0, float(i)));
            if (p.y > snowline && top > y0 + amp * 0.45)
                col = mix(float3(0.66, 0.74, 0.90), float3(0.97, 0.98, 1.0), smoothstep(-0.5, 0.5, sl));
        }
        // mist rising from the valleys, and the farther, the hazier
        col = mix(col, haze, smoothstep(top - 0.02, top - 0.16, p.y) * 0.35 * (1.0 - 0.5 * near));
        col = mix(col, haze, (1.0 - near) * 0.62);
        acc = under(acc, pm(col, a));
        if (acc.a > 0.995) break;
    }
    return acc;
}

// ---------------------------------------------------------------- 6 meadow

static float3 flowerCol(int s, float h) {
    if (s == 2) return float3(0.92, 0.22, 0.15);
    if (s == 3) return float3(0.75, 0.80, 0.95);
    if (s == 1) return h < 0.5 ? float3(0.98, 0.97, 0.92) : float3(1.0, 0.86, 0.35);
    return h < 0.4 ? float3(0.62, 0.42, 0.86) : h < 0.65 ? float3(0.80, 0.64, 0.96) : h < 0.85 ? float3(0.98, 0.97, 1.0) : float3(1.0, 0.66, 0.80);
}

static float4 anMeadow(Ctx c, constant ANU& U) {
    float2 pg = c.pg;
    int s = c.style;
    const float H = 0.25;
    float wind = 0.35 + c.r * U.time.y;
    float3 nearC, farC, sheenC, hazeC, bladeA, bladeB;
    if (s == 1) { nearC = float3(0.20, 0.45, 0.16); farC = float3(0.55, 0.72, 0.40); sheenC = float3(0.78, 0.88, 0.55); hazeC = float3(0.74, 0.86, 0.90); bladeA = float3(0.08, 0.24, 0.07); bladeB = float3(0.30, 0.52, 0.18); }
    else if (s == 2) { nearC = float3(0.72, 0.50, 0.20); farC = float3(0.88, 0.74, 0.42); sheenC = float3(1.0, 0.92, 0.62); hazeC = float3(0.98, 0.86, 0.70); bladeA = float3(0.45, 0.28, 0.08); bladeB = float3(0.85, 0.66, 0.30); }
    else if (s == 3) { nearC = float3(0.04, 0.10, 0.10); farC = float3(0.09, 0.15, 0.24); sheenC = float3(0.30, 0.42, 0.62); hazeC = float3(0.10, 0.15, 0.30); bladeA = float3(0.01, 0.04, 0.05); bladeB = float3(0.06, 0.12, 0.16); }
    else { nearC = float3(0.22, 0.55, 0.18); farC = float3(0.62, 0.78, 0.45); sheenC = float3(0.82, 0.93, 0.58); hazeC = float3(0.78, 0.88, 0.95); bladeA = float3(0.10, 0.32, 0.08); bladeB = float3(0.36, 0.62, 0.20); }

    float4 acc = 0.0;
    // blades in front, rooted below the bottom edge, rushing by when the camera pans
    float bx = pg.x + c.panX * 2.2;
    const float slotW = 0.009;
    float hmax = s == 1 ? 0.3 : 0.15;
    int bi = int(floor(bx / slotW));
    float bladeA_ = 0.0, bladeV = 0.0;
    for (int k = -6; k <= 6; k++) {
        int bk = bi + k;
        if (hash1(bk * 3 + 7) > 0.6) continue;
        float rx = (float(bk) + hash1(bk * 3 + 9)) * slotW;
        float h = hmax * (0.35 + 0.65 * hash1(bk * 3 + 11));
        float v = (pg.y + 0.57) / h;
        if (v < 0.0 || v > 1.0) continue;
        float lean = (hash1(bk * 5 + 1) - 0.5) * 0.05 + wind * 0.045 * (0.6 + 0.4 * sin(U.time.z * 2.3 + rx * 9.0));
        float cx = rx + lean * v * v * (h / 0.15);
        float w = 0.0032 * (1.0 - v) + c.px * 0.3;
        float a = cov(abs(bx - cx) - w, c.px);
        if (a > bladeA_) { bladeA_ = a; bladeV = v; }
    }
    if (bladeA_ > 0.0) acc = pm(mix(bladeA, bladeB, bladeV), bladeA_);
    if (acc.a > 0.995) return acc;

    float yh = 0.008 * (vnoise(float2((pg.x + c.panX * 0.05) * 3.0, 1.0)) - 0.5);
    float dy = yh - pg.y;
    if (dy <= -c.px) return acc;
    float z = H / max(dy, 1e-4);
    float X = pg.x * z + c.panX, Z = z;
    float fpX = c.px * z, fpZ = c.px * z * z / H;
    float far = saturate((z - 1.0) / 8.0);
    float3 col = mix(nearC, farC, pow(far, 0.6));
    float n1 = vnoise(float2(X * 9.0, Z * 2.2));
    float n2 = vnoise(float2(X * 31.0, Z * 7.0) + 7.0);
    float det1 = 1.0 - smoothstep(0.08, 0.3, fpZ * 2.2 + fpX * 9.0);
    float det2 = 1.0 - smoothstep(0.08, 0.3, fpZ * 7.0 + fpX * 31.0);
    col *= 1.0 + (n1 - 0.5) * 0.28 * det1 + (n2 - 0.5) * 0.22 * det2;
    // cloud shadows drifting over the field
    col *= 1.0 - 0.22 * smoothstep(0.5, 0.6, fbm(float2(X * 0.25 - U.time.z * 0.03, Z * 0.25)));
    // wind waves: pale bands where the grass bends and shows its light side
    float wv = sin(X * 1.6 + Z * 0.9 - U.time.z * 1.8 + fbm(float2(X, Z) * 0.6) * 4.0);
    col = mix(col, sheenC, smoothstep(0.35, 0.95, wv) * (0.2 + 0.5 * wind) * 0.5 * (1.0 - far * 0.5));
    // flowers
    float dens = s == 0 ? 0.75 : s == 1 ? 0.22 : s == 2 ? 0.15 : 0.35;
    const float cw = 0.16;
    float2 W2 = float2(X, Z);
    float patch = smoothstep(0.3, 0.65, vnoise(W2 * 0.35 + 3.0));
    if (fpX < cw * 0.35) {
        int2 fc = int2(floor(W2 / cw));
        for (int j = -1; j <= 1; j++) for (int i = -1; i <= 1; i++) {
            int2 k = fc + int2(i, j);
            float hh = hash2(k + 31);
            float2 fw = (float2(k) + 0.2 + 0.6 * float2(hash2(k + 33), hash2(k + 37))) * cw;
            if (hh > dens * smoothstep(0.3, 0.65, vnoise(fw * 0.35 + 3.0))) continue;
            float zf = fw.y;
            if (zf < 0.3) continue;
            float2 sp = float2((fw.x - c.panX) / zf + 0.004 * wind * sin(U.time.z * 2.0 + fw.x * 5.0) / zf, yh - H / zf);
            float r = 0.016 / zf;
            float2 fd = (pg - sp) * float2(1.0, 1.6);
            float dd = length(fd);
            float pr = r * (0.72 + 0.28 * cos(5.0 * atan2(fd.y, fd.x) + hh * 20.0));   // five petals
            float fa = cov(dd - pr, c.px) * saturate(r / (c.px * 0.8));
            float3 fcol = flowerCol(s, hash2(k + 41));
            fcol *= 0.85 + 0.15 * saturate(fd.y / r + 0.5);
            fcol = mix(fcol, float3(1.0, 0.88, 0.4), cov(dd - r * 0.25, c.px) * 0.8);
            col = mix(col, fcol, fa);
        }
    } else {
        col = mix(col, flowerCol(s, 0.3), patch * dens * 0.25 * (1.0 - far));
    }
    col = mix(col, hazeC, smoothstep(2.0, 30.0, z) * 0.5);
    return under(acc, pm(col, cov(-dy, c.px)));
}

// ---------------------------------------------------------------- 7 tree line

static float4 bamboo(Ctx c, constant ANU& U, float wind) {
    float2 p = c.p;
    float4 acc = 0.0;
    const float slot = 0.06;
    float x = p.x;
    int si = int(floor(x / slot));
    for (int k = -2; k <= 2; k++) {
        int sk = si + k;
        if (hash1(sk * 5 + 1) > 0.75) continue;
        float w = 0.006 + 0.004 * hash1(sk * 5 + 2);
        float base = (float(sk) + 0.5 + (hash1(sk * 5 + 3) - 0.5) * 0.6) * slot;
        float swayA = wind * 0.03 * (0.8 + 0.4 * hash1(sk * 5 + 4)) * sin(U.time.z * 1.4 + float(sk) * 1.7) + 0.01 * (hash1(sk * 5 + 6) - 0.5);
        float yy = p.y + 0.6;
        float cx = base + swayA * yy * yy;
        float dx = x - cx;
        // stalk with nodes
        float a = cov(abs(dx) - w, c.px);
        float4 col = 0.0;
        if (a > 0.0) {
            float off = hash1(sk * 5 + 7) * 0.09;
            float node = fract((p.y + off) / 0.09);
            float3 sc = mix(float3(0.30, 0.56, 0.28), float3(0.52, 0.76, 0.40), smoothstep(0.0, -w * 0.6, dx));
            sc = mix(sc, float3(0.17, 0.33, 0.16), smoothstep(w * 0.3, w, dx));
            sc *= node < 0.04 || node > 0.985 ? 0.65 : 1.0;
            col = pm(sc, a);
        }
        // leaves at the nodes, hanging out to one side
        int nj = int(floor((p.y + 0.6) / 0.09));
        for (int j = -1; j <= 1; j++) {
            int n = nj + j;
            int hs = sk * 131 + n * 17;
            if (hash1(hs) > 0.45 || n < 2) continue;
            float ny = float(n) * 0.09 - 0.6;
            float side = hash1(hs + 1) > 0.5 ? 1.0 : -1.0;
            float2 o = float2(base + swayA * (ny + 0.6) * (ny + 0.6), ny);
            for (int l = 0; l < 3; l++) {
                float ang = -0.35 - 0.45 * float(l) + 0.15 * sin(U.time.z * 2.0 + float(hs + l)) * wind;
                float2 dir = float2(cos(ang) * side, sin(ang));
                float2 q = p - o;
                float u = dot(q, dir);
                float vv = dot(q, float2(-dir.y, dir.x));
                float L = 0.055 + 0.02 * hash1(hs + l + 3);
                if (u < 0.0 || u > L) continue;
                float lw = 0.007 * sin(PI * u / L);
                float la = cov(abs(vv) - lw, c.px);
                float3 lc = mix(float3(0.22, 0.45, 0.20), float3(0.45, 0.70, 0.32), step(0.0, vv * side));
                col = under(pm(lc, la), col);
            }
        }
        acc = under(acc, col);
        if (acc.a > 0.995) break;
    }
    return acc;
}

static float4 anTrees(Ctx c, constant ANU& U) {
    float2 p = c.p;
    int s = c.style;
    float wind = 0.35 + c.r * U.time.y;
    if (s == 2) return bamboo(c, U, wind);
    float4 acc = 0.0;
    for (int row = 0; row < 2; row++) {
        float sc = row == 0 ? 1.0 : 0.62;
        float x = p.x + c.panX * (row == 0 ? 0.0 : -0.35) + float(row) * 0.013;
        float y = p.y - (row == 0 ? 0.0 : 0.012);
        float slot = (s == 0 ? 0.034 : 0.07) * sc;
        int si = int(floor(x / slot));
        float best = 0.0;
        float3 bc = 0.0;
        for (int k = -2; k <= 2; k++) {
            int tk = si + k + row * 1000;
            float cx = (float(si + k) + 0.5 + (hash1(tk * 3 + 1) - 0.5) * 0.6) * slot;
            float h = (s == 0 ? 0.11 : 0.085) * sc * (0.6 + 0.7 * hash1(tk * 3 + 2));
            float v = y / h;
            if (v > 1.3) continue;
            float sway = wind * 0.012 * sc * sin(U.time.z * 1.7 + cx * 13.0) * saturate(v) * saturate(v);
            float lx = x - cx - sway;
            float d;
            float3 col;
            if (s == 0) {
                float tier = fract(v * 4.0 + hash1(tk) * 0.5);
                float wv = (1.0 - v) * h * 0.36 * (0.72 + 0.28 * tier);
                wv *= 0.9 + 0.2 * vnoise(float2(y * 300.0, float(tk)));
                d = max(max(abs(lx) - wv, y - h), -y - 0.05);
                bool litSide = lx < (vnoise(float2(y * 120.0, float(tk))) - 0.6) * wv;
                col = row == 0 ? (litSide ? float3(0.22, 0.45, 0.28) : float3(0.09, 0.26, 0.19))
                               : (litSide ? float3(0.42, 0.60, 0.58) : float3(0.30, 0.48, 0.50));
            } else {
                float2 q = float2(lx, y);
                float r = h * 0.32;
                float dc = length(q - float2(0.0, h * 0.62)) - r;
                dc = smin(dc, length(q - float2(-r * 0.75, h * 0.45)) - r * 0.8, r * 0.3);
                dc = smin(dc, length(q - float2(r * 0.8, h * 0.48)) - r * 0.75, r * 0.3);
                dc = smin(dc, length(q - float2(r * 0.1, h * 0.88)) - r * 0.7, r * 0.3);
                float trunk = sdBox(q - float2(0.0, h * 0.15), float2(h * 0.04, h * 0.2));
                d = min(dc, trunk);
                d = max(d, -y - 0.05);
                float2 n = normalize(q - float2(0.0, h * 0.62) + 1e-5);
                float litF = step(0.15, dot(n, normalize(float2(-0.6, 0.8))) + 0.15 * vnoise(q * 300.0));
                col = dc < trunk ? (row == 0 ? mix(float3(0.12, 0.32, 0.14), float3(0.32, 0.56, 0.22), litF)
                                             : mix(float3(0.30, 0.48, 0.42), float3(0.45, 0.62, 0.50), litF))
                                 : float3(0.22, 0.16, 0.12);
            }
            float a = cov(d, c.px);
            if (a > best) { best = a; bc = col; }
        }
        // the ground strip under the trees
        float ga = cov(y, c.px) * cov(-y - 0.05, c.px);
        if (ga > best) { best = ga; bc = row == 0 ? float3(0.08, 0.22, 0.13) : float3(0.28, 0.45, 0.45); }
        acc = under(acc, pm(bc, best));
        if (acc.a > 0.995) break;
    }
    return acc;
}

// ---------------------------------------------------------------- 8 water

static float4 anWater(Ctx c, constant ANU& U) {
    int s = c.style;
    float tr = U.music.z * c.r;
    if (s == 1) {
        float2 p = c.p;
        float2 q = p + float2(c.t * 0.02, c.t * 0.008);
        float3 col = mix(float3(0.36, 0.58, 0.62), float3(0.55, 0.72, 0.70), fbm(q * 1.5));
        float caus = fbm(q * 6.0 + float2(c.t * 0.1, 0.0));
        col += 0.07 * pow(1.0 - abs(sin(caus * 9.0)), 6.0);
        const float rowH = 0.045;
        int ri = int(floor(q.y / rowH));
        float hi = 0.0, sh = 0.0;
        for (int j = -1; j <= 1; j++) {
            int r = ri + j;
            float yc = (float(r) + 0.5) * rowH + 0.02 * (hash1(r) - 0.5);
            float x = q.x + c.t * (0.03 + 0.04 * hash1(r + 3));
            const float segW = 0.35;
            int sx = int(floor(x / segW));
            for (int k = -1; k <= 1; k++) {
                int sk = sx + k;
                int hs = sk * 17 + r * 131;
                float hh = hash1(hs);
                if (hh > 0.3 + 0.25 * tr) continue;
                float cx = (float(sk) + 0.5 + (hash1(hs + 4) - 0.5) * 0.5) * segW;
                float len = segW * (0.15 + 0.4 * hash1(hs + 1));
                float dx = (x - cx) / len;
                if (abs(dx) > 1.0) continue;
                float yy = q.y - yc - 0.01 * sin(dx * (3.0 + 4.0 * hash1(hs + 5)) + c.t * 1.5 + hh * 10.0) - 0.008 * dx * (hash1(hs + 6) - 0.5);
                float w = rowH * 0.14 * (0.5 + 0.9 * hash1(hs + 2)) * (1.0 - dx * dx) * (0.55 + 0.9 * vnoise(float2(x * 40.0, float(hs))));
                hi = max(hi, cov(abs(yy) - w, c.px));
                sh = max(sh, cov(abs(yy + 0.012) - w * 1.1, c.px));
            }
        }
        col = mix(col, col * float3(0.62, 0.76, 0.82), sh * 0.7);
        col = mix(col, float3(0.97, 1.0, 1.0), hi * (0.85 + 0.15 * tr));
        return float4(col, 1.0);
    }
    float2 pg = c.pg;
    const float H = 0.25;
    float dy = -pg.y;
    if (dy <= -c.px) return 0.0;
    float z = H / max(dy, 1e-4);
    float X = pg.x * z + c.panX, Z = z;
    float fpZ = c.px * z * z / H;
    float far = pow(saturate((z - 0.5) / 12.0), 0.5);
    float3 col = s == 2 ? mix(float3(0.02, 0.05, 0.12), float3(0.08, 0.12, 0.26), far)
                        : mix(float3(0.06, 0.30, 0.58), float3(0.52, 0.74, 0.90), far);
    col *= 1.0 + 0.08 * (vnoise(float2(X * 3.0, Z * 12.0) + c.t * 0.2) - 0.5);
    // the glitter path down the middle
    float path = exp(-pg.x * pg.x / pow(0.03 + 0.06 * dy * 4.0, 2.0));
    float dens = (s == 2 ? 0.05 : 0.22) + 0.35 * tr + 0.6 * path;
    float3 gc = s == 2 ? float3(1.0, 0.95, 0.80) : mix(float3(0.92, 0.97, 1.0), float3(1.0, 0.95, 0.80), path);
    const float2 csz = float2(0.4, 0.07);
    float2 g = float2(X, Z) / csz;
    int2 gi = int2(floor(g));
    float hi = 0.0;
    for (int j = -1; j <= 1; j++) for (int i = -1; i <= 1; i++) {
        int2 k = gi + int2(i, j);
        if (hash2(k) > dens) continue;
        float2 ctr = (float2(k) + 0.5 + (float2(hash2(k + 3), hash2(k + 7)) - 0.5) * 0.6) * csz;
        float len = csz.x * (0.15 + 0.4 * hash2(k + 11));
        float th = csz.y * 0.1;
        float on = sin(PI * fract(c.time * (0.5 + hash2(k + 13)) + hash2(k + 17)));
        float dx = (X - ctr.x - c.t * 0.04) / len, dz = (Z - ctr.y) / th;
        float r = length(float2(dx, dz));
        float edge = max(fpZ / th, 0.08);
        hi = max(hi, saturate((1.0 - r) / edge + 0.5) * saturate(th / fpZ) * on);
    }
    col = mix(col, gc, hi * (0.85 + 0.15 * tr));
    col += (s == 2 ? 0.05 : 0.18) * exp(-dy / 0.003);
    return pm(col, cov(-dy, c.px));
}

// ---------------------------------------------------------------- 9 town

static float wires(float2 p, float x0, float x1, float y0, float y1, float sag, float px) {
    float u = (p.x - x0) / (x1 - x0);
    if (u < 0.0 || u > 1.0) return 0.0;
    float y = mix(y0, y1, u) - sag * 4.0 * u * (1.0 - u);
    return cov(abs(p.y - y) - max(0.0006, px * 0.35), px);
}

/// Utility poles every `gap` with sagging wires between them; `top` = height above `base`.
static float poles(float2 p, float base, float top, float gap, float w, float px, float wind, float t) {
    int pi = int(floor(p.x / gap));
    float a = 0.0;
    for (int k = -1; k <= 1; k++) {
        int pk = pi + k;
        float x = (float(pk) + 0.3 * hash1(pk * 7)) * gap;
        float h = top * (0.9 + 0.2 * hash1(pk * 7 + 1));
        a = max(a, cov(sdBox(p - float2(x, base + h * 0.5), float2(w, h * 0.5)), px));
        a = max(a, cov(sdBox(p - float2(x, base + h * 0.94), float2(w * 9.0, w * 0.7)), px));
        a = max(a, cov(sdBox(p - float2(x, base + h * 0.82), float2(w * 6.0, w * 0.6)), px));
        if (k < 1) {
            int nk = pk + 1;
            float xn = (float(nk) + 0.3 * hash1(nk * 7)) * gap;
            float hn = top * (0.9 + 0.2 * hash1(nk * 7 + 1));
            float sway = 0.002 * wind * sin(t * 1.3 + float(pk));
            for (int wi = 0; wi < 4; wi++) {
                float off = (float(wi) - 1.5) * w * 5.0;
                float yy = wi < 2 ? 0.94 : 0.82;
                a = max(a, wires(p, x + off, xn + off, base + h * yy + w, base + hn * yy + w, gap * (0.05 + 0.01 * float(wi)) + sway, px));
            }
        }
    }
    return a;
}

static float4 anTown(Ctx c, constant ANU& U) {
    float2 p = c.p;
    int s = c.style;
    float wind = 0.35 + c.r * U.time.y;
    float loud = U.music.w * c.r;
    if (s == 1) {
        float a = poles(p, -0.6, 1.05, 0.95, 0.009, c.px, wind, U.time.z);
        return pm(float3(0.05, 0.05, 0.08), a);
    }
    if (s == 2) {
        const float slot = 0.028;
        int b = int(floor(p.x / slot));
        float h = (0.02 + 0.09 * pow(hash1(b * 3 + 1), 2.0)) * (0.85 + 0.35 * bandOf(U, int(hash1(b * 3 + 2) * 16.0)) * c.r);
        float w = slot * (0.35 + 0.15 * hash1(b * 3 + 4));
        float cx = (float(b) + 0.5) * slot;
        float a = cov(max(abs(p.x - cx) - w, p.y - h), c.px);
        float4 acc = 0.0;
        if (a > 0.0) {
            float3 col = float3(0.30, 0.33, 0.45);
            float2 wc = float2((p.x - cx) / 0.0045, p.y / 0.006);
            int2 wi = int2(floor(wc));
            float2 wf = fract(wc);
            if (abs(p.x - cx) < w - 0.002 && p.y < h - 0.004 && wf.x > 0.35 && wf.y > 0.35
                && hash2(wi + int2(b * 17, 0)) < 0.25 + 0.5 * loud) col = float3(1.0, 0.86, 0.55);
            acc = pm(col, a);
        }
        // red aircraft lights blinking on the taller towers
        if (hash1(b * 3 + 5) > 0.7 && fract(c.time * 0.8 + hash1(b)) < 0.5)
            acc = under(pm(float3(1.0, 0.2, 0.15), cov(length(p - float2(cx, h + 0.003)) - max(0.0015, c.px), c.px)), acc);
        // the lower town in front
        return under(pm(float3(0.22, 0.24, 0.34), cov(p.y + 0.005, c.px)), acc);
    }
    // rows of rooftops with lit windows stepping down towards the viewer (seen from a hill), poles and wires
    // above the far row
    float4 acc = 0.0;
    for (int row = 2; row >= 0; row--) {
        // row 0 = the far row on the horizon (with the poles); 1, 2 = nearer, bigger, lower, darker
        float rs = row == 0 ? 1.0 : row == 1 ? 1.6 : 2.6;
        float rowY = row == 0 ? 0.0 : row == 1 ? -0.17 : -0.42;
        float2 rp = float2(p.x + c.panX * (rs - 1.0) + float(row) * 0.37, p.y - rowY) / rs;
        float px = c.px / rs;
        const float slot = 0.085;
        int si = int(floor(rp.x / slot));
        float best = 0.0;
        float3 bc = 0.0;
        for (int k = -1; k <= 1; k++) {
            int b = si + k + row * 5000;
            if (row > 0 && hash1(b * 5 + 10) < 0.2) continue;
            if (hash1(b * 5 + 9) < 0.15) continue;   // gaps between the houses
            float cx = (float(si + k) + 0.5 + (hash1(b * 5 + 8) - 0.5) * 0.3) * slot;
            float w = slot * (0.28 + 0.2 * hash1(b * 5 + 1));
            float h = 0.035 + 0.075 * pow(hash1(b * 5 + 2), 1.5);
            bool gable = hash1(b * 5 + 3) > 0.45;
            float2 q = rp - float2(cx, 0.0);
            float body = sdBox(q - float2(0.0, h * 0.5 - 0.05), float2(w, h * 0.5 + 0.05));
            float roof = gable ? sdTri(q, float2(-w * 1.15, h), float2(w * 1.15, h), float2(0.0, h + w * 0.5)) : 1e3;
            float tank = !gable && hash1(b * 5 + 4) > 0.5 ? sdBox(q - float2(w * 0.4, h + 0.012), float2(0.008, 0.012)) : 1e3;
            float d = min(body, min(roof, tank));
            float a = cov(d, px);
            if (a <= best) continue;
            float3 col = row == 0 ? float3(0.24, 0.19, 0.32) : row == 1 ? float3(0.16, 0.13, 0.24) : float3(0.09, 0.07, 0.15);
            if (roof < 0.0 || tank < 0.0) col *= 0.7;
            if (d > -0.003 && q.y > h - 0.002) col = mix(col, float3(0.62, 0.42, 0.46), 0.7);   // rim light along the roofs
            float2 wc = float2(q.x / 0.014, q.y / 0.016);
            int2 wi = int2(floor(wc));
            float2 wf = fract(wc);
            if (body < -0.004 && q.y > 0.004 && q.y < h - 0.006 && wf.x > 0.3 && wf.x < 0.72 && wf.y > 0.3 && wf.y < 0.75) {
                float on = hash2(wi + int2(b * 37, 11));
                col = on < 0.25 + 0.4 * loud ? float3(1.0, 0.80, 0.45) : col * 1.25;
            }
            best = a; bc = col;
        }
        float ga = cov(rp.y + 0.02, px);   // the blocks under the row's roofs
        if (ga > best) { best = ga; bc = row == 0 ? float3(0.19, 0.15, 0.27) : row == 1 ? float3(0.12, 0.10, 0.19) : float3(0.07, 0.05, 0.12); }
        // the poles stand in front of the far row, behind the nearer ones
        if (row == 0) acc = under(acc, pm(float3(0.04, 0.035, 0.07), poles(p, 0.0, 0.36, 0.5, 0.0035, c.px, wind, U.time.z)));
        acc = under(acc, pm(bc, best));
        if (acc.a > 0.995) break;
    }
    return acc;
}

// ---------------------------------------------------------------- 10 particles

static float4 anParticles(Ctx c, constant ANU& U) {
    int s = c.style;
    float4 acc = 0.0;
    float3 light = 0.0;
    float dens = saturate((s == 3 ? 0.75 : s == 2 ? 0.55 : s == 4 ? 0.28 : s == 5 ? 0.35 : 0.33) * (0.75 + 0.6 * c.r * U.music.w));
    for (int L = 2; L >= 0; L--) {
        float k = L == 0 ? 0.55 : L == 1 ? 1.0 : 1.9;
        float cs = (s == 3 ? 0.045 : 0.075) * k;
        float fall = (s == 2 ? 0.05 : s == 3 ? 1.1 : s == 0 ? 0.07 : s == 1 ? 0.09 : s == 5 ? -0.01 : 0.0) * k;
        float drift = s == 3 ? 0.3 : s >= 4 ? 0.03 : 0.12;
        float2 q = c.p + float2(c.panX * (k - 1.0), 0.0) - float2(U.time.z * drift * k + c.t * 0.01, -fall * c.t);
        int2 ci = int2(floor(q / cs));
        for (int j = -1; j <= 1; j++) for (int i = -1; i <= 1; i++) {
            int2 kk = ci + int2(i, j);
            int2 hk = kk + int2(L * 977, L * 613);
            float h = hash2(hk);
            if (h > dens) continue;
            float ph = hash2(hk + 7) * TAU;
            float2 base = (float2(kk) + 0.5 + (float2(hash2(hk + 3), hash2(hk + 5)) - 0.5) * 0.5) * cs;
            float amp = s == 4 ? 0.35 : s == 3 ? 0.0 : 0.18;
            float2 sw = float2(sin(c.t * 1.3 * (s == 4 ? 0.4 : 1.0) + ph), cos(c.t * 0.9 * (s == 4 ? 0.4 : 1.0) + ph * 1.3)) * cs * amp;
            float2 d = q - base - sw;
            float size = cs * (0.12 + 0.08 * hash2(hk + 9));
            float blur = c.px + (L == 2 ? size * 0.35 : 0.0);
            float fade = L == 0 ? 0.65 : 1.0;
            if (s == 0 || s == 1) {
                float a = ph + c.t * (0.8 + h);
                float flip = cos(c.t * (1.5 + 2.0 * h) + ph);
                float2 r = rot2(d, a);
                r.x /= max(abs(flip), 0.25);
                float dd;
                float3 col;
                if (s == 0) {
                    dd = length(r * float2(1.0, 1.6)) - size;
                    dd = max(dd, -(length((r - float2(size * 1.05, 0.0)) * float2(1.0, 2.5)) - size * 0.3));
                    col = mix(float3(1.0, 0.82, 0.88), float3(0.95, 0.60, 0.72), saturate(-r.x / size * 0.5 + 0.5));
                } else {
                    dd = length(r * float2(1.0, 2.4)) - size * 1.15;
                    float pick = hash2(hk + 21);
                    col = pick < 0.3 ? float3(0.95, 0.55, 0.15) : pick < 0.55 ? float3(0.85, 0.22, 0.12) : pick < 0.8 ? float3(0.98, 0.80, 0.25) : float3(0.60, 0.35, 0.15);
                    col *= 1.0 - 0.3 * cov(abs(r.y) - c.px * 0.4, c.px) * step(abs(r.x), size);
                }
                col *= flip > 0.0 ? 1.0 : 0.82;
                acc = under(acc, pm(col, cov(dd, blur) * fade));
            } else if (s == 2) {
                float dd = length(d) - size * 0.55;
                acc = under(acc, pm(float3(0.97, 0.98, 1.0), cov(dd, blur + size * 0.15) * fade * 0.95));
            } else if (s == 3) {
                float2 dir = normalize(float2(U.time.y * drift * 0.6 + 0.05, -1.1));
                float dd = sdSeg(d, -dir * size * 3.0, dir * size * 3.0) - max(c.px * 0.35, size * 0.04);
                acc = under(acc, pm(float3(0.80, 0.86, 0.96), cov(dd, blur) * 0.45 * fade));
            } else if (s == 4) {
                float blink = smoothstep(0.2, 1.0, sin(c.t * (1.0 + h) * 2.0 + ph));
                float g = exp(-length(d) / (size * 0.35));
                light += float3(0.85, 1.0, 0.45) * g * blink * 1.2 * fade;
            } else {
                float tw = 0.5 + 0.5 * sin(c.time * (2.0 + 3.0 * h) + ph);
                float g = exp(-length(d) / max(size * 0.12, c.px * 0.8));
                light += float3(1.0, 0.93, 0.78) * g * tw * 0.8 * fade;
            }
        }
    }
    return acc + float4(light * (1.0 - acc.a), 0.0);
}

// ---------------------------------------------------------------- 11 sparkles

static float4 anSparkles(Ctx c, constant ANU& U) {
    float2 p = c.p;
    int s = c.style;
    float boost = c.r * (U.hits.z + 0.5 * U.music.z);
    if (s == 0) {
        float3 col = 0.0;
        const float gs = 0.11;
        int2 gc = int2(floor(p / gs));
        for (int j = -1; j <= 1; j++) for (int i = -1; i <= 1; i++) {
            int2 k = gc + int2(i, j);
            float h = hash2(k + 51);
            float ph = fract(c.t * 0.35 + h);
            float win = 0.3 + 0.3 * boost;
            if (ph > win || hash2(k + 53) > 0.6) continue;
            float on = sin(PI * ph / win);
            float2 sp = (float2(k) + 0.15 + 0.7 * float2(hash2(k + 55), hash2(k + 57))) * gs;
            float sz = (0.012 + 0.03 * hash2(k + 59)) * on * (1.0 + 0.5 * boost);
            float3 tint = mix(float3(1.0), float3(1.0, 0.85, 0.95), hash2(k + 61));
            col += glint(p - sp, sz, c.px) * on * tint;
        }
        return float4(col, 0.0);
    }
    if (s == 1) {
        float4 acc = 0.0;
        const float gs = 0.17;
        float2 q = p - float2(0.0, c.t * 0.02);
        int2 gc = int2(floor(q / gs));
        for (int j = -1; j <= 1; j++) for (int i = -1; i <= 1; i++) {
            int2 k = gc + int2(i, j);
            if (hash2(k + 71) > 0.55) continue;
            float2 sp = (float2(k) + 0.2 + 0.6 * float2(hash2(k + 73), hash2(k + 75))) * gs;
            sp += float2(sin(c.t * 0.3 + hash2(k) * 6.0), cos(c.t * 0.25 + hash2(k + 1) * 6.0)) * 0.02;
            float r = 0.02 + 0.045 * hash2(k + 77);
            float d = length(q - sp);
            float a = saturate((r - d) / (r * 0.08 + c.px)) * (0.6 + 0.4 * smoothstep(r * 0.6, r, d));
            float pick = hash2(k + 79);
            float3 col = pick < 0.33 ? float3(1.0, 0.72, 0.86) : pick < 0.66 ? float3(0.62, 0.90, 1.0) : float3(1.0, 0.95, 0.62);
            float I = a * (0.16 + 0.12 * U.hits.x * c.r);
            acc += float4(col * I, I * 0.25);
        }
        return acc;
    }
    float f = fbm(p * 0.7 + float2(c.t * 0.04, -c.t * 0.02));
    float edge = smoothstep(0.15, 0.95, abs(p.x) / max(c.asp * 0.5, 0.1));
    float leak = smoothstep(0.42, 0.85, f) * (0.35 + 0.65 * edge);
    float3 col = mix(float3(1.0, 0.42, 0.2), float3(1.0, 0.78, 0.5), f) * leak * 0.7 * (1.0 + 0.5 * U.music.w * c.r);
    return float4(col, 0.0);
}

// ---------------------------------------------------------------- 12 speed lines

static float4 anSpeedLines(Ctx c, constant ANU& U) {
    int s = c.style;
    float push = saturate(U.hits.x * 1.2 + U.music.w * 0.5 + U.hits.w * 0.3);
    float vis = mix(1.0, push, c.r);
    if (vis < 0.01) return 0.0;
    int fr = int(c.seed);
    float2 p = c.p;
    if (s <= 1) {
        float r = length(p);
        float ang = atan2(p.y, p.x);
        const float N = 220.0;
        float slot = floor((ang / TAU + 0.5) * N);
        float a = 0.0;
        for (int k = -1; k <= 1; k++) {
            float sl = slot + float(k);
            int si = int(sl) - int(floor(sl / N)) * int(N);
            int hs = si * 7 + fr * 131;
            if (hash1(hs) > 0.55) continue;
            float a0 = ((sl + 0.5 + (hash1(hs + 1) - 0.5) * 0.8) / N - 0.5) * TAU;
            float clear = mix(0.42, 0.2, push * c.r) * (0.85 + 0.5 * hash1(hs + 2));
            float wid = (0.6 + 1.6 * hash1(hs + 3)) * (TAU / N) * 0.5;
            float da = abs(wrapPi(ang - a0));
            float taper = saturate((r - clear) / 0.35);
            float d = da * r - wid * r * taper;
            if (r < clear) d = 1.0;
            a = max(a, cov(d, c.px));
        }
        float3 ink = s == 0 ? float3(0.02, 0.02, 0.04) : float3(1.0);
        return pm(ink, a * vis);
    }
    if (s == 3) p = float2(p.y, p.x);
    const float rowH = 0.006;
    int ri = int(floor(p.y / rowH));
    float a = 0.0;
    for (int k = -1; k <= 1; k++) {
        int row = ri + k;
        int hs = row * 13 + fr * 7;
        if (hash1(hs) > 0.5) continue;
        float yc = (float(row) + 0.5) * rowH;
        float th = rowH * 0.25 * (0.5 + hash1(hs + 1));
        float x = p.x + c.t * 3.0 * (0.7 + 0.6 * hash1(row * 3 + 5));
        float segL = 0.25 + 0.5 * hash1(hs + 2);
        float period = segL * 2.5;
        float xs = fract(x / period + hash1(hs + 3)) * period;
        if (xs > segL) continue;
        float taper = sin(PI * xs / segL);
        a = max(a, cov(abs(p.y - yc) - th * taper, c.px));
    }
    float edge = 0.3 + 0.7 * smoothstep(0.05, 0.35, abs(p.y));
    return pm(float3(1.0), a * 0.75 * edge * vis);
}

// ---------------------------------------------------------------- 13 impact burst

static float4 anBurst(Ctx c, constant ANU& U) {
    float age = c.e.x, str = c.e.z;
    int seed = int(c.e.y * 100000.0);
    int s = c.style;
    float2 p = c.p;
    if (s == 0) {
        const float life = 0.4;
        if (age > life) return 0.0;
        float u = age / life;
        float R = (0.12 + 0.55 * (1.0 - pow(1.0 - u, 3.0))) * (0.7 + 0.5 * str);
        float ang = atan2(p.y, p.x);
        const float N = 16.0;
        float f = (ang / TAU + 0.5) * N;
        int i = int(floor(f));
        float tri = 1.0 - abs(fract(f) * 2.0 - 1.0);
        float spike = mix(0.45, 1.0, hash1((i % 16) + seed));
        float edge = R * (0.45 + 0.55 * spike * pow(tri, 1.6));
        float r = length(p);
        float hole = R * 0.9 * u * u;
        float fade = 1.0 - smoothstep(0.6, 1.0, u);
        float outer = cov(r - edge - 0.008, c.px) * cov(hole - r, c.px);
        float inner = cov(r - edge, c.px);
        float core = cov(r - edge * 0.72, c.px);
        float3 col = mix(float3(0.02), mix(float3(1.0, 0.78, 0.2), float3(1.0), core), inner);
        return pm(col, outer * fade);
    }
    if (s == 1) {
        const float life = 0.6;
        if (age > life) return 0.0;
        float u = age / life;
        float R = 0.05 + 1.1 * (1.0 - pow(1.0 - u, 2.5));
        float r = length(p);
        float T = 0.03 * (1.0 - u) + 0.003;
        float a1 = cov(abs(r - R) - T, c.px), a2 = cov(abs(r - R * 0.8) - T * 0.4, c.px);
        float g = exp(-abs(r - R) / 0.05) * 0.4;
        float fade = 1.0 - u;
        float3 col = mix(float3(0.6, 0.9, 1.0), float3(1.0), a1);
        return float4(col * g * fade, 0.0) + pm(col, max(a1, a2 * 0.7) * fade);
    }
    const float life = 1.0;
    if (age > life) return 0.0;
    float grow = saturate(age / 0.06);
    float fade = 1.0 - smoothstep(0.5, 1.0, age / life);
    float d = 1e3;
    for (int i = 0; i < 7; i++) {
        float ang = float(seed % 1000) * 0.00628 + float(i) * 0.9 + (hash1(seed + i * 11) - 0.5) * 0.5;
        float2 pos = 0.0;
        for (int sgm = 0; sgm < 6; sgm++) {
            if (float(sgm) >= grow * 6.0) break;
            ang += (hash1(seed + i * 31 + sgm) - 0.5) * 0.7;
            float2 nxt = pos + float2(cos(ang), sin(ang)) * (0.07 + 0.06 * hash1(seed + i * 37 + sgm));
            float w = 0.0025 * (1.0 - float(sgm) / 6.0);
            d = min(d, sdSeg(p, pos, nxt) - w);
            if (sgm == 2 || sgm == 4) {
                float ba = ang + (hash1(seed + i * 41 + sgm) > 0.5 ? 0.8 : -0.8);
                d = min(d, sdSeg(p, nxt, nxt + float2(cos(ba), sin(ba)) * 0.05) - w * 0.6);
            }
            pos = nxt;
        }
    }
    float core = cov(d, c.px), halo = cov(d - 0.004, c.px);
    float3 col = mix(float3(0.02, 0.02, 0.05), float3(0.95, 0.98, 1.0), core);
    return pm(col, halo * fade);
}

// ---------------------------------------------------------------- 14 aura

static float4 anAura(Ctx c, constant ANU& U) {
    float2 p = c.p;
    int s = c.style;
    float grow = 0.25 + c.r * (U.music.w * 0.5 + U.hits.x * 0.5 + U.hits.y * 0.3);
    float body = sdSeg(p, float2(0.0, 0.05), float2(0.0, 0.26)) - 0.06;
    if (s == 3) {
        float3 light = 0.0;
        float core = 0.0;
        int fr = int(c.seed);
        float on = 0.35 + 0.65 * saturate(c.r * (U.hits.y + U.music.w));
        for (int k = 0; k < 5; k++) {
            int hs = fr * 17 + k * 5;
            if (hash1(hs) > on) continue;
            float a0 = hash1(hs + 1) * TAU, a1 = a0 + (hash1(hs + 2) - 0.5) * 2.5;
            float2 ctr = float2(0.0, 0.15);
            float2 A = ctr + float2(cos(a0) * 0.09, sin(a0) * 0.16), B = ctr + float2(cos(a1) * 0.09, sin(a1) * 0.16);
            float2 prev = A;
            float d = 1e3;
            for (int j = 1; j <= 6; j++) {
                float u = float(j) / 6.0;
                float2 m = mix(A, B, u);
                float2 ov = normalize(m - ctr + 1e-4);
                float2 nxt = j == 6 ? B : m + ov * (0.04 + 0.05 * hash1(hs + j * 3)) * sin(PI * u) * (0.6 + grow)
                                        + float2(-ov.y, ov.x) * (hash1(hs + j * 7) - 0.5) * 0.03;
                d = min(d, sdSeg(p, prev, nxt));
                prev = nxt;
            }
            light += float3(0.55, 0.45, 1.0) * exp(-d / 0.012) * 0.5;
            core = max(core, cov(d - 0.0015, c.px));
        }
        light += float3(0.4, 0.35, 0.9) * exp(-max(body, 0.0) / 0.08) * 0.15 * on;
        return float4(light * (1.0 - core), 0.0) + pm(float3(0.95, 0.95, 1.0), core);
    }
    // flame tongues: noise sampled back down towards the body (so the tongues rise), stretched upwards, scrolling up;
    // they push the outline out mostly above and around the shoulders, little at the sides
    float bo = max(body, 0.0);
    float2 fq = float2(p.x * 9.0, (p.y - bo * 1.5) * 2.4 - c.t * 2.6);
    float n = fbm(fq + float2(0.0, fbm(p * 5.0 + float2(0.0, -c.t)) * 0.8));
    float up = saturate(p.y * 3.0 + 0.3);
    float tongue = pow(saturate(n * 1.5 - 0.25), 2.5) * 3.0 + 0.6 * vnoise(float2(p.x * 26.0, (p.y - bo * 1.5) * 5.0 - c.t * 4.0));
    float F = body - (0.012 + 0.03 * grow) * (0.3 + tongue) * (0.5 + 2.2 * up * up);
    float m = -F;
    float3 c1, c2, c3;
    if (s == 1) { c1 = float3(1.0, 0.60, 0.12); c2 = float3(1.0, 0.85, 0.35); c3 = float3(1.0, 0.98, 0.85); }
    else if (s == 2) { c1 = float3(0.15, 0.45, 1.0); c2 = float3(0.45, 0.85, 1.0); c3 = float3(0.92, 1.0, 1.0); }
    else { c1 = float3(0.40, 0.50, 1.0); c2 = float3(0.22, 0.08, 0.45); c3 = float3(0.10, 0.03, 0.20); }
    float a1 = cov(-m, c.px * 1.5), a2 = cov(0.022 - m, c.px * 1.5), a3 = cov(0.05 - m, c.px * 1.5);
    float3 col = mix(mix(c1, c2, a2), c3, a3);
    float glowA = exp(-max(body, 0.0) / (0.05 + 0.06 * grow)) * 0.3 * (1.0 - a1);
    // embers rising
    float3 em = 0.0;
    float2 eq = p - float2(0.0, -c.t * 0.25);
    int2 ec = int2(floor(eq / 0.04));
    float2 ed = eq - (float2(ec) + 0.5 + (float2(hash2(ec), hash2(ec + 3)) - 0.5) * 0.6) * 0.04;
    if (hash2(ec + 5) < 0.18 && body < 0.12) em = c1 * exp(-length(ed) / max(0.002, c.px)) * 1.2;
    return pm(col, a1 * 0.95) + float4((c1 * glowA + em) * (1.0 - a1), 0.0);
}

// ---------------------------------------------------------------- 15 slashes

static float4 slashOne(Ctx c, float age, float seedF, int s) {
    float life = s == 0 ? 0.45 : 0.6;
    if (age < 0.0 || age > life) return 0.0;
    int hs = int(seedF * 100000.0);
    float2 ctr = (float2(hash1(hs), hash1(hs + 1)) - 0.5) * float2(0.5, 0.3);
    float R = 0.28 + 0.35 * hash1(hs + 2);
    float a0 = hash1(hs + 3) * TAU;
    float sweep = 1.3 + 1.2 * hash1(hs + 4);
    float dir = hash1(hs + 5) > 0.5 ? 1.0 : -1.0;
    float T = (s == 0 ? 0.02 : 0.045) * (0.8 + 0.4 * hash1(hs + 6));
    float u = age / life;
    float head = 1.0 - pow(1.0 - saturate(age / 0.09), 3.0);
    float tail = saturate((age - 0.07) / (life * 0.6));
    tail *= tail;
    float2 v = c.p - ctr;
    float r = length(v);
    float rel = dir * (atan2(v.y, v.x) - a0);
    rel -= TAU * floor(rel / TAU);
    float f = rel / sweep;
    if (f > 1.0 || f < tail || f > head) return 0.0;
    float prof = sin(PI * saturate((f - tail) / max(head - tail, 1e-3)));
    float dr = r - R;
    float fade = 1.0 - smoothstep(0.55, 1.0, u);
    if (s == 0) {
        float w = T * prof;
        float a = cov(abs(dr) - w, c.px);
        float edge = smoothstep(-w * 0.15, -w * 0.5, abs(dr) - w);
        float3 col = mix(float3(0.65, 0.82, 1.0), float3(1.0), edge);
        float after = max(cov(abs(abs(dr) - (w + 0.012)) - c.px * 0.5, c.px) * 0.55, cov(abs(abs(dr) - (w + 0.03)) - c.px * 0.4, c.px) * 0.3) * prof;
        return pm(col, max(a, after) * fade);
    }
    if (s == 1) {
        float L = f * R * sweep;
        float w = T * prof;
        float crest = 1.0 + 0.35 * max(0.0, sin(L * 45.0 - age * 12.0));
        float outerE = dr - w * crest, innerE = -dr - w;
        float a = cov(max(outerE, innerE), c.px);
        if (a <= 0.0) return 0.0;
        float x = (dr + w) / (w * (1.0 + crest));
        float st = sin(L * 60.0 - age * 25.0 + x * 4.0);
        float3 col = float3(0.08, 0.30, 0.82);
        col = mix(col, float3(0.25, 0.60, 1.0), cov(-(x - 0.35), 0.02));
        col = mix(col, float3(0.95, 0.98, 1.0), cov(-(st - 0.55), 0.06) * cov(-(x - 0.6), 0.02));
        col = mix(col, float3(0.95, 0.98, 1.0), cov(abs(outerE) - 0.003, c.px));
        return pm(col, a * fade);
    }
    if (s == 2) {
        float L = f * R * sweep;
        float w = T * prof * (1.0 + 0.8 * fbm(float2(L * 30.0 - age * 4.0, age * 3.0)));
        float a = cov(max(dr - w, -dr - T * prof * 0.6), c.px);
        if (a <= 0.0) return 0.0;
        float x = saturate((dr + T * prof * 0.6) / (w + T * prof * 0.6));
        float3 col = x < 0.35 ? float3(1.0, 0.95, 0.6) : x < 0.7 ? float3(1.0, 0.55, 0.1) : float3(0.85, 0.15, 0.05);
        return pm(col, a * fade);
    }
    float j = dr - 0.025 * (vnoise(float2(f * 25.0 + float(hs % 97), floor(c.time * 24.0))) - 0.5) * 2.0;
    float core = cov(abs(j) - max(c.px, 0.003) * prof, c.px);
    float3 g = float3(1.0, 0.9, 0.35) * exp(-abs(j) / 0.02) * prof * 0.8;
    return float4(g * fade * (1.0 - core), 0.0) + pm(float3(1.0, 1.0, 0.85), core * fade);
}

static float4 anSlash(Ctx c, constant ANU& U) {
    float4 acc = slashOne(c, c.e.x, c.e.y, c.style);
    acc = under(acc, slashOne(c, c.e.z, c.e.w, c.style));
    acc = under(acc, slashOne(c, c.f.x, c.f.y, c.style));
    return acc;
}

// ---------------------------------------------------------------- 16 light wings

static float4 anWings(Ctx c, constant ANU& U) {
    float2 p = c.p;
    int s = c.style;
    float bass = U.music.x * c.r, kick = U.hits.x * c.r;
    if (s == 0) {
        float span = 1.0 + 0.25 * bass + 0.3 * kick;
        float2 q = float2(abs(p.x), p.y);
        float3 light = 0.0;
        float core = 0.0;
        for (int i = 0; i < 5; i++) {
            float a = mix(0.5, -0.4, float(i) / 4.0);
            float L = (0.3 + 0.3 * hash1(i * 7 + 1)) * span * (i == 1 || i == 2 ? 1.25 : 0.9);
            float2 dv = float2(cos(a), sin(a));
            float2 p0 = float2(0.02, 0.0), p1 = p0 + dv * L * 0.4;
            float2 p2 = p1 + rot2(dv, -0.15) * L * 0.35, p3 = p2 + rot2(dv, -0.35) * L * 0.25;
            float fl = 0.75 + 0.25 * sin(c.time * (7.0 + float(i)) + float(i) * 3.0);
            float d = min(sdSeg(q, p0, p1), min(sdSeg(q, p1, p2), sdSeg(q, p2, p3)));
            for (int b = 0; b < 3; b++) {
                float2 bp = b == 0 ? mix(p0, p1, 0.7) : b == 1 ? mix(p1, p2, 0.5) : mix(p2, p3, 0.4);
                float ba = a + (b % 2 == 0 ? 0.55 : -0.6) * (0.6 + 0.4 * hash1(i * 13 + b));
                float bl = L * (0.22 + 0.12 * hash1(i * 17 + b));
                float2 be = bp + float2(cos(ba), sin(ba)) * bl;
                d = min(d, sdSeg(q, bp, be));
                float2 tm = mix(bp, be, 0.55);
                float ta = ba + 0.5 * (hash1(i * 19 + b) > 0.5 ? 1.0 : -1.0);
                d = min(d, sdSeg(q, tm, tm + float2(cos(ta), sin(ta)) * bl * 0.4));
            }
            float3 hc = mix(float3(0.95, 0.55, 1.0), float3(0.55, 0.85, 1.0), saturate(q.x / 0.8));
            light += hc * (exp(-d / 0.025) * 0.16 + exp(-d / 0.007) * 0.35) * fl * smoothstep(0.0, 0.12, q.x + 0.04);
            core = max(core, cov(d - max(c.px * 0.6, 0.0012), c.px) * fl);
        }
        light += float3(1.0, 0.9, 1.0) * exp(-length(p) / 0.035) * (0.5 + kick);
        return float4(light * (1.0 - core), 0.0) + pm(float3(1.0), core);
    }
    if (s == 1) {
        float k = 1.0 + 0.4 * bass + 0.6 * kick;
        float wv = 0.02 * k * (1.0 + 2.0 * saturate(p.y));
        float pillar = exp(-abs(p.x) / wv);
        float bar = exp(-abs(p.y - 0.18) / (0.015 * k)) * exp(-abs(p.x) / (0.35 * k));
        float I = pillar + bar * 0.9;
        float core = saturate(I * 1.2 - 0.6);
        float3 col = mix(float3(1.0, 0.55, 0.35), float3(1.0), core) * I;
        float a = saturate(I - 0.3) * 0.9;
        return float4(col * (1.0 - a), 0.0) + pm(mix(float3(1.0, 0.75, 0.6), float3(1.0), core), a);
    }
    float r = length(p);
    float R = 0.16 * (1.0 + 0.1 * bass);
    float ring = exp(-abs(r - R) / 0.004) * 0.9 + exp(-abs(r - R) / 0.03) * 0.3;
    float ang = atan2(p.y, p.x);
    float rays = pow(abs(cos(ang * 12.0 + c.t * 0.3)), 30.0) * exp(-max(r - R, 0.0) / 0.12) * step(R, r);
    float core = cov(abs(r - R) - max(c.px, 0.002), c.px);
    float3 col = float3(1.0, 0.85, 0.5) * (ring + rays) * (1.0 + 0.5 * kick);
    return float4(col * (1.0 - core), 0.0) + pm(float3(1.0, 0.98, 0.9), core);
}

// ---------------------------------------------------------------- 17 planet & nebula

static float4 anPlanet(Ctx c, constant ANU& U) {
    float2 p = c.p;
    int s = c.style;
    float bass = U.music.x * c.r;
    if (s == 0) {
        const float R = 1.6;
        float2 ctr = float2(0.0, -0.3 - R);
        float2 v = p - ctr;
        float d = length(v) - R;
        float a = cov(d, c.px);
        float depthIn = saturate(-d / 0.5);
        float2 uv = float2(v.x / R * (1.0 + (1.0 - depthIn) * 0.8) * 3.0 + c.t * 0.01, -d * 6.0);
        float3 col = float3(0.10, 0.28, 0.62);
        float land = smoothstep(0.55, 0.6, fbm(uv * 1.5 + 2.0));
        col = mix(col, mix(float3(0.30, 0.45, 0.25), float3(0.62, 0.52, 0.36), fbm(uv * 4.0)), land);
        float cl = smoothstep(0.5, 0.72, fbm(uv * float2(2.5, 5.0) + float2(c.t * 0.015, 0.0) + fbm(uv * 3.0) * 0.8));
        col = mix(col, float3(0.96, 0.97, 1.0), cl * 0.9);
        col = mix(col, float3(0.55, 0.80, 1.0), exp(d / 0.025) * 0.6);
        col *= 0.4 + 0.6 * smoothstep(-0.6, 0.6, v.x / R + 0.3);
        float3 atm = float3(0.4, 0.7, 1.0) * (exp(-max(d, 0.0) / 0.03) * 0.8 + exp(-max(d, 0.0) / 0.12) * 0.3) * (1.0 + 0.5 * bass);
        return pm(col, a) + float4(atm * (1.0 - a), 0.0);
    }
    if (s == 1) {
        float2 q = p * 1.2 + float2(c.t * 0.01, 0.0);
        float w1 = fbm(q * 1.5 + fbm(q * 2.0 + 3.0) * 1.5);
        float w2 = fbm(q * 3.0 + w1 * 2.0 + 7.0);
        float dens = smoothstep(0.3, 0.72, w1);
        float3 col = mix(float3(0.95, 0.22, 0.42), float3(0.35, 0.28, 0.95), smoothstep(0.3, 0.7, w2));
        col = mix(col, float3(0.35, 0.75, 1.0), smoothstep(0.45, 0.7, fbm(q * 0.8 + 20.0)) * 0.7);
        col = mix(col, float3(1.0, 0.88, 0.95), smoothstep(0.65, 0.95, w1));
        col *= 1.0 - 0.45 * smoothstep(0.62, 0.8, fbm(q * 4.0 + 11.0)) * dens;
        col *= 1.25;
        col *= 1.0 + 0.3 * bass;
        return pm(col, dens * 0.9);
    }
    const float R = 0.14;
    float d = length(p) - R;
    float2 w = rot2(p, 0.35);
    w.y /= 0.28;
    float rr = length(w) / R;
    float ringM = smoothstep(1.3, 1.32, rr) * smoothstep(2.1, 2.08, rr) * (0.55 + 0.45 * smoothstep(0.4, 0.6, fract(rr * 7.0)));
    ringM *= 1.0 - smoothstep(1.62, 1.64, rr) * smoothstep(1.7, 1.68, rr);
    float3 rc = mix(float3(0.85, 0.75, 0.6), float3(0.65, 0.55, 0.45), fract(rr * 3.0));
    float pa = cov(d, c.px);
    float3 pc = 0.0;
    if (pa > 0.0) {
        float nz = sqrt(saturate(1.0 - dot(p, p) / (R * R)));
        float3 n = float3(p / R, nz);
        float lit = step(0.0, dot(n, normalize(float3(-0.6, 0.4, 0.7))) + 0.05 * vnoise(p * 80.0));
        float st = sin(p.y / R * 14.0 + fbm(p * 8.0 + float2(c.t * 0.02, 0.0)) * 2.0);
        pc = mix(float3(0.92, 0.78, 0.55), float3(0.80, 0.50, 0.30), smoothstep(-0.2, 0.2, st));
        pc *= mix(0.45, 1.0, lit);
        pc = mix(pc, float3(1.0, 0.95, 0.85), smoothstep(-0.006, -0.001, d) * lit * 0.6);
    }
    float4 front = w.y < 0.0 ? pm(rc, ringM) : 0.0;
    float4 back = w.y >= 0.0 ? pm(rc * 0.8, ringM) : 0.0;
    float4 acc = under(front, pm(pc, pa));
    return under(acc, back);
}

// ---------------------------------------------------------------- 18 spaceship

static float4 anShip(Ctx c, constant ANU& U) {
    int s = c.style;
    float P = s == 1 ? 26.0 : s == 2 ? 18.0 : 9.0;
    float ph = fract(c.t / P);
    float W = c.asp * 0.5 + 0.45;
    float2 pos = float2(mix(-W, W, ph), 0.08 * sin(ph * TAU + 0.5) + (s == 1 ? 0.12 : 0.0));
    float bank = 0.12 * cos(ph * TAU + 0.5);
    float sc = s == 1 ? 0.22 : s == 2 ? 0.07 : 0.09;
    float2 q = rot2(c.p - pos, -bank) / sc;
    float px = c.px / sc;
    float loud = U.music.w * c.r;
    float flick = 0.85 + 0.15 * sin(c.time * 40.0);
    if (s == 2) {
        float3 light = 0.0;
        float r = length(q);
        light += float3(1.0, 0.98, 0.9) * exp(-r / 0.08) * 1.5;
        if (q.x < 0.0) {
            float tw = 0.03 + 0.12 * -q.x;
            float yb = q.y + 0.015 * q.x * q.x;
            light += mix(float3(0.6, 0.85, 1.0), float3(0.75, 0.45, 1.0), saturate(-q.x / 6.0)) * exp(-abs(yb) / tw) * exp(q.x / (3.0 + 2.0 * loud)) * 0.8;
        }
        return float4(light, 0.0);
    }
    float4 col = 0.0;
    float d, dWing = 1e3, dCan = 1e3;
    float3 hullL, hullD;
    if (s == 0) {
        float nose = sdTri(q, float2(1.0, 0.0), float2(0.15, 0.17), float2(0.15, -0.14));
        float body = sdBox(q - float2(-0.3, 0.015), float2(0.5, 0.14)) - 0.04;
        dWing = min(sdTri(q, float2(0.1, 0.06), float2(-0.55, 0.72), float2(-0.66, 0.06)),
                    sdTri(q, float2(0.1, -0.06), float2(-0.5, -0.5), float2(-0.62, -0.06)));
        float fin = sdTri(q, float2(-0.5, 0.15), float2(-0.85, 0.48), float2(-0.8, 0.12));
        float eng = sdBox(q - float2(-0.78, 0.0), float2(0.1, 0.09)) - 0.02;
        d = min(min(nose, body), min(min(dWing, fin), eng));
        dCan = length((q - float2(0.22, 0.12)) * float2(1.0, 2.6)) - 0.2;
        hullL = float3(0.90, 0.20, 0.17); hullD = float3(0.55, 0.08, 0.12);
    } else {
        float hull = sdBox(q - float2(0.0, 0.0), float2(0.95, 0.09)) - 0.02;
        float prow = sdTri(q, float2(1.25, -0.02), float2(0.93, 0.11), float2(0.93, -0.11));
        float bridge = sdBox(q - float2(0.3, 0.16), float2(0.14, 0.07)) - 0.01;
        float tower = sdBox(q - float2(0.33, 0.25), float2(0.04, 0.04));
        float back = sdBox(q - float2(-0.95, 0.0), float2(0.12, 0.13)) - 0.02;
        d = min(min(hull, prow), min(min(bridge, tower), back));
        dWing = bridge;
        hullL = float3(0.62, 0.66, 0.74); hullD = float3(0.32, 0.35, 0.44);
    }
    float lw = 1.6 * px;
    float a = cov(d, px);
    if (a > 0.0) {
        float3 hc = q.y > -0.02 ? hullL : hullD;
        if (dWing < 0.0) hc *= 0.9;
        if (s == 0 && dWing < 0.0 && abs(q.y - 0.3 + q.x * 0.2) < 0.04) hc = float3(0.95, 0.95, 0.92);
        if (s == 1 && abs(q.y + 0.02) < 0.015) hc = float3(0.25, 0.45, 0.85);
        if (s == 1 && abs(q.y - 0.04) < 0.01 && fract(q.x * 12.0) < 0.3) hc = float3(1.0, 0.9, 0.6);
        if (dCan < 0.0) hc = mix(float3(0.30, 0.70, 1.0), float3(0.95, 1.0, 1.0), cov(abs(q.y - 0.16 - (q.x - 0.22) * 0.3) - 0.012, px));
        float ink = 1.0 - cov(d + lw, px);   // the ink outline just inside the edge
        ink = max(ink, cov(abs(dWing) - lw * 0.4, px) * step(d, 0.0) * 0.8);
        ink = max(ink, cov(abs(dCan) - lw * 0.4, px) * step(d, 0.0));
        hc = mix(hc, float3(0.04, 0.03, 0.06), ink);
        col = pm(hc, a);
    }
    // engine flame and trail
    float ex = s == 0 ? -0.88 : -1.07;
    float len = (0.35 + 0.65 * loud) * (s == 1 ? 0.6 : 1.0);
    float3 light = 0.0;
    if (q.x < ex) {
        float xr = (ex - q.x) / len;
        light += float3(0.55, 0.85, 1.0) * exp(-abs(q.y) / (0.06 * (1.0 - saturate(xr)) + 0.01)) * saturate(1.0 - xr) * 1.6 * flick;
        light += float3(0.6, 0.75, 1.0) * exp(-abs(q.y) / 0.012) * exp(-(ex - q.x) / 3.0) * 0.25;
    }
    return col + float4(light * (1.0 - col.a), 0.0);
}

// ---------------------------------------------------------------- 19 silhouette
// Everything is built from tapered capsules, ellipses and curved, tapered strands (quadratic Béziers) blended with
// smooth minimums. Figure units: feet at y = 0, about 1 high; the wind blows towards +x.

static float sdCapT(float2 p, float2 a, float2 b, float ra, float rb) {
    float2 pa = p - a, ba = b - a;
    float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-8));
    return length(pa - ba * h) - mix(ra, rb, h);
}
static float sdEll(float2 p, float2 r) { return (length(p / r) - 1.0) * min(r.x, r.y); }
/// A curved, tapered strand along the quadratic Bézier a → (c) → b.
static float sdStrand(float2 p, float2 a, float2 c, float2 b, float r0, float r1) {
    // the curve stays inside its control points' box: far from it, that box's distance is enough
    float rr = max(r0, r1);
    float2 lo = min(min(a, b), c) - rr, hi = max(max(a, b), c) + rr;
    float bd = sdBox(p - (lo + hi) * 0.5, (hi - lo) * 0.5);
    if (bd > 0.06) return bd;
    float d = 1e9;
    float2 prev = a;
    for (int i = 1; i <= 6; i++) {
        float t = float(i) / 6.0;
        float2 q = mix(mix(a, c, t), mix(c, b, t), t);
        d = min(d, sdCapT(p, prev, q, mix(r0, r1, t - 1.0 / 6.0), mix(r0, r1, t)));
        prev = q;
    }
    return d;
}
/// A limb from s to h with its joint bent `bend` away from the body's middle (x = 0).
static float sdLimb(float2 p, float2 s, float2 h, float bend, float r0, float r1, float r2) {
    float2 m = (s + h) * 0.5, dir = h - s;
    float2 n = normalize(float2(-dir.y, dir.x) + 1e-6);
    if (dot(n, float2(m.x, 0.0)) < 0.0) n = -n;
    float2 e = m + n * bend;
    return smin(sdCapT(p, s, e, r0, r1), sdCapT(p, e, h, r1, r2), 0.012);
}

/// A person seen from behind. look: 0 long coat + spiky hair, 1 skirt + long hair, 2 hakama + wide sleeves + ponytail,
/// 3 hooded cloak. hl / hr = where the hands are; scarf: a scarf streaming from the neck.
static float sdPerson(float2 p, float wind, float t, int look, float2 hl, float2 hr, bool scarf) {
    float g = wind * (0.88 + 0.12 * sin(t * 5.3 + p.y * 7.0));
    float slim = look == 1 ? 0.9 : 1.0;
    float2 ps = float2(p.x / slim, p.y);
    // torso: chest, waist, hips and the shoulder line, blended
    float torso = sdEll(ps - float2(0.0, 0.68), float2(0.086, 0.12));
    torso = smin(torso, sdEll(ps - float2(0.0, 0.555), float2(0.064, 0.075)), 0.04);
    torso = smin(torso, sdEll(ps - float2(0.0, 0.475), float2(0.075, 0.055)), 0.035);
    torso = smin(torso, sdCapT(ps, float2(-0.09, 0.776), float2(0.09, 0.776), 0.03, 0.03), 0.05);
    float d = torso;
    d = smin(d, sdCapT(p, float2(0.0, 0.79), float2(0.0, 0.87), 0.031, 0.027), 0.025);
    d = smin(d, sdEll(p - float2(0.0, 0.915), float2(0.058, 0.07)), 0.015);
    // arms and hands
    float2 sL = float2(-0.095 * slim, 0.766), sR = float2(0.095 * slim, 0.766);
    float ar = look == 1 ? 0.88 : 1.12;   // coats and kimonos: thicker sleeves
    d = smin(d, sdLimb(p, sL, hl, 0.012, 0.032 * ar, 0.026 * ar, 0.019 * ar), 0.02);
    d = smin(d, sdLimb(p, sR, hr, 0.012, 0.032 * ar, 0.026 * ar, 0.019 * ar), 0.02);
    d = min(d, sdEll(p - hl - float2(0.0, -0.016), float2(0.017, 0.026)));
    d = min(d, sdEll(p - hr - float2(0.0, -0.016), float2(0.017, 0.026)));
    // legs: thigh, calf, a small foot
    if (look != 2) {
        float lr = look == 1 ? 0.86 : 1.0;
        for (int sd = -1; sd <= 1; sd += 2) {
            float s = float(sd);
            float2 hip = float2(0.042 * s, 0.47), knee = float2(0.05 * s, 0.26), ank = float2(0.056 * s, 0.05);
            float leg = smin(sdCapT(p, hip, knee, 0.042 * lr, 0.029 * lr), sdCapT(p, knee, ank, 0.029 * lr, 0.018 * lr), 0.02);
            leg = smin(leg, sdEll(p - float2(0.053 * s, 0.18), float2(0.028 * lr, 0.06)), 0.03);
            leg = smin(leg, sdCapT(p, ank, float2(0.07 * s, 0.014), 0.02, 0.015), 0.015);
            d = smin(d, leg, 0.02);
        }
    }
    if (look == 0) {
        // a long coat, flaring, its hem lifting on the downwind side and its back vent parting
        float k = saturate((0.62 - p.y) / 0.47);
        float2 cp = float2(p.x - g * (0.04 * k + 0.13 * k * k), p.y);
        float w = 0.094 + 0.06 * k + 0.045 * g * k * k;
        float hemY = 0.15 + 0.016 * sin(cp.x * 30.0 - t * 9.0) * g + 0.35 * g * max(cp.x - 0.03, 0.0);
        float coat = max(abs(cp.x) - w, max(cp.y - 0.64, hemY - cp.y));
        float vent = max(abs(cp.x - 0.012) - (0.003 + 0.035 * g) * saturate((0.37 - cp.y) / 0.22), cp.y - 0.37);
        coat = max(coat, -vent);
        coat = smin(coat, torso - 0.012, 0.05);
        coat = min(coat, sdTri(float2(abs(p.x), p.y), float2(0.016, 0.775), float2(0.075, 0.778), float2(0.034, 0.872)) - 0.004);
        d = min(d, coat);
    } else if (look == 1) {
        // a skirt, flaring and lifting downwind, with a pleated hem
        float k = saturate((0.57 - p.y) / 0.2);
        float2 cp = float2(p.x - g * 0.06 * k * k, p.y);
        float w = 0.062 + 0.085 * k + 0.03 * g * k;
        float hemY = 0.37 + 0.008 * sin(cp.x * 80.0 + t * 6.0 * g) + 0.1 * g * max(cp.x, 0.0);
        float sk = max(abs(cp.x) - w, max(cp.y - 0.58, hemY - cp.y));
        d = smin(d, sk, 0.02);
    } else if (look == 2) {
        // hakama: wide trousers down to the ground, split between the legs
        float k = saturate((0.54 - p.y) / 0.5);
        float2 cp = float2(p.x - g * (0.03 * k + 0.05 * k * k), p.y);
        float w = 0.08 + 0.1 * k + 0.035 * g * k;
        float hk = max(abs(cp.x) - w, max(cp.y - 0.56, 0.03 - cp.y));
        float gap = max(abs(cp.x - 0.01 * g) - 0.004 - 0.02 * k, cp.y - 0.26);
        hk = max(hk, -gap);
        d = smin(d, hk, 0.03);
        for (int sd = -1; sd <= 1; sd += 2) d = min(d, sdEll(p - float2(0.085 * float(sd), 0.016), float2(0.036, 0.017)));
        // wide kimono sleeves, swinging downwind
        for (int sd = 0; sd < 2; sd++) {
            float2 s = sd == 0 ? sL : sR, h = sd == 0 ? hl : hr;
            float side = sd == 0 ? -1.0 : 1.0;
            float2 top = s + float2(0.0, -0.01), bot = mix(s, h, 0.82) + float2(0.03 * side + 0.06 * g, -0.06);
            float2 ax = bot - top;
            float ang = atan2(ax.x, -ax.y);
            float2 lp = rot2(p - (top + bot) * 0.5, -ang);
            lp.x -= side * 0.02 * saturate(-lp.y / length(ax) * 2.0 + 1.0);
            d = smin(d, sdTrap(lp, 0.06, 0.036, length(ax) * 0.5) - 0.008, 0.02);
        }
    } else {
        // a cloak from the shoulders, ragged at the hem
        float k = saturate((0.72 - p.y) / 0.6);
        float2 cp = float2(p.x - g * (0.05 * k + 0.12 * k * k), p.y);
        float w = 0.115 + 0.1 * k + 0.05 * g * k * k;
        float rag = 0.03 * vnoise(float2(cp.x * 22.0 + t * 2.0 * g, 3.0)) + 0.025 * vnoise(float2(cp.x * 55.0 - t * 3.0, 7.0));
        float hemY = 0.1 + rag + 0.25 * g * max(cp.x, 0.0);
        float cl = max(abs(cp.x) - w, max(cp.y - 0.74, hemY - cp.y));
        cl = smin(cl, sdEll(p - float2(0.0, 0.735), float2(0.125, 0.075)), 0.05);
        d = min(d, cl);
        // the hood, its point trailing downwind
        float hood = sdEll(p - float2(0.0, 0.915), float2(0.066, 0.078));
        hood = smin(hood, sdStrand(p, float2(0.01, 0.95), float2(0.07 + 0.03 * g, 0.965),
                                   float2(0.1 + 0.08 * g, 0.9 - 0.02 * g + 0.01 * sin(t * 6.0)), 0.04, 0.004), 0.02);
        d = smin(d, hood, 0.02);
    }
    // hair
    if (look == 0) {
        d = smin(d, sdEll(p - float2(0.0, 0.93), float2(0.066, 0.066)), 0.015);
        for (int i = 0; i < 9; i++) {
            float fi = float(i), u = fi / 8.0;
            float a = mix(3.5, -0.4, u) + 0.25 * (hash1(i * 7 + 3) - 0.5);
            float2 dir = float2(cos(a), sin(a));
            float2 root = float2(0.0, 0.93) + dir * float2(0.05, 0.05);
            float len = 0.045 + 0.035 * hash1(i * 7 + 1);
            float2 to = normalize(dir * 0.6 + float2(0.8 * g + 0.15, -0.55));
            float2 tip = root + to * len + 0.007 * float2(sin(t * 8.0 + fi * 1.7), cos(t * 7.0 + fi));
            d = smin(d, sdStrand(p, root, root + dir * len * 0.5, tip, 0.026, 0.0015), 0.006);
        }
    } else if (look == 1) {
        d = smin(d, sdEll(p - float2(0.0, 0.928), float2(0.062, 0.064)), 0.015);
        for (int i = 0; i < 7; i++) {
            float fi = float(i), u = fi / 6.0;
            float2 root = float2(mix(-0.05, 0.05, u), 0.91);
            float sw = 0.015 * sin(t * 4.5 + fi * 1.3);
            float2 tip = float2(root.x + 0.02 + g * (0.1 + 0.2 * u), 0.5 + 0.06 * hash1(i + 40) + g * (0.08 + 0.12 * u) + sw);
            float2 ctl = float2(root.x * 1.3 + g * 0.06 * u, 0.72);
            d = smin(d, sdStrand(p, root, ctl, tip, 0.03, 0.004), 0.012);
        }
    } else if (look == 2) {
        d = smin(d, sdEll(p - float2(0.0, 0.93), float2(0.064, 0.064)), 0.015);
        float2 tie = float2(0.035, 0.975);
        d = min(d, sdEll(p - tie, float2(0.02, 0.018)));
        for (int i = 0; i < 3; i++) {
            float fi = float(i);
            float sw = 0.02 * sin(t * 6.0 + fi * 1.9);
            float2 tip = float2(0.1 + g * (0.22 + 0.04 * fi), 0.7 + 0.18 * g - 0.03 * fi + sw);
            d = min(d, sdStrand(p, tie, float2(0.12 + 0.08 * g, 0.98 - 0.02 * fi), tip, 0.026 - 0.005 * fi, 0.002));
        }
    }
    if (scarf) {
        for (int k = 0; k < 2; k++) {
            float fk = float(k), ph = t * 7.0 + fk * 1.7;
            // two thin ribbons from the neck, tapering and rippling (anything thick at that height reads as an arm)
            float2 a0 = float2(0.04, 0.835 - 0.012 * fk);
            float L = (0.2 + 0.2 * g) * (1.0 - 0.25 * fk);
            float2 dir = normalize(float2(0.45 + 0.55 * g, -0.75 + 0.6 * g - 0.15 * fk));
            float2 nrm = float2(-dir.y, dir.x);
            float2 m0 = a0 + dir * L * 0.5 + nrm * 0.035 * sin(ph);
            float2 e0 = a0 + dir * L + nrm * 0.045 * sin(ph - 2.4);
            float2 c0 = a0 + dir * L * 0.25 + nrm * 0.03 * sin(ph + 1.3);
            float2 c1 = 2.0 * m0 - c0;
            float r0 = 0.017 - 0.003 * fk;
            d = min(d, sdStrand(p, a0, c0, m0, r0, r0 * 0.8));
            d = min(d, sdStrand(p, m0, c1, e0, r0 * 0.8, 0.003));
        }
        d = smin(d, sdEll(p - float2(0.0, 0.825), float2(0.044, 0.03)), 0.02);
    }
    return d;
}

static float sdRobot(float2 p, float t) {
    p.x += 0.006 * sin(t * 0.5) * p.y;
    float2 q = float2(abs(p.x), p.y);   // symmetric
    // feet, shins swelling towards the ankle, knees with a fin, thighs
    float d = sdTrap(q - float2(0.122, 0.03), 0.09, 0.055, 0.03) - 0.006;
    d = min(d, sdTrap(q - float2(0.116, 0.165), 0.07, 0.048, 0.105) - 0.008);
    d = min(d, sdTrap(rot2(q - float2(0.15, 0.12), -0.12), 0.012, 0.03, 0.06) - 0.004);   // calf thruster
    d = min(d, sdEll(q - float2(0.1, 0.3), float2(0.048, 0.036)));
    d = min(d, sdTri(q, float2(0.075, 0.29), float2(0.125, 0.3), float2(0.095, 0.38)) - 0.004);
    d = smin(d, sdCapT(q, float2(0.095, 0.32), float2(0.08, 0.45), 0.042, 0.05), 0.015);
    // hips and skirt plates
    d = smin(d, sdEll(q - float2(0.0, 0.47), float2(0.1, 0.045)), 0.02);
    d = min(d, sdTrap(rot2(q - float2(0.105, 0.43), 0.25), 0.042, 0.03, 0.055) - 0.006);
    d = min(d, sdTri(q, float2(0.0, 0.37), float2(0.035, 0.46), float2(0.0, 0.47)) - 0.004);
    // waist and a broad chest
    d = smin(d, sdEll(q - float2(0.0, 0.52), float2(0.055, 0.045)), 0.02);
    d = smin(d, sdTrap(p - float2(0.0, 0.615), 0.075, 0.15, 0.07) - 0.014, 0.03);
    // pauldrons: rounded tops, flat undersides, a fin
    float pa = max(sdEll(q - float2(0.205, 0.695), float2(0.08, 0.06)), -(q.y - 0.655));
    pa = min(pa, sdTri(q, float2(0.17, 0.73), float2(0.25, 0.73), float2(0.27, 0.82)) - 0.004);
    d = min(d, pa - 0.004);
    // arms: upper arm, a forearm flaring towards the wrist, fists
    d = smin(d, sdCapT(q, float2(0.215, 0.66), float2(0.228, 0.5), 0.034, 0.03), 0.015);
    d = min(d, sdTrap(q - float2(0.234, 0.42), 0.046, 0.034, 0.075) - 0.006);
    d = min(d, sdEll(q - float2(0.243, 0.31), float2(0.04, 0.045)));
    // thruster wings behind the shoulders
    d = min(d, sdTri(q, float2(0.11, 0.74), float2(0.16, 0.7), float2(0.33, 0.95)) - 0.006);
    d = min(d, sdTri(q, float2(0.12, 0.7), float2(0.15, 0.66), float2(0.36, 0.84)) - 0.005);
    // neck, helmet, chin, V-fin and crest
    d = smin(d, sdCapT(q, float2(0.0, 0.69), float2(0.0, 0.72), 0.022, 0.02), 0.01);
    d = smin(d, sdEll(q - float2(0.0, 0.765), float2(0.042, 0.045)), 0.012);
    d = min(d, sdTri(q, float2(0.0, 0.72), float2(0.03, 0.735), float2(0.0, 0.705)) - 0.002);
    d = min(d, sdStrand(q, float2(0.0, 0.79), float2(0.06, 0.8), float2(0.13, 0.88), 0.012, 0.001));
    d = min(d, sdTri(q, float2(0.0, 0.79), float2(0.012, 0.8), float2(0.0, 0.84)) - 0.002);
    return d;
}

/// A cat sitting on a wall (the wall's top at y = 0), facing left, its tail hanging over the edge.
static float sdCat(float2 p, float swish, float twitch) {
    float d = sdEll(p - float2(0.045, 0.09), float2(0.1, 0.09));
    d = smin(d, sdCapT(p, float2(0.03, 0.11), float2(-0.045, 0.24), 0.08, 0.05), 0.04);
    d = smin(d, sdEll(p - float2(-0.055, 0.15), float2(0.05, 0.085)), 0.03);
    d = smin(d, sdCapT(p, float2(-0.065, 0.15), float2(-0.078, 0.012), 0.024, 0.017), 0.02);
    d = smin(d, sdCapT(p, float2(-0.03, 0.15), float2(-0.04, 0.012), 0.022, 0.016), 0.02);
    d = min(d, sdEll(p - float2(-0.088, 0.012), float2(0.024, 0.013)));
    float h = sdEll(p - float2(-0.065, 0.315), float2(0.062, 0.054));
    h = smin(h, sdEll(p - float2(-0.118, 0.298), float2(0.028, 0.024)), 0.02);
    h = min(h, sdTri(p, float2(-0.112, 0.34), float2(-0.07, 0.355), float2(-0.104 - 0.014 * twitch, 0.418 - 0.012 * twitch)) - 0.005);
    h = min(h, sdTri(p, float2(-0.052, 0.355), float2(-0.012, 0.335), float2(-0.03, 0.408)) - 0.005);
    d = smin(d, h, 0.03);
    float2 a = float2(0.12, 0.03), e = float2(0.17 + 0.07 * swish, -0.27 + 0.03 * abs(swish));
    d = smin(d, sdStrand(p, a, float2(0.19, -0.04), e, 0.024, 0.014), 0.02);
    return d;
}

constant float4 anTreeClumps[14] = {
    float4(-0.34, 0.7, 0.08, 0.3), float4(-0.25, 0.77, 0.1, 1.7), float4(-0.12, 0.86, 0.1, 2.9), float4(0.02, 0.92, 0.1, 4.1),
    float4(0.15, 0.86, 0.1, 5.3), float4(0.27, 0.76, 0.09, 0.9), float4(0.38, 0.67, 0.07, 3.3), float4(-0.17, 0.68, 0.07, 6.1),
    float4(0.06, 0.78, 0.09, 1.2), float4(-0.06, 0.74, 0.07, 2.2), float4(0.2, 0.68, 0.07, 3.8), float4(-0.28, 0.65, 0.06, 4.6),
    float4(0.1, 1.0, 0.06, 5.9), float4(-0.08, 0.99, 0.06, 0.6)
};

/// A lone, wind-bent tree (its foot at 0).
static float sdTree(float2 p, float wind, float t, float flutter) {
    float2 b = p;
    b.x -= (wind * 0.06 + wind * (0.02 + 0.015 * sin(t * 1.3))) * p.y * p.y;
    float d = sdStrand(b, float2(0.0, -0.05), float2(0.02, 0.3), float2(0.07, 0.55), 0.055, 0.03);
    d = smin(d, sdStrand(b, float2(0.0, 0.12), float2(-0.04, 0.02), float2(-0.13, -0.01), 0.03, 0.008), 0.03);
    d = smin(d, sdStrand(b, float2(0.01, 0.12), float2(0.05, 0.02), float2(0.14, -0.015), 0.03, 0.008), 0.03);
    d = min(d, sdStrand(b, float2(0.05, 0.45), float2(-0.12, 0.6), float2(-0.3, 0.68), 0.022, 0.007));
    d = min(d, sdStrand(b, float2(0.07, 0.5), float2(0.2, 0.58), float2(0.35, 0.64), 0.02, 0.007));
    d = min(d, sdStrand(b, float2(0.07, 0.54), float2(0.06, 0.7), float2(0.02, 0.84), 0.02, 0.006));
    d = min(d, sdStrand(b, float2(-0.14, 0.62), float2(-0.2, 0.74), float2(-0.15, 0.84), 0.01, 0.004));
    d = min(d, sdStrand(b, float2(0.2, 0.585), float2(0.22, 0.68), float2(0.18, 0.78), 0.01, 0.004));
    float f = 1e9;
    for (int i = 0; i < 14; i++) {
        float4 k = anTreeClumps[i];
        float2 o = float2(sin(t * 1.7 + k.w) * 0.01 + wind * 0.02, cos(t * 2.1 + k.w) * 0.006) * (0.6 + flutter);
        float2 r = b - k.xy - o;
        float dc = length(r) - k.z * 1.25;
        if (dc > 0.09) { f = min(f, dc - 0.05); continue; }   // far from this clump: no leaves to work out
        // leafy edge: lobes around the clump plus fine serration, a flatter underside
        float an = atan2(r.y, r.x);
        float lobes = 0.008 * sin(an * 5.0 + k.w * 5.0) + 0.006 * sin(an * 11.0 + k.w * 2.0);
        float edge = lobes + 0.022 * vnoise(r * 26.0 + float2(k.w * 9.0, t * flutter)) + 0.012 * vnoise(r * 70.0 + k.w * 3.0);
        f = smin(f, length(r * float2(1.0, r.y < 0.0 ? 1.4 : 1.0)) - k.z * 1.25 + edge, 0.05);
    }
    return min(d, f);
}

/// A shrine gate (its feet at 0).
static float sdGate(float2 p) {
    float2 q = float2(abs(p.x), p.y);
    float d = sdCapT(q, float2(0.34, -0.02), float2(0.31, 0.8), 0.042, 0.034);
    d = min(d, sdBox(q - float2(0.34, 0.03), float2(0.06, 0.03)) - 0.008);
    d = min(d, sdBox(q - float2(0.0, 0.64), float2(0.45, 0.02)) - 0.004);
    float yc = 0.86 + 0.075 * pow(q.x / 0.64, 2.6);
    float top = max(abs(q.y - yc) - 0.03, q.x - 0.64 - (q.y - yc + 0.03) * 0.6);
    float y2 = 0.8 + 0.03 * pow(q.x / 0.58, 2.6);
    top = min(top, max(abs(q.y - y2) - 0.022, q.x - 0.56));
    d = min(d, top);
    d = min(d, sdBox(q - float2(0.0, 0.72), float2(0.02, 0.06)));
    d = min(d, sdBox(q - float2(0.0, 0.725), float2(0.055, 0.045)) - 0.008);
    return d;
}

/// The silhouette of style s (figure units). blade: the sword's own distance (style 3).
static float silShape(int s, float2 q, float wind, float t, float4 m, thread float& blade) {
    blade = 1e9;
    switch (s) {
        case 0: case 2: return sdPerson(q, wind, t, 0, float2(-0.128, 0.49), float2(0.134, 0.495), true);
        case 1: return sdRobot(q, t);
        case 3: {
            float d = sdPerson(q, wind, t, 2, float2(-0.13, 0.49), float2(0.16, 0.49), false);
            float2 h1 = float2(0.21, 0.44);
            d = min(d, sdCapT(q, float2(0.13, 0.53), h1, 0.013, 0.012));
            d = min(d, sdEll(rot2(q - h1, 0.7), float2(0.024, 0.008)));
            blade = sdStrand(q, h1, float2(0.41, 0.27), float2(0.62, 0.04), 0.011, 0.002);
            return min(d, blade);
        }
        case 4: {
            float2 hr = float2(0.11, 0.7);
            float d = sdPerson(q, wind, t, 1, float2(-0.12, 0.5), hr, false);
            float a = -0.28 - 0.08 * wind + 0.03 * sin(t * 2.0) + 0.04 * m.w;
            float2 dir = float2(sin(a), cos(a));
            float2 top = hr + dir * 0.5;
            d = min(d, sdCapT(q, hr - dir * 0.06, top + dir * 0.05, 0.007, 0.006));
            float2 l = float2(dot(q - top, float2(dir.y, -dir.x)), dot(q - top, dir));
            float lob = abs(sin(l.x / 0.36 * PI * 3.0));
            float canopy = max(sdEll(l - float2(0.0, -0.2), float2(0.36, 0.2)), (-0.2 + 0.03 * lob) - l.y);
            return min(d, canopy);
        }
        case 5: {
            float d = sdPerson(q - float2(-0.13, 0.0), wind, t, 0, float2(-0.128, 0.49), float2(0.125, 0.49), false);
            float2 qb = (q - float2(0.12, 0.0)) / 0.9;
            return min(d, sdPerson(qb, wind, t + 1.3, 1, float2(-0.122, 0.544), float2(0.12, 0.52), false) * 0.9);
        }
        case 6: return sdCat(q, m.x, m.y);
        case 7: {
            float d = sdPerson(q, wind, t, 3, float2(-0.2, 0.62), float2(0.12, 0.5), false);
            d = min(d, sdCapT(q, float2(-0.225, 0.0), float2(-0.195, 1.1), 0.011, 0.01));
            return min(d, abs(length(q - float2(-0.19, 1.15)) - 0.042) - 0.007);
        }
        case 8: return sdTree(q, wind, t, m.z);
        default: return sdGate(q);
    }
}

static float4 anFigure(Ctx c, constant ANU& U) {
    int s = c.style;
    float wind = saturate(0.35 + c.r * U.time.y);
    float2 p = c.p;
    float4 acc = 0.0;
    float sz = s == 1 ? 0.6 : s == 2 ? 0.16 : s == 5 ? 0.3 : s == 6 ? 0.5 : s == 8 ? 0.55 : s == 9 ? 0.45 : 0.33;
    float2 q = p / sz;
    float pxq = c.px / sz;
    // swish (cat's tail), twitch (ears), leaf flutter, bass bob
    float4 m = float4(sin(c.t * 1.4) + 0.6 * U.hits.w * c.r, U.hits.z * c.r, U.music.z * c.r, U.music.x * c.r);
    float4 bb = s == 1 ? float4(0.0, 0.5, 0.39, 0.5) : s == 3 ? float4(0.2, 0.52, 0.45, 0.5) : s == 4 ? float4(0.0, 0.66, 0.42, 0.66)
              : s == 5 ? float4(0.04, 0.52, 0.38, 0.5) : s == 6 ? float4(0.06, 0.08, 0.2, 0.36) : s == 7 ? float4(-0.02, 0.6, 0.32, 0.62)
              : s == 8 ? float4(0.04, 0.55, 0.5, 0.58) : s == 9 ? float4(0.0, 0.47, 0.7, 0.5)
              : float4(0.12, 0.52, 0.36, 0.5);
    float3 body = float3(0.04, 0.03, 0.07);
    float3 rimC = float3(1.0, 0.6, 0.38);
    if (s == 2) { body = float3(0.10, 0.12, 0.22); rimC = float3(1.0, 0.95, 0.85); }
    float2 L = normalize(float2(0.75, 0.55));
    if (sdBox(q - bb.xy, bb.zw) < 4.0 * pxq) {
        // one call site (the shape is big: inlining it three times for the gradient slowed every layer down)
        float rimW = max(1.8 * pxq, 0.0055), e = max(pxq, 0.003);
        float dd[3] = { 1.0, 0.0, 0.0 };
        float blade = 1e9;
        int nk = 1;
        for (int k = 0; k < 3; k++) {
            if (k >= nk) break;
            float bl;
            float2 o = k == 1 ? float2(e, 0.0) : (k == 2 ? float2(0.0, e) : float2(0.0));
            dd[k] = silShape(s, q + o, wind, c.t, m, bl);
            if (k == 0) {
                blade = bl;
                if (dd[0] > -rimW * 1.2 && dd[0] < pxq) nk = 3;   // the rim needs the outline's direction
            }
        }
        float d = dd[0];
        float a = cov(d, pxq);
        if (a > 0.0) {
            float3 col = body;
            if (nk == 3) {
                // rim light on the lit edges
                float2 n = normalize(float2(dd[1] - d, dd[2] - d) + 1e-6);
                float lit = saturate(dot(n, L) * 1.4 - 0.1);
                col = mix(col, rimC, (1.0 - cov(d + rimW, pxq)) * lit * 0.95);
            }
            if (s == 3 && blade < 0.0) {
                // steel catching the light, a glint running down it on the beat
                float u = saturate((q.x - 0.2) / 0.4);
                float gl = exp(-abs(u - fract(c.t * 0.35)) / 0.05) * (0.4 + 0.6 * U.hits.w * c.r);
                col = mix(float3(0.45, 0.5, 0.62), float3(1.0), saturate(gl + 0.8 * U.hits.x * c.r));
            }
            if (s == 1) {
                float2 qa = float2(abs(q.x), q.y);
                float eyes = cov(sdCapT(qa, float2(0.01, 0.764), float2(0.032, 0.774), 0.0055, 0.003), pxq);
                float glow = 0.6 + 0.4 * U.hits.w * c.r + 0.6 * U.hits.x * c.r;
                col = mix(col, float3(1.0, 0.85, 0.35) * glow, eyes);
                col = mix(col, float3(1.0, 0.5, 0.25) * glow, cov(length(q - float2(0.0, 0.63)) - 0.016, pxq));
            }
            if (s == 6) {
                float eye = cov(sdEll(rot2(q - float2(-0.088, 0.322), 0.25), float2(0.012, 0.0055)), pxq);
                col = mix(col, float3(0.8, 1.0, 0.35) * (0.6 + 0.8 * U.hits.x * c.r), eye);
            }
            acc = pm(col, a);
        }
    }
    float3 glowC = 0.0;
    if (s == 1) {
        float2 qa = float2(abs(q.x), q.y);
        float g = exp(-length((qa - float2(0.022, 0.77)) * float2(0.6, 2.0)) / 0.025) * (0.5 + U.hits.x * c.r) * 0.8;
        g += exp(-length(q - float2(0.0, 0.63)) / 0.03) * (0.2 + U.hits.x * c.r) * 0.7;
        glowC = float3(1.0, 0.7, 0.3) * g;
    }
    if (s == 6) glowC = float3(0.7, 1.0, 0.3) * exp(-length(q - float2(-0.088, 0.322)) / 0.012) * U.hits.x * c.r * 0.6;
    acc += float4(glowC * (1.0 - acc.a), 0.0);
    // the ground each style stands on
    if (s == 2) {
        float top = -0.004 - 0.012 * fbm(float2(p.x * 20.0, 3.0));
        if (p.x < -0.04) top -= (-0.04 - p.x) * 4.0 + 0.02 * vnoise(float2(p.y * 30.0, 1.0));
        top += 0.006 * pow(vnoise(float2(p.x * 300.0 - c.t * 3.0 * wind, 2.0)), 3.0);   // grass on the edge
        float ra = cov(p.y - top, c.px);
        float3 rc = mix(float3(0.08, 0.09, 0.16), float3(0.45, 0.42, 0.45), cov(abs(p.y - top) - 0.003, c.px) * 0.6);
        acc = under(acc, pm(rc, ra));
    } else if (s == 6) {
        // a garden wall: coping stones on top, faint courses below
        float top = 0.0;
        float wa = cov(q.y - top, pxq);
        if (wa > 0.0) {
            float3 wc = float3(0.1, 0.085, 0.13);
            float row = floor(q.y / 0.07);
            float bx = fract(q.x / 0.16 + 0.5 * fmod(abs(row), 2.0));
            float joint = max(cov(abs(fract(q.y / 0.07) - 0.5) * 0.07 - 0.033, pxq), cov(abs(bx - 0.5) * 0.16 - 0.077, pxq));
            if (q.y > -0.035) { wc = float3(0.13, 0.11, 0.16); joint = cov(abs(fract(q.x / 0.3) - 0.5) * 0.3 - 0.147, pxq); }
            wc *= 1.0 - 0.35 * joint;
            wc = mix(wc, rimC * 0.8, cov(-q.y - max(1.5 * pxq, 0.004), pxq) * 0.7);
            acc = under(acc, pm(wc, wa));
        }
    } else if (s == 8) {
        float top = -0.16 * q.x * q.x + 0.012 * vnoise(float2(q.x * 30.0, 1.0))
                  + 0.018 * pow(vnoise(float2(q.x * 160.0 - c.t * 4.0 * wind, 2.0)), 2.0);
        float ha = cov(q.y - top, pxq);
        float3 hc = mix(body * 1.3, rimC * 0.85, cov(-(q.y - top) - max(1.8 * pxq, 0.005), pxq) * 0.8);
        acc = under(acc, pm(hc, ha));
    } else if (s == 9) {
        float top = -0.005 + 0.008 * vnoise(float2(q.x * 12.0, 4.0));
        float ga = cov(q.y - top, pxq);
        float3 gc = mix(body * 1.2, rimC * 0.7, cov(-(q.y - top) - max(1.5 * pxq, 0.004), pxq) * 0.6);
        acc = under(acc, pm(gc, ga));
    }
    return acc;
}

// ---------------------------------------------------------------- 20 Japanese titles
// Glyphs come from a signed-distance atlas (AnimeTitles.swift): row = line, column = character, 128 px cells.
// e = (row, characters, age of the line s, rotate mask), f.x = small-kana mask, f.y = Giant kanji's character.

constexpr sampler anTitleS(filter::linear, address::clamp_to_edge);

/// Distance (in cells, negative inside) of character i of atlas row `row` at cell coordinates uv (0…1, y up).
static float glyphD(texture2d<float> T, float row, float i, float2 uv, int font) {
    if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) return 0.2;
    float2 sz = float2(T.get_width(), T.get_height());
    float4 v = T.sample(anTitleS, (float2(i, row) + float2(uv.x, 1.0 - uv.y)) * 128.0 / sz);
    return (0.5 - (font == 0 ? v.r : v.g)) * 24.0 / 128.0;
}

/// Ink a glyph: fill, outline, a drop shadow (front to back, premultiplied). pc = one pixel in cells.
static float4 inkGlyph(texture2d<float> T, float row, float i, float2 uv, int font, float pc, float3 fillC, float3 lineC,
                       float ow, float a) {
    float d = glyphD(T, row, i, uv, font);
    float ds = glyphD(T, row, i, uv - float2(0.035, -0.035), font);
    float4 acc = pm(fillC, cov(d, pc) * a);
    acc = under(acc, pm(lineC, cov(d - ow, pc) * a));
    acc = under(acc, pm(lineC * 0.5, cov(ds - ow, pc * 4.0) * 0.45 * a));
    return acc;
}

static float4 anTitle(Ctx c, constant ANU& U, texture2d<float> T) {
    float row = c.e.x, n = c.e.y, age = c.e.z;
    if (row < 0.0 || n < 1.0) return 0.0;
    int s = c.style;
    float kick = U.hits.x * c.r;
    float2 p = c.p;
    float3 paper = float3(0.97, 0.95, 0.9), ink = float3(0.05, 0.03, 0.05), red = float3(0.82, 0.1, 0.1);
    float4 acc = 0.0;
    if (s == 0) {
        // vertical title: the characters stamp in from the top, a red rule and a seal follow
        float S = 0.1;
        p /= 1.0 + 0.05 * kick;
        float top = n * S * 0.5;
        float fi = floor((top - p.y) / S);
        if (fi >= 0.0 && fi < n) {
            float ap = saturate((age - fi * 0.07) / 0.12);
            float sc = 1.0 + 0.9 * (1.0 - ap) * (1.0 - ap);
            float2 cc = float2(0.0, top - (fi + 0.5) * S);
            float2 uv = (p - cc) / (S * sc) + 0.5;
            int bit = 1 << int(fi);
            if ((int(c.e.w) & bit) != 0) uv = float2(uv.y, 1.0 - uv.x);
            if ((int(c.f.x) & bit) != 0) uv -= float2(0.1, 0.15);
            acc = inkGlyph(T, row, fi, uv, 0, c.px / (S * sc), paper, ink, 0.07, ap);
        }
        float grow = saturate(age / 0.5);
        float rule = cov(max(abs(p.x + 0.62 * S) - 0.004, max(p.y - top, top - 2.0 * top * grow - p.y)), c.px);
        acc = under(acc, pm(red, rule));
        float as = saturate((age - n * 0.07 - 0.1) / 0.1);
        if (as > 0.0) {
            float sc = 1.0 + 0.6 * (1.0 - as);
            float2 q = (p - float2(0.0, -top - 0.55 * S)) / sc;
            float sq = sdBox(q, float2(0.2 * S)) - 0.02 * S;
            float sealA = cov(sq, c.px) * (1.0 - 0.35 * cov(abs(sq + 0.06 * S) - 0.012 * S, c.px)) * as;
            sealA *= 0.8 + 0.2 * vnoise(q / S * 9.0);   // uneven stamp ink
            acc = under(acc, pm(red, sealA));
        }
    } else if (s == 1) {
        // title card: a wipe reveals the line, rules run out above and below
        float S = 0.16;
        float W = n * S;
        p.x += (hash1(int(c.seed)) - 0.5) * 0.012 * kick;
        float fi = floor((p.x + W * 0.5) / S);
        float rev = -W * 0.5 + (W + 0.3) * saturate(age / 0.6);
        float m = smoothstep(rev, rev - 0.1, p.x);
        if (fi >= 0.0 && fi < n) {
            float2 cc = float2(-W * 0.5 + (fi + 0.5) * S, 0.0);
            float2 uv = (p - cc) / S + 0.5;
            acc = inkGlyph(T, row, fi, uv, 1, c.px / S, paper, ink, 0.06, m);
        }
        float ext = (W * 0.5 + 0.08) * saturate(age / 0.45);
        float rules = cov(max(abs(abs(p.y) - 0.62 * S) - 0.0035, abs(p.x) - ext), c.px);
        acc = under(acc, pm(mix(paper, red, 0.6), rules));
    } else if (s == 2) {
        // ticker: a band along the screen, the lines end to end scrolling through it (positions from the CPU)
        float H = 0.075, S = 0.055;
        float band = cov(abs(p.y) - H * 0.5, c.px);
        if (band <= 0.0) return 0.0;
        // the lines from x0 (rows e.x + j, e.y lines, starting at e.w), each followed by a two-character gap with a
        // diamond; lengths − 1 packed 4 bits each in f.x / f.y
        int N = int(c.e.y);
        float x = c.e.z;
        for (int k = 0; k < 24 && x < p.x + S; k++) {
            int j = (int(c.e.w) + k) % max(N, 1);
            int pk = int(j < 6 ? c.f.x : c.f.y);
            float W = float(((pk >> (4 * (j % 6))) & 15) + 1) * S;
            float lx = p.x - x;
            if (lx >= 0.0 && lx < W) {
                float fi = floor(lx / S);
                float2 uv = float2((lx - fi * S) / S, p.y / S + 0.5);
                acc = inkGlyph(T, row + float(j), fi, uv, 1, c.px / S, paper, ink, 0.04, 1.0);
                break;
            } else if (lx >= W && lx < W + 2.0 * S) {
                float2 q = rot2(float2(lx - W - S, p.y), 0.785);
                acc = pm(red, cov(sdBox(q, float2(0.12 * S)), c.px));
                break;
            }
            x += W + 2.0 * S;
        }
        float3 bc = float3(0.05, 0.05, 0.11);
        bc = mix(bc, red, cov(abs(p.y - H * 0.5 + 0.004) - 0.004, c.px));
        bc = mix(bc, paper * 0.8, cov(abs(p.y + H * 0.5 - 0.002) - 0.0015, c.px));
        acc = under(acc, pm(bc, band * 0.85));
    } else {
        // giant kanji: one character filling the screen, a new one on every beat, flaring on the kicks
        float S = 0.85 * (1.0 + 0.04 * kick);
        float fi = c.f.y;
        float2 uv = p / S + 0.5;
        float d = glyphD(T, row, fi, uv, 0);
        float pc = c.px / S;
        float fill = cov(d, pc) * (0.35 + 0.65 * saturate(kick + U.hits.w * c.r * 0.5));
        float edge = cov(abs(d + 0.006) - 0.006, pc);
        acc = pm(red, fill);
        acc = under(pm(paper, edge * 0.9), acc);
        acc *= saturate(age / 0.15);
    }
    return acc;
}

// ---------------------------------------------------------------- the stack

fragment float4 anLayersFrag(ANOut in [[stage_in]], constant ANU& U [[buffer(0)]], constant ANL* Ls [[buffer(1)]],
                             texture2d<float> titles [[texture(0)]]) {
    float2 res = U.res.xy;
    float asp = U.res.z;
    // the layers are cards in 3D, one plane each (z = gap × (index − middle), the front one nearest), seen through the
    // orbit camera at distance D; each card is scaled by its distance so that head-on it covers exactly the window
    // (at rest the picture is the flat one, whatever the gap)
    const float D = 3.0;
    float2 ndc = float2(in.position.x / res.x * 2.0 - 1.0, 1.0 - in.position.y / res.y * 2.0) - U.view.yz;
    float tanH = 0.5 / (D * max(U.view.x, 0.05));
    float3 dc = float3(ndc.x * asp * tanH, ndc.y * tanH, -1.0);
    float3x3 Rt = float3x3(U.rot[0].xyz, U.rot[1].xyz, U.rot[2].xyz);
    float3 o = Rt * float3(0.0, 0.0, D);
    float3 d = Rt * dc;
    if (abs(d.z) < 1e-6) return 0.0;
    float dl = length(d);
    // one pixel's footprint per unit of distance, widened on cards seen at a slant (geometric mean of the two axes)
    float pxAng = 2.0 * tanH / res.y / sqrt(max(abs(d.z) / dl, 0.03));
    int n = int(U.res.w);
    float mid = 0.5 * float(n - 1);
    float gap = min(U.view.w, 0.6 * D / max(mid, 1.0));   // the front card stays well in front of the camera
    bool fromFront = d.z < 0.0;                            // seen from behind, the back card comes first
    // letterbox: the cards are cropped to the wide frame (the bars are what's around them)
    float barH = U.post.z * max(0.07, (1.0 - asp / 2.39) * 0.5);
    float4 acc = 0.0;
    for (int k = 0; k < n; k++) {
        int i = fromFront ? n - 1 - k : k;
        ANL L = Ls[i];
        float op = L.a.z;
        if (op <= 0.001) continue;
        float zi = (float(i) - mid) * gap;
        float t = (zi - o.z) / d.z;
        if (t <= 0.0) continue;
        float m = (D - zi) / D;
        float2 q = (o.xy + t * d.xy) / m;
        float fq = t * dl * pxAng / m;                     // one pixel in card units (1 / res.y head-on)
        float card = cov(max(abs(q.x) - 0.5 * asp, abs(q.y) - (0.5 - barH)), fq);
        if (card <= 0.0) continue;
        // the shot's camera: roll and zoom for everything, then pan / push in by each layer's depth
        float2 qr = rot2(q, -U.cam.w);
        float sc = max(L.b.z, 0.02);
        float w = max(L.c.z, 0.0);
        bool fixedL = w < 0.005;   // depth 0: stays on the screen (overlays): no shot camera at all
        float zs = fixedL ? 1.0 : U.cam.z / max(1.0 - U.cam2.x * w, 0.2);
        float2 base = fixedL ? q : qr / zs;
        float2 shift = fixedL ? float2(0.0) : (U.cam.xy + float2(L.f.w > 0.5 ? U.cam2.w : 0.0, 0.0)) * w;
        Ctx c;
        c.p = rot2(base + shift - L.b.xy, -L.b.w) / sc;
        c.pg = rot2(base + float2(0.0, shift.y) - L.b.xy, -L.b.w) / sc;
        c.panX = shift.x / sc;
        c.px = fq / (zs * sc);
        c.t = L.c.x;
        c.r = L.a.w;
        c.style = int(L.a.y);
        c.time = U.time.x;
        c.asp = asp;
        c.c0 = rot2(shift - L.b.xy, -L.b.w) / sc;
        c.seed = L.c.w;
        c.e = L.e;
        c.f = L.f;
        float4 col = 0.0;
        switch (int(L.a.x)) {
            case 0: col = anSky(c, U); break;
            case 1: col = anClouds(c, U); break;
            case 2: col = anSun(c, U); break;
            case 3: col = anRays(c, U); break;
            case 4: col = anStars(c, U); break;
            case 5: col = anMountains(c, U); break;
            case 6: col = anMeadow(c, U); break;
            case 7: col = anTrees(c, U); break;
            case 8: col = anWater(c, U); break;
            case 9: col = anTown(c, U); break;
            case 10: col = anParticles(c, U); break;
            case 11: col = anSparkles(c, U); break;
            case 12: col = anSpeedLines(c, U); break;
            case 13: col = anBurst(c, U); break;
            case 14: col = anAura(c, U); break;
            case 15: col = anSlash(c, U); break;
            case 16: col = anWings(c, U); break;
            case 17: col = anPlanet(c, U); break;
            case 18: col = anShip(c, U); break;
            case 19: col = anFigure(c, U); break;
            case 20: col = anTitle(c, U, titles); break;
            default: break;
        }
        if (col.a <= 0.0 && max(col.r, max(col.g, col.b)) <= 0.0) continue;
        if (L.c.y != 0.0) col.rgb = max(hueRot(col.rgb, L.c.y * TAU), 0.0);
        acc += (1.0 - acc.a) * col * (op * card);
        if (acc.a > 0.996) break;
    }
    return max(acc, 0.0);
}

// ---------------------------------------------------------------- post: scale up, film look, impact frames, letterbox

/// Catmull-Rom from 5 bilinear taps (the four corner taps dropped and the rest renormalised; premultiplied colour).
static float4 catmull(texture2d<float> t, float2 uv, float2 size) {
    float2 sp = uv * size;
    float2 tp = floor(sp - 0.5) + 0.5;
    float2 f = sp - tp;
    float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    float2 w3 = f * f * (-0.5 + 0.5 * f);
    float2 w12 = w1 + w2;
    float2 t0 = (tp - 1.0) / size, t3 = (tp + 2.0) / size, t12 = (tp + w2 / w12) / size;
    float4 r = t.sample(anLin, float2(t12.x, t0.y)) * (w12.x * w0.y)
             + t.sample(anLin, float2(t0.x, t12.y)) * (w0.x * w12.y)
             + t.sample(anLin, t12) * (w12.x * w12.y)
             + t.sample(anLin, float2(t3.x, t12.y)) * (w3.x * w12.y)
             + t.sample(anLin, float2(t12.x, t3.y)) * (w12.x * w3.y);
    float wsum = w12.x * w0.y + w0.x * w12.y + w12.x * w12.y + w3.x * w12.y + w12.x * w3.y;
    return max(r / wsum, 0.0);
}

static float lumaAt(texture2d<float> t, float2 uv) { return luma(t.sample(anLin, uv).rgb); }

fragment float4 anPostFrag(ANOut in [[stage_in]], constant ANU& U [[buffer(0)]], texture2d<float> src [[texture(0)]]) {
    float2 outS = U.outp.xy;
    float2 uv = in.position.xy / outS;
    float film = U.post.x;
    float old = U.outp.w;
    int fr = int(U.outp.z);
    float drawing = floor(U.time.x * 12.0);
    int di = int(drawing);
    // gate weave: the whole frame jitters a hair per drawing (more on old film)
    uv += (film * 0.0007 + old * 0.0016) * (float2(hash1(di * 3 + 1), hash1(di * 3 + 2)) - 0.5);
    float2 size = float2(src.get_width(), src.get_height());
    float4 col = catmull(src, uv, size);
    float cv = saturate(col.a);   // the cards' coverage: what's on the film (the rest is the window's background)
    // slight colour fringe towards the corners
    float2 cc = uv * 2.0 - 1.0;
    if (film > 0.001) {
        float2 off = cc * film * 0.0012;
        col.r = mix(col.r, src.sample(anLin, uv + off).r, 0.7);
        col.b = mix(col.b, src.sample(anLin, uv - off).b, 0.7);
    }
    float3 blur = src.sample(anMip, uv, level(3.0)).rgb * 0.6 + src.sample(anMip, uv, level(5.0)).rgb * 0.4;
    if (old > 0.001) {
        // SD softness: a broadcast-era picture had about 480 lines
        float soft = max(0.0, log2(size.y / 480.0));
        col = mix(col, src.sample(anMip, uv, level(soft)), 0.6 * old);
        // cel paint: luminance pulled into a few flat bands
        float l = max(luma(col.rgb), 1e-4);
        float b = l * 5.0;
        float lq = (floor(b) + smoothstep(0.35, 0.65, fract(b))) / 5.0;
        col.rgb *= mix(1.0, lq / l, 0.55 * old);
        // ink outlines where the paint changes, drawn again (a little differently) with every drawing
        float2 tx = max(1.0, size.y / 480.0) / size;
        float2 boil = (float2(vnoise(uv * 7.0 + drawing * 1.31), vnoise(uv * 7.0 + 40.0 + drawing * 0.77)) - 0.5) * tx * 1.6;
        float2 u2 = uv + boil;
        // one-sided: the line sits on the darker side of an edge, so small bright shapes (windows, lights) stay whole
        float lc = lumaAt(src, u2);
        float lm = max(max(lumaAt(src, u2 + float2(tx.x, 0.0)), lumaAt(src, u2 - float2(tx.x, 0.0))),
                       max(lumaAt(src, u2 + float2(0.0, tx.y)), lumaAt(src, u2 - float2(0.0, tx.y))));
        float edge = smoothstep(0.05, 0.16, lm - lc) * col.a;
        edge *= 0.75 + 0.25 * vnoise(uv * float2(90.0, 60.0) + drawing);   // the pen's pressure varies
        col.rgb = mix(col.rgb, float3(0.07, 0.04, 0.06) * col.a, edge * 0.85 * old);
        // faded film stock: less saturation, lifted plum shadows, warm highlights
        float l2 = luma(col.rgb);
        col.rgb = mix(col.rgb, float3(l2), 0.08 * old);
        col.rgb = mix(col.rgb, col.rgb * float3(1.06, 0.98, 0.9) + float3(0.05, 0.03, 0.06) * (1.0 - l2) * col.a, old);
        // the painted background's paper and brush texture
        col.rgb *= 1.0 + old * (0.06 * (fbm(uv * float2(9.0, 6.0) + 3.0) - 0.5) + 0.03 * (vnoise(uv * float2(300.0, 40.0)) - 0.5));
        // red halation round the lights
        col.rgb += max(blur - 0.5, 0.0) * float3(1.0, 0.42, 0.22) * 0.9 * old;
        // flicker, light leaks, dust and scratches
        col.rgb *= 1.0 + old * 0.05 * (hash1(di * 5 + 11) - 0.5);
        float slot = floor(U.time.x / 7.0);
        if (hash1(int(slot) * 13 + 5) > 0.45) {
            float ph = fract(U.time.x / 7.0);
            float pos = mix(-0.6, 1.8, ph);
            float dd = dot(uv - float2(0.0, 0.0), normalize(float2(1.0, 0.55))) - pos;
            float leak = exp(-dd * dd / 0.02) * smoothstep(0.0, 0.15, ph) * smoothstep(1.0, 0.8, ph);
            col.rgb += float3(1.0, 0.48, 0.14) * leak * 0.3 * old * cv;
        }
        float2 dc = floor(in.position.xy / (outS.y / 220.0));
        float dh = hash2(int2(dc) + int2(di * 31, di * 17));
        if (dh > 0.9993) {
            float2 f = fract(in.position.xy / (outS.y / 220.0)) - 0.5;
            float spot = smoothstep(0.45, 0.2, length(f));
            col.rgb = mix(col.rgb, (hash1(di + int(dc.x)) > 0.5 ? float3(0.95, 0.92, 0.85) : float3(0.05)) * cv, spot * old);
        }
        if (hash1(di * 7 + 3) > 0.7) {
            float sx = hash1(di * 7 + 4);
            float sl = exp(-abs(uv.x - sx) * outS.x / 1.2) * step(hash1(di * 7 + 5), 0.6 + 0.4 * sin(uv.y * 9.0 + sx * 20.0));
            col.rgb = mix(col.rgb, float3(0.9, 0.88, 0.8) * cv, sl * 0.35 * old);
        }
    }
    // diffusion: bright parts glow softly into their surroundings
    float3 bloom = max(blur - 0.45, 0.0) * 1.3 * film;
    col.rgb = 1.0 - (1.0 - col.rgb) * (1.0 - bloom);
    col.a = max(col.a, saturate(max(bloom.r, max(bloom.g, bloom.b))));
    // faded warm blacks, darker corners, grain
    float3 lift = float3(0.035, 0.025, 0.03) * film * col.a;
    col.rgb = col.rgb * (1.0 - 0.04 * film) + lift;
    col.rgb *= mix(float3(1.0), float3(1.03, 1.0, 0.96), film);
    float vig = 1.0 - (film * 0.28 + old * 0.2) * pow(saturate(dot(cc, cc) * 0.5), 1.4);
    col.rgb *= vig;
    float gn = (hash2(int2(in.position.xy) + int2(fr * 7, fr * 13)) - 0.5) * (0.06 * film + 0.07 * old);
    col.rgb += gn * col.a;
    // impact frame: a few frames in another look
    if (U.post.y > 0.5) {
        int look = int(U.post.w + 0.5);
        float l = luma(col.rgb);
        float2 pc = (in.position.xy - outS * 0.5) / outS.y;
        float ang = atan2(pc.y, pc.x);
        float rl = step(0.55, hash1(int(floor((ang / TAU + 0.5) * 160.0)) + di * 7)) * smoothstep(0.25, 0.6, length(pc));
        float3 paper = float3(0.97, 0.96, 0.93), inkC = float3(0.03, 0.02, 0.04);
        float3 o;
        if (look == 0) {
            // black-and-white negative, flickering back to positive every other frame
            float g = saturate((l - 0.45) * 1.8 + 0.5);
            o = float3((fr / 2) % 2 == 0 ? 1.0 - g : g);
        } else if (look == 1) {
            o = mix(inkC, paper, smoothstep(0.38, 0.46, l));
            o = mix(o, paper, rl * 0.85);
        } else if (look == 2) {
            o = l < 0.3 ? inkC : (l < 0.62 ? float3(0.75, 0.02, 0.06) : paper);
            o = mix(o, inkC, rl * 0.7);
        } else if (look == 3) {
            float2 off = pc * 0.012;
            float3 sh = float3(src.sample(anLin, uv + off).r, col.g, src.sample(anLin, uv - off).b);
            o = 1.0 - saturate(sh * 1.15);
        } else if (look == 4) {
            // pencil sketch: dark edges and hatching on paper
            float2 tx = 1.5 / size;
            float gx = lumaAt(src, uv + float2(tx.x, 0.0)) - lumaAt(src, uv - float2(tx.x, 0.0));
            float gy = lumaAt(src, uv + float2(0.0, tx.y)) - lumaAt(src, uv - float2(0.0, tx.y));
            float e = smoothstep(0.04, 0.16, length(float2(gx, gy)));
            float2 sp = in.position.xy / outS.y * 160.0;
            float h1 = step(0.55, fract(sp.x + sp.y)) * step(l, 0.45);
            float h2 = step(0.55, fract(sp.x - sp.y)) * step(l, 0.2);
            o = paper * (1.0 - 0.75 * max(e, max(h1, h2) * 0.8));
        } else {
            // manga screentone: dots on a 45° grid, bigger where it's darker
            float2 sp = rot2(in.position.xy / outS.y * 90.0, 0.785);
            float r = length(fract(sp) - 0.5);
            float dark = 1.0 - smoothstep(0.1, 0.8, l);
            float tone = smoothstep(0.03, -0.03, r - 0.62 * sqrt(dark));
            o = mix(paper, inkC, max(tone, step(l, 0.08)));
            o = mix(o, paper, rl * 0.6);
        }
        col = float4(o * cv, cv);
    }
    // over-bright colours keep their hue (clipping channels one by one turned a red glow yellow-green)
    col.rgb = max(col.rgb, 0.0);
    float mx = max(col.r, max(col.g, col.b));
    if (mx > 1.0) col.rgb = mix(col.rgb / mx, float3(1.0), saturate((mx - 1.0) * 0.25));
    return col;
}
"""
