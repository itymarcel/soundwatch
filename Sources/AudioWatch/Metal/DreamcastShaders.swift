import Foundation

// Dreamcast mode: MSL source (own library, compiled at runtime by DreamcastGPU).
// Pass 1 `dcLayersFrag` draws the layer stack at the console resolution (front-to-back, each layer a procedural
// function of its own coordinates), then quantises to RGB555 with an ordered dither.
// Pass 2 `dcCrtFrag` shows that picture full size: barrel warp, rounded screen edge, sharp pixels or (CRT style)
// gaussian scanline beams, aperture grille, halation, vignette and a little noise.
//
// Layer coordinates: y up, the screen is y −0.5 … 0.5 and x ±aspect/2 (the horizon of the scenery layers is y = 0);
// a layer's X / Y / Scale / Rotation transform them. `px` = one console pixel in layer units.
// `DCU` ↔ `DCUniforms`, `DCL` ↔ `DCLayerUniforms`, `DCT` ↔ `DCTextItem` (DreamcastGPU.swift): keep them in step.

/// The HUD font: 5 × 7 glyphs for ASCII 32 … 95 (lowercase is upper-cased on the CPU; '*' is a small ×).
enum DreamcastFont {
    static let glyphs: [Character: [String]] = [
        "0": [".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."],
        "1": ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."],
        "2": [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"],
        "3": ["#####", "...#.", "..#..", "...#.", "....#", "#...#", ".###."],
        "4": ["...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."],
        "5": ["#####", "#....", "####.", "....#", "....#", "#...#", ".###."],
        "6": ["..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###."],
        "7": ["#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."],
        "8": [".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."],
        "9": [".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.."],
        "A": [".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
        "B": ["####.", "#...#", "#...#", "####.", "#...#", "#...#", "####."],
        "C": [".###.", "#...#", "#....", "#....", "#....", "#...#", ".###."],
        "D": ["###..", "#..#.", "#...#", "#...#", "#...#", "#..#.", "###.."],
        "E": ["#####", "#....", "#....", "####.", "#....", "#....", "#####"],
        "F": ["#####", "#....", "#....", "####.", "#....", "#....", "#...."],
        "G": [".###.", "#...#", "#....", "#.###", "#...#", "#...#", ".####"],
        "H": ["#...#", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
        "I": [".###.", "..#..", "..#..", "..#..", "..#..", "..#..", ".###."],
        "J": ["..###", "...#.", "...#.", "...#.", "...#.", "#..#.", ".##.."],
        "K": ["#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#"],
        "L": ["#....", "#....", "#....", "#....", "#....", "#....", "#####"],
        "M": ["#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#"],
        "N": ["#...#", "#...#", "##..#", "#.#.#", "#..##", "#...#", "#...#"],
        "O": [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
        "P": ["####.", "#...#", "#...#", "####.", "#....", "#....", "#...."],
        "Q": [".###.", "#...#", "#...#", "#...#", "#.#.#", "#..#.", ".##.#"],
        "R": ["####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#"],
        "S": [".####", "#....", "#....", ".###.", "....#", "....#", "####."],
        "T": ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."],
        "U": ["#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
        "V": ["#...#", "#...#", "#...#", "#...#", "#...#", ".#.#.", "..#.."],
        "W": ["#...#", "#...#", "#...#", "#.#.#", "#.#.#", "#.#.#", ".#.#."],
        "X": ["#...#", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#...#"],
        "Y": ["#...#", "#...#", ".#.#.", "..#..", "..#..", "..#..", "..#.."],
        "Z": ["#####", "....#", "...#.", "..#..", ".#...", "#....", "#####"],
        ":": [".....", ".##..", ".##..", ".....", ".##..", ".##..", "....."],
        "'": ["..#..", "..#..", ".#...", ".....", ".....", ".....", "....."],
        "\"": [".#.#.", ".#.#.", "#.#..", ".....", ".....", ".....", "....."],
        "-": [".....", ".....", ".....", "#####", ".....", ".....", "....."],
        ".": [".....", ".....", ".....", ".....", ".....", ".##..", ".##.."],
        "/": ["....#", "....#", "...#.", "..#..", ".#...", "#....", "#...."],
        "!": ["..#..", "..#..", "..#..", "..#..", "..#..", ".....", "..#.."],
        "%": ["##..#", "##..#", "...#.", "..#..", ".#...", "#..##", "#..##"],
        "*": [".....", ".....", "#...#", ".#.#.", "..#..", ".#.#.", "#...#"],
    ]

    /// `constant uint2 dcFont[64]`: bit (row·5 + column) of the glyph; rows 0…5 in x, row 6 in y.
    static var msl: String {
        var items: [String] = []
        for code in 32..<96 {
            let ch = Character(UnicodeScalar(UInt8(code)))
            var lo: UInt32 = 0, hi: UInt32 = 0
            if let rows = glyphs[ch] {
                for (r, row) in rows.enumerated() {
                    for (c, cell) in row.enumerated() where cell == "#" {
                        let bit = r * 5 + c
                        if bit < 30 { lo |= 1 << UInt32(bit) } else { hi |= 1 << UInt32(bit - 30) }
                    }
                }
            }
            items.append("uint2(\(lo)u, \(hi)u)")
        }
        return "constant uint2 dcFont[64] = {\n" + items.joined(separator: ",\n") + "\n};\n"
    }
}

/// Our own 8 × 8 sprites, 2 bits per pixel ('.' = clear, 'a' / '#', 'b', 'c' = the three colours the shader picks).
/// The order is their number in the shader (`dcSpr[i]`).
enum DreamcastSprites {
    static let list: [[String]] = [
        // 0, 1: alien "jelly" (two frames)
        ["...##...", "..####..", ".#.##.#.", "########", "########", ".#.#.#.#", "#.#.#.#.", "........"],
        ["...##...", "..####..", ".#.##.#.", "########", "########", "#.#.#.#.", ".#.#.#.#", "........"],
        // 2, 3: alien "one-eye blob"
        ["..####..", ".######.", "##....##", "##.##.##", "##....##", ".######.", ".#....#.", "#......#"],
        ["..####..", ".######.", "##....##", "###..###", "##....##", ".######.", "..#..#..", "..#..#.."],
        // 4, 5: alien "moth"
        ["#......#", "##.##.##", ".######.", "..#..#..", ".######.", "##.##.##", "#......#", "........"],
        ["........", "#..##..#", "########", "..#..#..", "########", "#..##..#", "........", "........"],
        // 6: explosion
        ["#..#..#.", ".#.#.#..", "..#.#...", "##...###", "...#.#..", "..#.#.#.", ".#..#..#", "........"],
        // 7: cannon
        ["........", "...##...", "...##...", ".######.", "########", "########", "##....##", "........"],
        // 8: runner, upper half (a = outline / hair, b = skin, c = cap and shirt)
        ["..cccc..", ".ccccccc", ".aabab..", ".abbbbb.", "..bbbb..", ".cccccc.", "bccccccb", "bccccccb"],
        // 9, 10, 11: runner legs, run cycle
        [".cccccc.", ".aaaaaa.", ".aa..aa.", ".aa..aa.", ".aa..aa.", ".aa..aa.", "aaa..aaa", "........"],
        [".cccccc.", ".aaaaaa.", ".aa..aa.", "aa....aa", "a......a", "a......a", "aa....aa", "........"],
        [".cccccc.", ".aaaaaa.", "..aaaa..", "..aaa...", "..aaa...", "..aa....", "..aaa...", "........"],
        // 12: runner legs, jumping
        [".cccccc.", ".aaaaaa.", "aa...aa.", "a.....aa", "a......a", ".......a", "........", "........"],
    ]

    /// `constant uint4 dcSpr[N]`: pixel (x, y) = 2 bits at bit (y·8 + x)·2.
    static var msl: String {
        var items: [String] = []
        for rows in list {
            var w = [UInt32](repeating: 0, count: 4)
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() {
                    let v: UInt32 = ch == "b" ? 2 : ch == "c" ? 3 : (ch == "." ? 0 : 1)
                    let bit = (y * 8 + x) * 2
                    w[bit / 32] |= v << UInt32(bit % 32)
                }
            }
            items.append("uint4(\(w[0])u, \(w[1])u, \(w[2])u, \(w[3])u)")
        }
        return "constant uint4 dcSpr[\(list.count)] = {\n" + items.joined(separator: ",\n") + "\n};\n"
    }
}

/// The NES's colours (the common 2C02 emulator palette, blacks merged): the NES console look snaps to the nearest.
enum DreamcastNESPalette {
    static let hex: [UInt32] = [
        0x7C7C7C, 0x0000FC, 0x0000BC, 0x4428BC, 0x940084, 0xA80020, 0xA81000, 0x881400, 0x503000, 0x007800, 0x006800, 0x005800, 0x004058, 0x000000,
        0xBCBCBC, 0x0078F8, 0x0058F8, 0x6844FC, 0xD800CC, 0xE40058, 0xF83800, 0xE45C10, 0xAC7C00, 0x00B800, 0x00A800, 0x00A844, 0x008888,
        0xF8F8F8, 0x3CBCFC, 0x6888FC, 0x9878F8, 0xF878F8, 0xF85898, 0xF87858, 0xFCA044, 0xF8B800, 0xB8F818, 0x58D854, 0x58F898, 0x00E8D8, 0x787878,
        0xA4E4FC, 0xB8B8F8, 0xD8B8F8, 0xF8B8F8, 0xF8A4C0, 0xF0D0B0, 0xFCE0A8, 0xF8D878, 0xD8F878, 0xB8F8B8, 0xB8F8D8, 0x00FCFC, 0xF8D8F8,
    ]
    static var msl: String {
        let items = hex.map { h in
            String(format: "float3(%.4f, %.4f, %.4f)", Double((h >> 16) & 255) / 255, Double((h >> 8) & 255) / 255, Double(h & 255) / 255)
        }
        return "constant float3 dcNES[\(hex.count)] = {\n" + items.joined(separator: ",\n") + "\n};\n"
    }
}

let dreamcastShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct DCU {
    float4 res;      // console width, height (pixels), aspect, layer count
    float4 music;    // bass, mid, treble (relative levels 0…1), loudness 0…1
    float4 hits;     // kick, snare, hat pulses, beat pulse
    float4 crt;      // CRT style, warp, time (s), console (DCConsole.shaderIndex)
    float4 outp;     // output width, height (pixels), pixel aspect (width / height), screen width (share of the window)
    float4 bands[4]; // 16 relative band levels
    float4 peaks[4]; // the equalizer's falling peaks
    float4 pal[4];   // the palette at 0, ⅓, ⅔, 1 (with the colour offset)
    float4 cam[3];   // the orbit camera's rotation (rows: world → view)
    float4 view;     // zoom, pan x, pan y (in half-screens, y up), screen height (share of the window)
};
struct DCL {
    float4 a;   // kind, style, opacity, music amount (react)
    float4 b;   // offset x, y (layer units), scale, rotation (rad)
    float4 c;   // clock, hue turn, then per kind: HUD / scroller text start + count; aliens' march offset x, rows down
    uint4 d;    // per kind: alive masks (aliens, bricks), exploding alien, animation frame
    float4 e;   // per kind: cannon x, bullet x, y; ball x, y, paddle x; jump height, airborne; scroll fraction, left, base
};
struct DCT {
    float4 pos; // top-left x, y (layer units), font pixel size, style (≥ 16: a bar)
    uint4 ch;   // 16 characters, 4 per word (first in the low byte); bars: x = cells, y = fill × 1000
};

//@FONT@
#define NES_COUNT 54

struct DCOut { float4 position [[position]]; };

vertex DCOut dcVert(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    DCOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

constexpr sampler dcLin(filter::linear, address::clamp_to_edge);
constant float PI = 3.14159265;

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
constant float dcBayer[16] = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };
/// Ordered-dither threshold of a console pixel (0 … 1).
static float bay(int2 ip) { return (dcBayer[(ip.y & 3) * 4 + (ip.x & 3)] + 0.5) / 16.0; }
/// t quantised to `steps` levels, dithered between them (the banded pixel-art gradient).
static float dq(float t, float steps, float b) { return floor(t * steps + b) / steps; }
static float2 rot2(float2 p, float a) { float s = sin(a), c = cos(a); return float2(c * p.x - s * p.y, s * p.x + c * p.y); }
static float cross2(float2 a, float2 b) { return a.x * b.y - a.y * b.x; }
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
static float3 hueRot(float3 c, float a) {
    float3x3 toYIQ = float3x3(float3(0.299, 0.596, 0.211), float3(0.587, -0.274, -0.523), float3(0.114, -0.322, 0.312));
    float3x3 toRGB = float3x3(float3(1.0, 1.0, 1.0), float3(0.956, -0.272, -1.106), float3(0.621, -0.647, 1.703));
    float3 y = toYIQ * c;
    float s = sin(a), co = cos(a);
    y.yz = float2(co * y.y - s * y.z, s * y.y + co * y.z);
    return toRGB * y;
}
static float bandOf(constant DCU& U, int i) { i = clamp(i, 0, 15); return U.bands[i >> 2][i & 3]; }
static float peakOf(constant DCU& U, int i) { i = clamp(i, 0, 15); return U.peaks[i >> 2][i & 3]; }
static float3 grad4(float g, float3 top, float3 b, float3 c, float3 hor) {
    g = saturate(g) * 3.0;
    if (g < 1.0) return mix(hor, c, g);
    if (g < 2.0) return mix(c, b, g - 1.0);
    return mix(b, top, g - 2.0);
}
static float luma(float3 c) { return dot(c, float3(0.299, 0.587, 0.114)); }
/// A fixed rainbow (demo-style bars and letters, whatever the palette).
static float3 rainbow(float t) {
    return saturate(0.55 + 0.5 * cos(6.2831853 * (fract(t) + float3(0.0, 0.33, 0.67))));
}
/// The palette as a loop through its four stops (t wraps).
static float3 pal4(constant DCU& U, float t) {
    t = fract(t) * 4.0;
    int i = int(t);
    return mix(U.pal[i & 3].rgb, U.pal[(i + 1) & 3].rgb, t - float(i));
}
/// A sprite's pixel (0 = clear, 1 … 3 = its colours); y from the top.
static int sprPix(int id, int x, int y) {
    if (x < 0 || y < 0 || x > 7 || y > 7) return 0;
    int bit = (y * 8 + x) * 2;
    uint4 w = dcSpr[id];
    return int((w[bit >> 5] >> uint(bit & 31)) & 3u);
}
/// A font glyph's pixel (code = ASCII 32 … 95; x 0 … 4, y 0 … 6 from the top).
static bool glyphBit(uint code, int x, int y) {
    if (x < 0 || y < 0 || x > 4 || y > 6 || code < 32u || code > 95u) return false;
    uint2 g = dcFont[code - 32u];
    int bit = y * 5 + x;
    return bit < 30 ? ((g.x >> uint(bit)) & 1u) != 0u : ((g.y >> uint(bit - 30)) & 1u) != 0u;
}

struct Ctx {
    float2 p;     // layer coordinates
    float px;     // one console pixel in layer units
    int2 ip;      // console pixel (dither)
    float t;      // the layer's clock (Speed × music)
    float r;      // the layer's Music amount
    int style;
    float time;   // seconds
};

// ---------------------------------------------------------------- sky

static float4 dcSky(Ctx c, constant DCU& U) {
    float g = saturate(c.p.y * 2.2);
    float b = bay(c.ip);
    float gq = dq(g, 12.0, b);
    int s = c.style;
    float3 col;
    if (s == 0) col = grad4(gq, float3(0.04, 0.16, 0.62), float3(0.10, 0.36, 0.90), float3(0.30, 0.62, 1.0), float3(0.70, 0.90, 1.0));
    else if (s == 1) col = grad4(gq, float3(0.16, 0.04, 0.30), float3(0.50, 0.08, 0.46), float3(0.96, 0.30, 0.42), float3(1.0, 0.74, 0.34));
    else if (s == 2) col = grad4(gq, float3(0.02, 0.02, 0.12), float3(0.13, 0.08, 0.36), float3(0.50, 0.22, 0.58), float3(0.96, 0.52, 0.58));
    else if (s == 3) col = grad4(gq, float3(0.0, 0.0, 0.02), float3(0.01, 0.02, 0.09), float3(0.04, 0.06, 0.20), float3(0.12, 0.12, 0.30));
    else if (s == 5) {
        // hard colour bands, thinner towards the horizon (the 2600 changed colour per line, no dithering)
        float band = floor(sqrt(g) * 9.0);
        col = grad4(band / 8.0, float3(0.10, 0.05, 0.45), float3(0.75, 0.10, 0.45), float3(1.0, 0.40, 0.10), float3(1.0, 0.85, 0.20));
    } else {
        col = float3(0.0, 0.0, 0.015);
        float n = fbm(c.p * 2.5 + float2(c.t * 0.02, 0.0));
        n = saturate((n - 0.45) * 2.2);
        col += dq(n * 0.45, 4.0, b) * mix(U.pal[0].rgb, U.pal[2].rgb, vnoise(c.p * 1.5 + 4.0));
    }
    // the beat brightens the horizon
    if (s < 4 || s == 5) col += (1.0 - g) * (1.0 - g) * U.hits.w * c.r * 0.3 * float3(1.0, 0.85, 0.7);
    if (s >= 3) {
        int2 cell = int2(floor(c.p / c.px));
        float h = hash2(cell);
        if (h > 0.992) {
            float tw = 0.55 + 0.45 * sin(c.time * (1.5 + 5.0 * hash2(cell + 7)) + h * 80.0);
            if (hash2(cell + 3) > 0.5) tw += U.music.z * c.r;
            col += dq(saturate(tw), 3.0, b) * mix(float3(0.85, 0.9, 1.0), float3(1.0, 0.9, 0.7), hash2(cell + 11));
        }
    }
    return float4(col, 1.0);
}

// ---------------------------------------------------------------- clouds

static float cloudField(float x, float y0, float t, float swell) {
    float d = fbm(float2(x * 2.6, y0 * 5.5 - t * 0.01));
    float prof = 1.0 - y0 / (0.18 + 0.25 * vnoise(float2(x * 1.3, 3.7)));
    return d * 0.9 + prof * 0.55 - 0.74 + 0.12 * swell;
}

static float4 dcClouds(Ctx c, constant DCU& U) {
    float2 p = c.p;
    float t = c.t;
    float b = bay(c.ip);
    float swell = c.r * U.music.w;
    if (c.style == 0) {
        float y0 = p.y - 0.02;
        if (y0 < 0.0 || y0 > 0.48) return 0.0;
        float x = p.x + t * 0.04;
        float v = cloudField(x, y0, t, swell);
        if (v < 0.0) return 0.0;
        float vUp = cloudField(x, y0 + 0.02, t, swell);
        float lit = saturate(0.5 + (v - vUp) * 7.0 + y0 * 0.8);
        float q = dq(lit, 3.0, b);
        float3 col = q < 0.3 ? float3(0.60, 0.68, 0.86) : (q < 0.6 ? float3(0.80, 0.86, 0.97) : (q < 0.9 ? float3(0.94, 0.96, 1.0) : float3(1.0)));
        return float4(col, 1.0);
    }
    if (c.style == 1) {
        float y0 = p.y;
        if (y0 < 0.06 || y0 > 0.48) return 0.0;
        float wav = sin(p.x * 5.0 + t * 0.5 + y0 * 30.0) * 0.006 * (1.0 + 2.5 * c.r * U.music.x);
        float v = (y0 + wav) * 44.0;
        float row = floor(v);
        int ri = int(row);
        float x = p.x * (0.8 + 0.8 * hash1(ri)) + t * (0.03 + 0.05 * hash1(ri + 11)) + row * 3.1;
        float n = vnoise(float2(x * 2.2, row * 1.7)) * 0.75 + vnoise(float2(x * 8.0, row)) * 0.25;
        float fr = fract(v);
        // wisps thin out towards the horizon and towards their ends
        float dens = saturate((y0 - 0.06) * 6.0);
        float thick = (0.2 + 0.7 * saturate((n - 0.5) * 4.0)) * dens;
        if (n < 0.52 - 0.08 * swell || abs(fr - 0.5) > thick * 0.5) return 0.0;
        float k = hash1(ri + 5);
        float3 col = mix(float3(0.98, 0.34, 0.36), float3(1.0, 0.62, 0.30), k);
        col = mix(col, float3(0.60, 0.16, 0.44), saturate((y0 - 0.22) * 3.0) * 0.75);
        if (fr < 0.5 - thick * 0.25) col = mix(col, float3(1.0, 0.86, 0.56), 0.45);
        return float4(col, 1.0);
    }
    // haze bands: dithered see-through stripes over the horizon
    float y0 = p.y;
    float v = 0.5 + 0.5 * sin(y0 * 60.0 + t * 0.6);
    float a = v * saturate(1.0 - abs(y0 - 0.06) * 6.0) * (0.55 + 0.45 * swell);
    if (bay(c.ip) > a) return 0.0;
    return float4(mix(U.pal[1].rgb, float3(1.0, 0.85, 0.9), 0.4), 1.0);
}

// ---------------------------------------------------------------- sun / moon

static float4 dcSun(Ctx c, constant DCU& U) {
    float2 p = c.p;
    float R = 0.16 * (1.0 + 0.16 * c.r * U.music.x + 0.05 * c.r * U.hits.x);
    float d = length(p);
    float b = bay(c.ip);
    if (c.style == 0) {
        if (d < R) {
            float g = p.y / R;
            float3 col = mix(float3(1.0, 0.24, 0.56), float3(1.0, 0.92, 0.32), dq(saturate(0.5 + 0.5 * g), 7.0, b));
            if (g < 0.15) {
                float u = 0.15 - g;
                float ph = fract(u * 5.5 + c.t * 0.35);
                if (ph < u * 0.5) return 0.0;
            }
            return float4(col, 1.0);
        }
        float a = saturate(dq(exp(-(d - R) * 14.0) * 0.55, 4.0, b));
        return float4(float3(1.0, 0.35, 0.55) * a, a);
    }
    if (c.style == 1) {
        if (d < R) {
            float2 q = p / R;
            float cr = vnoise(q * 4.0 + 3.1) * 0.6 + vnoise(q * 9.0 + 1.7) * 0.4;
            float3 n = normalize(float3(q, sqrt(max(0.0, 1.0 - dot(q, q)))));
            float shade = saturate(0.55 + 0.5 * dot(n, normalize(float3(-0.5, 0.5, 0.7))));
            float3 col = cr > 0.58 ? float3(0.82, 0.48, 0.30) : float3(1.0, 0.78, 0.48);
            col *= dq(shade, 4.0, b) * 0.45 + 0.55;
            return float4(col, 1.0);
        }
        float a = saturate(dq(exp(-(d - R) * 20.0) * 0.45, 3.0, b));
        return float4(float3(1.0, 0.7, 0.5) * a, a);
    }
    float core = R * 0.55;
    if (d < core) return float4(1.0, 1.0, 0.92, 1.0);
    float ang = atan2(p.y, p.x);
    float rays = pow(abs(cos(ang * 4.0 + c.t * 0.15)), 30.0) * exp(-(d - core) * 7.0) * 0.8;
    float a = saturate(dq(exp(-(d - core) * 11.0) * 1.15 + rays, 5.0, b));
    if (a <= 0.0) return 0.0;
    float3 col = mix(float3(1.0, 0.8, 0.35), float3(1.0, 1.0, 0.9), a);
    return float4(col * a, a);
}

// ---------------------------------------------------------------- skyline

static float4 dcSkyline(Ctx c, constant DCU& U) {
    float2 p = c.p;
    if (p.y > 0.45 || p.y < -0.5) return 0.0;
    int s = c.style;
    float b = bay(c.ip);
    if (s <= 1) {
        if (p.y < 0.0) return 0.0;
        for (int row = 0; row < 2; row++) {
            float w = row == 0 ? 0.075 : 0.045;
            float x = p.x + c.t * (row == 0 ? 0.05 : 0.025) + float(row) * 13.7;
            float ci = floor(x / w);
            float fx = x / w - ci;
            int id = int(ci) * 2 + row;
            float hh = hash1(id);
            float gapL = 0.06 + 0.2 * hash1(id + 101), gapR = 0.94 - 0.15 * hash1(id + 202);
            float H = row == 0 ? 0.04 + 0.13 * hh * hh : 0.07 + 0.2 * hh * hh;
            H += c.r * (row == 0 ? 0.07 : 0.1) * bandOf(U, int(hash1(id + 7) * 16.0));
            bool inX = fx > gapL && fx < gapR;
            bool ant = hh > 0.75 && abs(fx - 0.5) * w < c.px * 0.6 && p.y >= H && p.y < H + 0.035;
            if (!((inX && p.y < H) || ant)) continue;
            float3 col = s == 0 ? (row == 0 ? float3(0.07, 0.40, 0.47) : float3(0.78, 0.18, 0.45))
                                : (row == 0 ? float3(0.02, 0.02, 0.05) : float3(0.10, 0.08, 0.20));
            if (ant) {
                if (p.y > H + 0.028 && fract(c.time * 0.8 + hh * 5.0) < 0.5) col = float3(1.0, 0.2, 0.2);
                return float4(col, 1.0);
            }
            float lx = (fx - gapL) * w, ly = p.y;
            int wx = int(floor(lx / c.px)), wy = int(floor(ly / c.px));
            if ((wx & 1) == 1 && (wy % 3) != 0 && ly < H - 2.0 * c.px && lx < (gapR - gapL) * w - c.px) {
                float lh = hash2(int2(wx / 2 + id * 37, wy / 3));
                float flick = hash2(int2(wx / 2 + id * 37, wy / 3 + int(c.time * (1.0 + 6.0 * U.music.z * c.r)) * 17));
                if (lh < 0.3 + 0.3 * U.music.w * c.r || flick > 0.93) {
                    float3 wc = s == 0 ? mix(float3(1.0, 0.85, 0.5), U.pal[int(lh * 4.0) & 3].rgb, 0.5) : float3(1.0, 0.82, 0.4);
                    if (row == 1) wc *= 0.6;
                    col = wc;
                }
            }
            if (row == 1 && s == 0) col = mix(col, float3(0.95, 0.45, 0.55), 0.25);
            return float4(col, 1.0);
        }
        return 0.0;
    }
    for (int row = 0; row < 2; row++) {
        float x = p.x + c.t * (row == 0 ? 0.05 : 0.02) + float(row) * 7.3;
        float H;
        if (s == 2) {
            H = 0.035 + 0.05 * vnoise(float2(x * 2.2, float(row) * 5.1)) + 0.02 * vnoise(float2(x * 7.0, float(row))) + float(row) * 0.04;
        } else {
            float n = vnoise(float2(x * 2.8, float(row) * 3.3));
            float ridge = 1.0 - abs(n * 2.0 - 1.0);
            H = 0.03 + 0.12 * ridge * ridge + 0.02 * vnoise(float2(x * 11.0, float(row))) + float(row) * 0.035;
        }
        H += c.r * 0.04 * bandOf(U, int(fract(x * 0.7) * 16.0));
        if (p.y >= H) continue;
        float3 col;
        if (s == 2) {
            col = row == 0 ? float3(0.18, 0.55, 0.22) : float3(0.30, 0.52, 0.48);
            if (dq(vnoise(p * float2(60.0, 90.0)), 2.0, b) > 0.5) col *= 0.85;
        } else {
            col = row == 0 ? float3(0.30, 0.12, 0.42) : float3(0.55, 0.28, 0.58);
            float sl = vnoise(float2(x * 2.8 + 0.01, float(row) * 3.3)) - vnoise(float2(x * 2.8 - 0.01, float(row) * 3.3));
            if (dq(saturate(0.5 + sl * 20.0), 2.0, b) > 0.5) col *= 1.18;
            // snow above a fixed altitude (only the high peaks), with a dithered snow line
            if (p.y > 0.125 + float(row) * 0.035 + (b - 0.5) * 0.008) col = row == 0 ? float3(0.92, 0.86, 1.0) : float3(0.9, 0.72, 0.9);
            if (row == 1) col = mix(col, float3(0.95, 0.5, 0.65), 0.2);
        }
        return float4(col, 1.0);
    }
    return 0.0;
}

// ---------------------------------------------------------------- ocean

static float4 dcOcean(Ctx c, constant DCU& U) {
    float2 p = c.p;
    if (p.y > 0.0) return 0.0;
    float u = -p.y + 0.002;
    float z = 0.06 / u;
    float b = bay(c.ip);
    int s = c.style;
    float3 hor, nearC, hi;
    if (s == 0) { hor = float3(0.62, 0.88, 0.95); nearC = float3(0.04, 0.30, 0.72); hi = float3(0.85, 1.0, 1.0); }
    else if (s == 1) { hor = float3(1.0, 0.62, 0.42); nearC = float3(0.22, 0.08, 0.32); hi = float3(1.0, 0.9, 0.6); }
    else { hor = float3(0.12, 0.14, 0.32); nearC = float3(0.01, 0.02, 0.07); hi = float3(0.7, 0.75, 1.0); }
    float g = saturate(u * 3.0);
    float3 col = mix(hor, nearC, dq(g, 8.0, b));
    float wx = p.x * z * 2.0, wz = z + c.t * 0.6;
    // wave crests: short dashes along rows (thin near the horizon, wider in front), more with the treble
    float w = sin(wz * 7.0 + vnoise(float2(wx * 1.5, wz * 0.8)) * 7.0 + c.time * 0.8);
    float m = vnoise(float2(wx * 3.0, wz * 2.0));
    float thr = 0.9 - 0.08 * c.r * U.music.z;
    if (w > thr && m > 0.5) col = mix(col, hi, w > thr + 0.05 ? 0.75 : 0.4);
    else if (w > thr - 0.12 && m > 0.62) col = mix(col, hi, 0.2);
    int2 cell = int2(floor(p / c.px));
    if (s == 1) {
        float wcol = 0.015 + u * 0.35;
        if (abs(p.x) < wcol && hash2(cell + int2(int(c.time * 8.0) * 31, 0)) > 0.55 + abs(p.x) / wcol * 0.35) col = hi;
    } else if (hash2(cell + int2(0, int(c.time * 6.0) * 57)) > 0.985 - 0.025 * c.r * U.music.z) {
        col = float3(1.0);
    }
    return float4(col, 1.0);
}

// ---------------------------------------------------------------- palm tree / lamp sprites

constant float4 dcFronds[6] = {
    float4(-1.0, 0.9, 2.2, 0.42), float4(-1.0, 0.25, 1.4, 0.5), float4(-1.0, -0.35, 0.9, 0.42),
    float4(1.0, 0.9, 2.2, 0.42), float4(1.0, 0.25, 1.4, 0.5), float4(1.0, -0.35, 0.9, 0.42),
};

/// A palm tree: base at (0, 0), about 1 tall. `lean` bends the trunk sideways, `sway` is the wind.
static float4 dcPalm(float2 q, float pxl, float lean, float sway) {
    float bend = lean * 0.16 + sway * 0.06;
    float2 top = float2(bend * 0.85, 0.9);
    float2 d = q - top;
    for (int i = 0; i < 6; i++) {
        float4 f = dcFronds[i];
        float dx = d.x * f.x;
        if (dx < 0.0 || dx > f.w) continue;
        float yc = f.y * dx - f.z * dx * dx + sway * 0.06 * dx;
        float th = 0.055 * sin(PI * dx / f.w) + pxl * 0.5;
        float dy = d.y - yc;
        if (abs(dy) >= th) continue;
        if (abs(dy) > th * 0.45 && fract(dx * 28.0) < 0.35) continue;
        float3 col = dy > th * 0.2 ? float3(0.38, 0.78, 0.26) : (dy > -th * 0.3 ? float3(0.18, 0.55, 0.18) : float3(0.08, 0.34, 0.12));
        return float4(col, 1.0);
    }
    if (length(d - float2(-0.022, -0.03)) < 0.02 || length(d - float2(0.02, -0.035)) < 0.02) return float4(0.36, 0.22, 0.10, 1.0);
    if (q.y >= 0.0 && q.y <= 0.92) {
        float cx = bend * q.y * q.y;
        float w = mix(0.045, 0.028, q.y) + pxl * 0.5;
        if (abs(q.x - cx) < w) {
            float ring = fract(q.y * 14.0);
            float3 col = ring < 0.3 ? float3(0.42, 0.26, 0.14) : float3(0.64, 0.44, 0.25);
            if (q.x - cx > w * 0.3) col *= 0.78;
            return float4(col, 1.0);
        }
    }
    return 0.0;
}

/// A street lamp: base at (0, 0), about 1 tall, the arm reaching towards `dir`. `glow` lights the halo.
static float4 dcLamp(float2 q, float pxl, float dir, float glow, float3 light, float b) {
    float2 head = float2(dir * 0.32, 0.98);
    float hd = length((q - head) / float2(1.0, 0.6));
    if (hd < 0.05) return float4(mix(light, float3(1.0), 0.6), 1.0);
    if (sdSeg(q, float2(0.0, 0.0), float2(0.0, 1.0)) < 0.022 + pxl * 0.5) return float4(0.30, 0.30, 0.36, 1.0);
    if (sdSeg(q, float2(0.0, 1.0), head + float2(-dir * 0.04, 0.02)) < 0.014 + pxl * 0.5) return float4(0.36, 0.36, 0.42, 1.0);
    float a = saturate(dq(exp(-hd * 9.0) * glow, 4.0, b));
    if (a <= 0.0) return 0.0;
    return float4(light * a, a);
}

// ---------------------------------------------------------------- road

static float roadCurve(float pos) { return 0.0035 * sin(pos * 0.045) + 0.002 * sin(pos * 0.017 + 1.3); }

static float4 dcRoadside(Ctx c, constant DCU& U, float pos, float curv) {
    int s = c.style;
    bool lamps = s == 4;
    float spacing = lamps ? 10.0 : 7.0;
    float side = lamps ? 1.4 : 1.75;
    float k0 = floor(pos / spacing);
    float b = bay(c.ip);
    float sway = sin(c.time * 1.3) * 0.25 + c.r * U.music.x * 0.6 * sin(c.time * 2.1);
    for (int k = 0; k < 16; k++) {
        float zw = (k0 + 1.0 + float(k)) * spacing - pos;
        if (zw < 0.55) continue;
        float sc = 0.6 / zw;
        for (int sd = 0; sd < 2; sd++) {
            float sgn = sd == 0 ? -1.0 : 1.0;
            if (s == 2 && sgn < 0.0) continue;
            int oid = int(k0) + k;
            float wxo = sgn * (side + 0.3 * hash1(oid * 2 + sd));
            float2 at = float2((wxo + curv * zw * zw) / (zw * 1.5), -sc);
            float hgt = lamps ? 2.6 : 3.4 + 0.8 * hash1(oid * 2 + sd + 77);
            float2 lp = (c.p - at) / (sc * hgt);
            if (lp.y < -0.05 || lp.y > 1.25 || abs(lp.x) > 0.8) continue;
            float pxl = c.px / (sc * hgt);
            float4 col = lamps ? dcLamp(lp, pxl, -sgn, 0.6 + 0.8 * U.hits.w * c.r, U.pal[0].rgb, b)
                               : dcPalm(lp, pxl, -sgn * (0.5 + 0.5 * hash1(oid + sd * 31)), sway + sgn * 0.1);
            if (col.a > 0.0) return col;
        }
    }
    return 0.0;
}

static float4 dcRoad(Ctx c, constant DCU& U) {
    float2 p = c.p;
    float pos = c.t * 14.0;
    float curv = roadCurve(pos);
    int s = c.style;
    bool neon = s >= 3;
    if (s == 1 || s == 2 || s == 4) {
        float4 sp = dcRoadside(c, U, pos, curv);
        if (sp.a > 0.0) return sp;
    }
    if (p.y > 0.0) return 0.0;
    float u = -p.y + 0.0005;
    float z = 0.6 / u;
    float wx = p.x * z * 1.5 - curv * z * z;
    float ax = abs(wx);
    float b = bay(c.ip);
    float zpx = 0.6 / (u * u) * c.px;
    bool lt = fract((z + pos) * 0.125) < 0.5;
    float alias = saturate((zpx - 1.0) / 3.0);
    if (alias > b) lt = ((c.ip.x + c.ip.y) & 1) == 0;
    float3 asA, asB, lineC, rumA, rumB, grA, grB;
    if (!neon) {
        asA = float3(0.42, 0.42, 0.45); asB = float3(0.38, 0.38, 0.41); lineC = float3(0.95);
        rumA = float3(0.85, 0.12, 0.12); rumB = float3(0.95); grA = float3(0.88, 0.82, 0.66); grB = float3(0.82, 0.76, 0.60);
    } else {
        asA = float3(0.20, 0.06, 0.24); asB = float3(0.23, 0.07, 0.27); lineC = float3(1.0, 0.78, 0.2);
        rumA = float3(1.0, 0.78, 0.2); rumB = float3(0.30, 0.09, 0.34); grA = float3(0.10, 0.62, 0.58); grB = float3(0.07, 0.52, 0.50);
    }
    float lineW = max(0.035, c.px * z * 1.5);
    float3 col;
    if (ax < 1.0) {
        col = lt ? asA : asB;
        if (abs(ax - 0.3333) < lineW * 0.6 && lt) col = lineC;
        if (neon && ax > 1.0 - lineW * 1.2) col = lineC * (1.0 + 0.4 * U.hits.x * c.r);
    } else if (ax < 1.12 + lineW * 0.5) {
        col = lt ? rumA : rumB;
    } else {
        if (s == 2 && wx < 0.0) return 0.0;
        col = lt ? grA : grB;
    }
    return float4(col, 1.0);
}

// ---------------------------------------------------------------- palm layer

static float4 dcPalmLayer(Ctx c, constant DCU& U) {
    float sway = sin(c.t * 1.2) * 0.4 + c.r * U.music.x * 0.9 * sin(c.time * 2.3);
    float2 base = float2(0.0, -0.45);
    if (c.style == 2) {
        float2 q = (c.p - base) / 0.6;
        return dcLamp(q, c.px / 0.6, 1.0, 0.6 + 0.9 * U.hits.w * c.r, U.pal[0].rgb, bay(c.ip));
    }
    if (c.style == 1) {
        float4 a = dcPalm((c.p - float2(0.12, -0.47)) / 0.72, c.px / 0.72, 0.8, sway);
        if (a.a > 0.0) return a;
        return dcPalm((c.p - float2(-0.1, -0.42)) / 0.6, c.px / 0.6, -0.7, sway * 0.8);
    }
    return dcPalm((c.p - base) / 0.75, c.px / 0.75, 0.6, sway);
}

// ---------------------------------------------------------------- grid

static float gridLines(float2 w, float pxA, float pxL) {
    float lx = abs(fract(w.x + 0.5) - 0.5) / max(pxA, 1e-5);
    float lz = abs(fract(w.y + 0.5) - 0.5) / max(pxL, 1e-5);
    float ix = (lx < 0.75 ? 1.0 : 0.0) * saturate(1.5 - pxA * 2.0);
    float iz = (lz < 0.75 ? 1.0 : 0.0) * saturate(1.5 - pxL * 2.0);
    return max(ix, iz);
}

static float4 dcGrid(Ctx c, constant DCU& U) {
    float2 p = c.p;
    float flash = 1.0 + c.r * (1.2 * U.hits.w + 0.8 * U.hits.x);
    float3 lc = U.pal[0].rgb, lc2 = U.pal[2].rgb;
    int s = c.style;
    float pos = c.t * 3.0;
    float b = bay(c.ip);
    if (s <= 1) {
        if (p.y > 0.0) {
            if (s == 1) return 0.0;
            float a = saturate(dq(exp(-p.y * 40.0) * 0.7 * flash, 4.0, b));
            return float4(lc2 * a, a);
        }
        float u = -p.y + 0.0008;
        float z = 0.5 / u;
        float2 w = float2(p.x * z * 2.0, z + pos);
        float pxA = c.px * z * 2.0, pxL = 0.5 / (u * u) * c.px;
        float v = gridLines(w, pxA, pxL);
        float far = saturate(pxL * 0.6) * 0.6;
        float lv = saturate(max(v, far) * flash);
        float3 lcol = mix(lc, lc2, saturate(far * 1.6));
        if (s == 1) {
            float a = saturate(dq(lv, 4.0, b));
            return float4(lcol * a, a);
        }
        float3 fill = mix(float3(0.05, 0.0, 0.10), lc2 * 0.3, dq(saturate(1.0 - u * 6.0), 5.0, b));
        return float4(mix(fill, lcol, lv), 1.0);
    }
    float2 q = s == 3 ? rot2(p, c.t * 0.15) : p;
    float W = 1.0, Hh = s == 2 ? 0.6 : 1.0;
    float kx = W / max(abs(q.x), 1e-4), ky = Hh / max(abs(q.y), 1e-4);
    float k = min(kx, ky);
    bool wall = kx < ky;
    float2 w = wall ? float2(q.y * k * 2.0, k + pos) : float2(q.x * k * 2.0, k + pos);
    float pxA = c.px * k * 2.0;
    float pxL = k * k / (wall ? W : Hh) * c.px;
    float v = gridLines(w, pxA, pxL);
    float far = saturate(pxL * 0.6) * 0.5;
    float depth = saturate(1.3 - k / 30.0);
    float lv = saturate(max(v, far) * flash) * depth;
    float3 col = s == 2 ? float3(0.95) * lv : mix(lc2, lc, depth) * lv;
    return float4(col, 1.0);
}

// ---------------------------------------------------------------- checkerboard

static float4 dcChecker(Ctx c, constant DCU& U) {
    float2 p = c.p;
    float b = bay(c.ip);
    int s = c.style;
    float kick = c.r * U.hits.x;
    float3 ca, cb;
    bool chk;
    float shade = 1.0;
    if (s == 0) {
        if (p.y > 0.0) return 0.0;
        float u = -p.y + 0.0008;
        float z = 0.45 / u;
        float2 w = rot2(float2(p.x * z * 2.0, z), sin(c.t * 0.1) * 0.6);
        w.y += c.t * 2.5;
        float pxW = 0.45 / (u * u) * c.px;
        chk = ((int(floor(w.x)) + int(floor(w.y))) & 1) == 0;
        if (saturate(pxW * 1.2 - 0.4) > b) chk = ((c.ip.x + c.ip.y) & 1) == 0;
        ca = float3(0.12, 0.22, 0.86); cb = float3(1.0, 0.62, 0.14);
        shade = 0.5 + 0.5 * dq(saturate(u * 3.0), 5.0, b);
    } else if (s == 1) {
        float2 w = p / 0.08 + float2(c.t * 1.5, c.t * 0.8);
        chk = ((int(floor(w.x)) + int(floor(w.y))) & 1) == 0;
        ca = U.pal[0].rgb * 0.8; cb = U.pal[1].rgb * 0.35;
    } else {
        float2 w = p / 0.07;
        w.x += sin(w.y * 0.5 + c.t * 2.0) * 1.2 * (1.0 + c.r * U.music.x);
        w.y += sin(w.x * 0.4 + c.t * 1.6) * 0.8;
        chk = ((int(floor(w.x)) + int(floor(w.y))) & 1) == 0;
        ca = U.pal[0].rgb; cb = U.pal[3].rgb * 0.5;
    }
    float3 col = (chk ? ca : cb) * shade;
    col = mix(col, float3(1.0), saturate(kick * 0.4));
    return float4(col, 1.0);
}

// ---------------------------------------------------------------- stars

static float4 dcStars(Ctx c, constant DCU& U) {
    float2 p = c.p;
    float b = bay(c.ip);
    int s = c.style;
    if (s == 0) {
        int2 cell = int2(floor(p / c.px));
        float h = hash2(cell);
        if (h < 0.985) return 0.0;
        float tw = 0.5 + 0.5 * sin(c.t * 3.0 * (0.5 + hash2(cell + 9)) + h * 100.0);
        tw += U.music.z * c.r * hash2(cell + 5);
        float v = saturate(dq(saturate(tw), 3.0, b) + 0.34);
        float3 col = mix(float3(0.85, 0.9, 1.0), mix(float3(1.0, 0.9, 0.7), U.pal[1].rgb, 0.4), hash2(cell + 13));
        return float4(col * v, v);
    }
    if (s == 1) {
        for (int i = 2; i >= 0; i--) {
            float x = p.x + c.t * 0.03 * float(i + 1) + float(i) * 11.0;
            int2 cell = int2(floor(float2(x, p.y) / c.px)) + int2(0, i * 1000);
            if (hash2(cell) > 0.996 - 0.001 * float(i)) {
                float v = 0.35 + 0.3 * float(i) + 0.2 * U.music.z * c.r;
                v = saturate(v);
                return float4(float3(0.9, 0.92, 1.0) * v, v);
            }
        }
        return 0.0;
    }
    float rho = length(p);
    float ang = atan2(p.y, p.x);
    float nb = 160.0;
    float bi = floor((ang / (2.0 * PI) + 0.5) * nb);
    for (int j = 0; j < 3; j++) {
        float h = hash1(int(bi) * 3 + j);
        float h2 = hash1(int(bi) * 3 + j + 7777);
        float z = fract(h - c.t * (0.15 + 0.2 * h2));
        float rs = 0.03 / max(z, 0.02);
        float len = rs * 0.12 * (1.0 + 2.0 * c.r * U.music.w);
        float a0 = (bi + 0.3 + 0.4 * h2) / nb * 2.0 * PI - PI;
        float dAng = abs(ang - a0) * rho;
        if (dAng < c.px * 0.7 && rho > rs && rho < rs + len + c.px) {
            float v = saturate(1.3 - z);
            return float4(float3(0.9, 0.95, 1.0) * v, v);
        }
    }
    return 0.0;
}

// ---------------------------------------------------------------- planet

static float4 dcPlanet(Ctx c, constant DCU& U) {
    float R = 0.28;
    float2 q = c.p / R;
    float d2 = dot(q, q);
    float b = bay(c.ip);
    int s = c.style;
    float glow = 0.35 + c.r * U.music.x * 1.2;
    float3 atm = s == 0 ? float3(1.0, 0.5, 0.2) : (s == 1 ? float3(1.0, 0.85, 0.6) : (s == 2 ? float3(0.6, 0.8, 1.0) : float3(0.4, 0.7, 1.0)));
    if (s == 1) {
        float2 rq = rot2(q, 0.35);
        float rr = length(float2(rq.x, rq.y / 0.28));
        if (rr > 1.35 && rr < 2.1 && (rq.y < 0.0 || d2 > 1.0)) {
            float bd = fract(rr * 6.0);
            if (bd > 0.2) {
                float3 rc = bd > 0.6 ? float3(0.62, 0.52, 0.42) : float3(0.88, 0.78, 0.58);
                if (rq.y > 0.0 && d2 < 1.6) rc *= 0.5;
                return float4(rc, 1.0);
            }
        }
    }
    if (d2 > 1.0) {
        float a = saturate(dq(exp(-(sqrt(d2) - 1.0) * 18.0) * glow, 4.0, b));
        return float4(atm * a, a);
    }
    float zc = sqrt(1.0 - d2);
    float3 n = float3(q, zc);
    float lon = atan2(q.x, zc) + c.t * 0.25;
    float lat = asin(clamp(q.y, -1.0, 1.0));
    float2 sp = float2(lon, lat);
    float3 col;
    float jit = (b - 0.5) * 0.05;
    if (s == 0) {
        float v = fbm(float2(lon * 1.6, lat * 2.4) + fbm(float2(lon * 0.8 + 3.0, lat * 1.2)) * 1.5) + jit;
        col = v < 0.45 ? float3(0.62, 0.08, 0.04) : (v < 0.58 ? float3(0.95, 0.32, 0.08) : float3(1.0, 0.62, 0.18));
    } else if (s == 1) {
        float v = lat * 3.5 + 0.35 * fbm(float2(lon * 2.0, lat * 10.0)) + jit;
        float k = hash1(int(floor(v)) + 40);
        col = k < 0.33 ? float3(0.93, 0.86, 0.68) : (k < 0.66 ? float3(0.78, 0.55, 0.35) : float3(0.95, 0.62, 0.30));
    } else if (s == 2) {
        float v = fbm(sp * float2(2.0, 3.0)) + jit;
        col = v > 0.55 ? float3(0.45, 0.65, 0.95) : float3(0.78, 0.9, 1.0);
        if (abs(vnoise(sp * 8.0) - 0.5) < 0.03) col = float3(0.3, 0.45, 0.8);
    } else {
        float v = fbm(sp * float2(1.5, 2.2)) + jit;
        col = v > 0.52 ? mix(float3(0.22, 0.55, 0.2), float3(0.6, 0.5, 0.3), saturate((v - 0.55) * 6.0)) : float3(0.08, 0.28, 0.72);
        if (abs(lat) > 1.15) col = float3(0.95);
        if (fbm(sp * float2(2.5, 5.0) + float2(c.time * 0.02, 0.0)) > 0.62) col = float3(1.0);
    }
    float lam = saturate(dot(n, normalize(float3(-0.6, 0.45, 0.65))));
    col *= 0.1 + 0.9 * dq(lam, 4.0, b);
    col += atm * pow(1.0 - zc, 3.0) * glow * 0.6;
    return float4(col, 1.0);
}

// ---------------------------------------------------------------- 3D object (a tiny software rasteriser)

constant float3 dcV[26] = {
    float3(-1, -1, -1), float3(1, -1, -1), float3(1, 1, -1), float3(-1, 1, -1),
    float3(-1, -1, 1), float3(1, -1, 1), float3(1, 1, 1), float3(-1, 1, 1),
    float3(0, 1.3, 0), float3(-1, -0.7, -1), float3(1, -0.7, -1), float3(1, -0.7, 1), float3(-1, -0.7, 1),
    float3(0, 1.6, 0), float3(1, 0, 0), float3(0, 0, 1), float3(-1, 0, 0), float3(0, 0, -1), float3(0, -1.6, 0),
    float3(0, 0, 1.8), float3(0, 0.42, -0.55), float3(0, -0.28, -0.55), float3(-1.5, -0.05, -0.9), float3(1.5, -0.05, -0.9),
    float3(0, 0.05, -1.0), float3(0, 0.9, -1.1)
};
// vertex indices + edge flags (bit 0 = edge 0-1, bit 1 = 1-2, bit 2 = 2-0: the drawn outline)
constant uchar4 dcT[35] = {
    uchar4(0, 1, 2, 3), uchar4(0, 2, 3, 6), uchar4(5, 4, 7, 3), uchar4(5, 7, 6, 6),
    uchar4(4, 0, 3, 3), uchar4(4, 3, 7, 6), uchar4(1, 5, 6, 3), uchar4(1, 6, 2, 6),
    uchar4(4, 5, 1, 3), uchar4(4, 1, 0, 6), uchar4(3, 2, 6, 3), uchar4(3, 6, 7, 6),
    uchar4(8, 9, 10, 7), uchar4(8, 10, 11, 7), uchar4(8, 11, 12, 7), uchar4(8, 12, 9, 7), uchar4(9, 10, 11, 3), uchar4(9, 11, 12, 6),
    uchar4(13, 14, 15, 7), uchar4(13, 15, 16, 7), uchar4(13, 16, 17, 7), uchar4(13, 17, 14, 7),
    uchar4(18, 15, 14, 7), uchar4(18, 16, 15, 7), uchar4(18, 17, 16, 7), uchar4(18, 14, 17, 7),
    uchar4(19, 20, 22, 7), uchar4(19, 23, 20, 7), uchar4(19, 22, 21, 7), uchar4(19, 21, 23, 7),
    uchar4(20, 24, 22, 7), uchar4(20, 23, 24, 7), uchar4(21, 22, 24, 7), uchar4(21, 24, 23, 7), uchar4(20, 25, 24, 7)
};

static float edgeDist(float2 P, float2 a, float2 b, float2 c, uint fl) {
    float d = 1e9;
    if (fl & 1u) d = min(d, sdSeg(P, a, b));
    if (fl & 2u) d = min(d, sdSeg(P, b, c));
    if (fl & 4u) d = min(d, sdSeg(P, c, a));
    return d;
}

static float4 dcPolygon(Ctx c, constant DCU& U) {
    int s = c.style;
    int mesh = s <= 3 ? s : (s == 4 ? 0 : 3);
    bool wire = s >= 4;
    int v0 = mesh == 0 ? 0 : (mesh == 1 ? 8 : (mesh == 2 ? 13 : 19));
    int nv = mesh == 0 ? 8 : (mesh == 1 ? 5 : (mesh == 2 ? 6 : 7));
    int t0 = mesh == 0 ? 0 : (mesh == 1 ? 12 : (mesh == 2 ? 18 : 26));
    int t1 = mesh == 0 ? 12 : (mesh == 1 ? 18 : (mesh == 2 ? 26 : 35));
    float sc = (mesh == 3 ? 0.09 : 0.15) * (1.0 + c.r * (0.25 * U.music.x + 0.2 * U.hits.x));
    float yaw = c.t * 0.9, pitch = 0.45 + 0.35 * sin(c.t * 0.37), roll = 0.2 * sin(c.t * 0.23);
    if (mesh == 3) { yaw = PI + sin(c.t * 0.5) * 0.8; pitch = 0.35 + 0.15 * sin(c.t * 0.31); roll = sin(c.t * 0.7) * 0.35; }
    float cy = cos(yaw), sy = sin(yaw), cp = cos(pitch), spi = sin(pitch), cr = cos(roll), sr = sin(roll);
    float3x3 Ry = float3x3(float3(cy, 0, -sy), float3(0, 1, 0), float3(sy, 0, cy));
    float3x3 Rx = float3x3(float3(1, 0, 0), float3(0, cp, spi), float3(0, -spi, cp));
    float3x3 Rz = float3x3(float3(cr, sr, 0), float3(-sr, cr, 0), float3(0, 0, 1));
    float3x3 R = Rz * Rx * Ry;
    float3 rv[8];
    float3 pv[8];
    for (int i = 0; i < nv; i++) {
        float3 v = R * dcV[v0 + i];
        rv[i] = v;
        float f = 5.0 / (5.0 - v.z);
        pv[i] = float3(v.xy * f * sc, v.z);
    }
    float2 P = c.p;
    float bestZ = -1e9;
    int best = -1;
    float edgeD = 1e9;
    for (int ti = t0; ti < t1; ti++) {
        uchar4 tr = dcT[ti];
        float3 a = pv[tr.x - v0], bb = pv[tr.y - v0], cc = pv[tr.z - v0];
        if (wire) { edgeD = min(edgeD, edgeDist(P, a.xy, bb.xy, cc.xy, uint(tr.w))); continue; }
        float w0 = cross2(bb.xy - a.xy, P - a.xy), w1 = cross2(cc.xy - bb.xy, P - bb.xy), w2 = cross2(a.xy - cc.xy, P - cc.xy);
        bool inside = (w0 >= 0.0 && w1 >= 0.0 && w2 >= 0.0) || (w0 <= 0.0 && w1 <= 0.0 && w2 <= 0.0);
        float area = w0 + w1 + w2;
        if (!inside || abs(area) < 1e-12) continue;
        float z = (w1 * a.z + w2 * bb.z + w0 * cc.z) / area;
        if (z > bestZ) { bestZ = z; best = ti; }
    }
    float3 tint = mesh == 3 ? float3(0.85, 0.88, 0.95) : U.pal[0].rgb;
    if (wire) {
        if (edgeD < c.px * 0.75) return float4(mix(tint, float3(1.0), 0.5), 1.0);
        return 0.0;
    }
    if (best < 0) return 0.0;
    uchar4 tr = dcT[best];
    float3 A = rv[tr.x - v0], B = rv[tr.y - v0], C = rv[tr.z - v0];
    float3 n = normalize(cross(B - A, C - A));
    if (n.z < 0.0) n = -n;
    float lam = 0.2 + 0.8 * saturate(dot(n, normalize(float3(-0.4, 0.6, 0.7))));
    float3 base;
    if (mesh == 3) {
        int f = best - t0;
        base = f >= 4 ? float3(0.55, 0.58, 0.66) : float3(0.88, 0.9, 0.96);
        if (f == 8) base = float3(0.85, 0.15, 0.2);
    } else {
        int f = (best - t0) / (mesh == 0 ? 2 : 1);
        base = U.pal[f % 3].rgb;
    }
    float3 col = base * (0.25 + 0.75 * dq(lam, 4.0, bay(c.ip)));
    if (edgeDist(P, pv[tr.x - v0].xy, pv[tr.y - v0].xy, pv[tr.z - v0].xy, uint(tr.w)) < c.px * 0.6) col = mix(col, float3(1.0), 0.7);
    return float4(col, 1.0);
}

// ---------------------------------------------------------------- car (rear view)

static float4 dcCar(Ctx c, constant DCU& U) {
    bool hover = c.style == 1;
    float S = 0.36;
    float2 base = float2(sin(c.t * 0.5) * 0.05, -0.40);
    if (hover) base.y += 0.045 + 0.012 * sin(c.time * 2.5);
    float2 q = (c.p - base) / S;
    float pxq = c.px / S;
    float b = bay(c.ip);
    float kick = saturate(c.r * U.hits.x * 1.5);
    float yb = hover ? 0.0 : (c.r * U.music.x * 0.03 + 0.008 * sin(c.time * 23.0) * (0.4 + U.music.w));
    float2 cq = q - float2(0.0, yb);
    float3 body = float3(0.86, 0.10, 0.12);
    float sdBody = sdBox(cq - float2(0.0, 0.21), float2(0.48, 0.08)) - 0.02;
    float sdCab = sdTrap(cq - float2(0.0, 0.375), 0.37, 0.27, 0.07);
    float sdSpoiler = sdBox(cq - float2(0.0, 0.335), float2(0.47, 0.012));
    float sdWheels = hover ? 1e9 : min(sdBox(q - float2(-0.39, 0.075), float2(0.075, 0.075)), sdBox(q - float2(0.39, 0.075), float2(0.075, 0.075))) - 0.01;
    float sil = min(min(sdBody, sdCab), min(sdSpoiler, sdWheels));
    if (sil > pxq) {
        if (hover) {
            float g = exp(-abs(q.y + 0.02) * 16.0) * saturate(1.0 - abs(q.x) * 1.7) * (0.7 + kick);
            float a = saturate(dq(g, 4.0, b));
            if (a > 0.0) return float4(U.pal[1].rgb * a, a);
        } else if (abs(q.x) < 0.5 && q.y > -0.035 && q.y < 0.01) {
            return float4(0.0, 0.0, 0.0, 0.45);
        }
        // tail light glow on kicks
        float2 lq = float2(abs(cq.x) - 0.3, cq.y - 0.215);
        float lg = kick * exp(-length(lq / float2(1.0, 0.6)) * 9.0);
        float a = saturate(dq(lg, 3.0, b));
        if (a > 0.0) return float4(float3(1.0, 0.25, 0.2) * a, a);
        return 0.0;
    }
    if (sil > 0.0) return float4(0.05, 0.03, 0.05, 1.0);
    float3 col;
    if (sdWheels < 0.0 && cq.y < 0.12) {
        col = float3(0.08, 0.08, 0.09);
        if (fract(q.y * 28.0 + c.t * 6.0) < 0.3) col = float3(0.17, 0.17, 0.19);
        return float4(col, 1.0);
    }
    if (sdSpoiler < 0.0) return float4(cq.y > 0.342 ? body * 1.2 + 0.05 : body * 0.75, 1.0);
    if (sdCab < 0.0) {
        col = body;
        if (sdTrap(cq - float2(0.0, 0.372), 0.32, 0.23, 0.05) < 0.0) {
            col = float3(0.08, 0.09, 0.16);
            if (abs(fract((cq.x + cq.y * 1.5) * 3.0 + 0.2) - 0.5) < 0.06) col = float3(0.32, 0.38, 0.52);
        }
        return float4(col, 1.0);
    }
    float y = cq.y;
    col = body;
    if (y > 0.27) col = body * 1.25 + 0.05;
    if (y < 0.165) col = body * 0.7;
    if (y > 0.185 && y < 0.245 && abs(cq.x) > 0.13 && abs(cq.x) < 0.46) {
        col = mix(float3(0.55, 0.05, 0.05), float3(1.0, 0.4, 0.3), saturate(0.25 + kick + 0.4 * U.hits.w * c.r));
        if (fract(abs(cq.x) * 40.0) < 0.25) col *= 0.6;
    }
    if (y > 0.13 && y < 0.25 && abs(cq.x) < 0.13) {
        col = float3(0.06, 0.06, 0.07);
        if (abs(cq.x) < 0.085 && y > 0.14 && y < 0.185) {
            col = float3(0.92, 0.92, 0.85);
            if (abs(y - 0.162) < 0.008 && fract(cq.x * 60.0) < 0.5) col = float3(0.15, 0.15, 0.3);
        }
    }
    if (y < 0.12) col = float3(0.18, 0.18, 0.2);
    if (length(cq - float2(-0.25, 0.115)) < 0.022 || length(cq - float2(0.25, 0.115)) < 0.022) col = float3(0.55, 0.55, 0.58);
    if (y < 0.165 && y > 0.12 && b > 0.5) col *= 0.88;
    return float4(col, 1.0);
}

// ---------------------------------------------------------------- jet (rear view)

static float4 dcJet(Ctx c, constant DCU& U) {
    float bank = sin(c.t * 0.45) * 0.22;
    float2 base = float2(sin(c.t * 0.3) * 0.08, -0.12 + c.r * U.music.x * 0.012);
    float S = 0.5;
    float2 q = rot2((c.p - base) / S, -bank);
    float pxq = c.px / S;
    float b = bay(c.ip);
    float flame = 0.7 + 0.15 * sin(c.time * 37.0) + c.r * U.music.w * 1.1;
    float wingT = 0.02 - 0.015 * saturate(abs(q.x) / 0.62);
    float dFus = (length(q / float2(0.075, 0.06)) - 1.0) * 0.06;
    float dWing = min(sdSeg(q, float2(0.04, 0.0), float2(0.62, -0.07)), sdSeg(q, float2(-0.04, 0.0), float2(-0.62, -0.07))) - wingT;
    float dTail = min(sdSeg(q, float2(0.04, 0.015), float2(0.24, 0.0)), sdSeg(q, float2(-0.04, 0.015), float2(-0.24, 0.0))) - 0.01;
    float dFin = min(sdSeg(q, float2(0.045, 0.04), float2(0.1, 0.2)), sdSeg(q, float2(-0.045, 0.04), float2(-0.1, 0.2))) - 0.012;
    float dCan = (length((q - float2(0.0, 0.055)) / float2(0.035, 0.025)) - 1.0) * 0.025;
    float sil = min(min(min(dFus, dWing), min(dTail, dFin)), dCan);
    float2 n1 = float2(-0.03, -0.012), n2 = float2(0.03, -0.012);
    if (sil > pxq) {
        float g = exp(-min(length(q - n1), length(q - n2)) / (0.03 * flame));
        float a = saturate(dq(g, 4.0, b));
        if (a > 0.0) return float4(mix(float3(1.0, 0.5, 0.15), float3(1.0, 0.95, 0.7), a) * a, a);
        if (c.style == 1) {
            for (int i = 0; i < 2; i++) {
                float2 nz = i == 0 ? n1 : n2;
                float2 dir = normalize(float2(sign(nz.x) * 0.3 - bank * 0.6, -1.0));
                float2 dd = q - nz;
                float along = dot(dd, dir);
                float perp = abs(cross2(dir, dd));
                float width = 0.006 + along * 0.04;
                if (along > 0.0 && perp < width) {
                    float seg = fract(along * 5.0 - c.time * 4.0);
                    float ta = saturate(1.0 - along * 0.5) * (seg < 0.7 ? 1.0 : 0.5) * (0.6 + 0.4 * flame);
                    ta = saturate(dq(ta, 4.0, b));
                    if (ta > 0.0) return float4(mix(float3(1.0, 0.95, 0.6), float3(1.0, 0.45, 0.1), saturate(along)) * ta, ta);
                }
            }
        }
        return 0.0;
    }
    if (sil > 0.0) return float4(0.05, 0.05, 0.08, 1.0);
    float3 col = float3(0.56, 0.59, 0.65);
    if (dCan < 0.0) {
        col = float3(0.15, 0.25, 0.45);
        if (q.y > 0.062 && q.x < 0.0) col = float3(0.5, 0.65, 0.85);
    } else if (dFin < 0.0 && q.y > 0.03) {
        col = float3(0.48, 0.5, 0.56);
    } else if (length(q - n1) < 0.024 || length(q - n2) < 0.024) {
        float r = min(length(q - n1), length(q - n2));
        col = r < 0.015 ? mix(float3(1.0, 0.6, 0.2), float3(1.0, 0.95, 0.7), saturate(flame - 0.5)) : float3(0.25, 0.25, 0.28);
    } else {
        if (q.y < -0.01) col *= 0.75;
        if (dWing < 0.0 && dq(saturate(abs(q.x) * 1.5), 3.0, b) > 0.5) col *= 0.88;
    }
    return float4(col, 1.0);
}

// ---------------------------------------------------------------- equalizer

static float4 dcEqualizer(Ctx c, constant DCU& U) {
    float2 p = c.p;
    float W = 0.62, H = 0.38;
    float x = (p.x + W) / (2.0 * W);
    if (x < 0.0 || x >= 1.0) return 0.0;
    float bi = floor(x * 16.0);
    int i = int(bi);
    float fx = fract(x * 16.0);
    if (fx < 0.16 || fx > 0.88) return 0.0;
    float gain = 0.35 + 1.3 * c.r;
    float lev = saturate(bandOf(U, i) * gain), pk = saturate(peakOf(U, i) * gain);
    float3 bc = mix(mix(U.pal[0].rgb, U.pal[1].rgb, saturate(bi / 7.5)), U.pal[3].rgb, saturate((bi - 7.5) / 7.5));
    int s = c.style;
    if (s == 2) {
        float v = abs(p.y) / (H * 0.5);
        if (v > 1.0) return 0.0;
        if (v < lev) return float4(mix(bc, float3(1.0), v * 0.3), 1.0);
        if (abs(v - pk) < c.px / (H * 0.5) * 1.2) return float4(1.0);
        return 0.0;
    }
    float y = (p.y + H * 0.5) / H;
    if (y < 0.0 || y > 1.0) return 0.0;
    if (s == 1) {
        float seg = floor(y * 16.0);
        if (fract(y * 16.0) > 0.72) return 0.0;
        float3 lc = y < 0.6 ? float3(0.2, 1.0, 0.3) : (y < 0.85 ? float3(1.0, 0.9, 0.2) : float3(1.0, 0.25, 0.2));
        if ((seg + 0.5) / 16.0 < lev || seg == floor(pk * 16.0 - 0.001)) return float4(lc, 1.0);
        return float4(lc * 0.12 * 0.6, 0.6);
    }
    if (y < lev) return float4(mix(bc * 0.7, bc, dq(y / max(lev, 0.01), 3.0, bay(c.ip))), 1.0);
    if (abs(y - pk) < c.px / H * 1.2) return float4(1.0);
    return 0.0;
}

// ---------------------------------------------------------------- HUD

static bool glyphPix(uint4 ch, int x, int y) {
    if (x < 0 || y < 0 || y >= 7) return false;
    int ci = x / 6;
    int gx = x - ci * 6;
    if (ci >= 16 || gx >= 5) return false;
    return glyphBit((ch[ci >> 2] >> uint((ci & 3) * 8)) & 255u, gx, y);
}

static float3 textColour(int st, float fy, constant DCU& U) {
    float k = saturate(fy / 6.0);
    if (st == 0) return mix(float3(1.0, 0.96, 0.4), float3(1.0, 0.55, 0.1), k);
    if (st == 1) return mix(float3(0.98, 0.98, 1.0), float3(0.7, 0.75, 0.9), k);
    if (st == 2) return mix(float3(0.55, 1.0, 1.0), float3(0.1, 0.6, 0.95), k);
    if (st == 3) return mix(float3(1.0, 0.55, 0.95), float3(0.8, 0.2, 0.75), k);
    if (st == 4) return mix(float3(1.0, 0.45, 0.4), float3(0.85, 0.1, 0.1), k);
    if (st == 5) return mix(float3(0.65, 1.0, 0.5), float3(0.2, 0.75, 0.2), k);
    return mix(U.pal[0].rgb, U.pal[2].rgb, k);
}

static float4 dcHud(Ctx c, constant DCU& U, constant DCT* T, int start, int count) {
    for (int i = start; i < start + count; i++) {
        DCT it = T[i];
        float sz = it.pos.z;
        float2 lp = float2(c.p.x - it.pos.x, it.pos.y - c.p.y) / sz;
        int st = int(it.pos.w);
        if (st >= 16) {
            float wc = float(it.ch.x);
            float fill = float(it.ch.y) / 1000.0;
            if (lp.x < -1.0 || lp.y < -1.0 || lp.x > wc * 4.0 + 1.0 || lp.y > 7.0) continue;
            if (lp.x < 0.0 || lp.y < 0.0 || lp.x >= wc * 4.0 || lp.y >= 6.0) return float4(0.02, 0.02, 0.05, 1.0);
            if (fract(lp.x / 4.0) > 0.75) return float4(0.05, 0.05, 0.1, 1.0);
            float fx = (floor(lp.x / 4.0) + 0.5) / wc;
            if (fx > fill) return float4(0.12, 0.12, 0.18, 1.0);
            float3 col = st == 16 ? (fx < 0.6 ? float3(0.2, 1.0, 0.3) : (fx < 0.85 ? float3(1.0, 0.9, 0.2) : float3(1.0, 0.25, 0.2)))
                                  : (st == 17 ? float3(0.35, 0.75, 1.0) : U.pal[1].rgb);
            if (lp.y < 1.0) col = mix(col, float3(1.0), 0.4);
            return float4(col, 1.0);
        }
        if (lp.x < -1.0 || lp.y < -1.0 || lp.y > 8.0 || lp.x > 97.0) continue;
        int fx = int(floor(lp.x)), fy = int(floor(lp.y));
        if (glyphPix(it.ch, fx, fy)) return float4(textColour(st, float(fy), U), 1.0);
        bool nb = false;
        for (int dy = -1; dy <= 1 && !nb; dy++)
            for (int dx = -1; dx <= 1 && !nb; dx++) nb = glyphPix(it.ch, fx + dx, fy + dy);
        if (nb) return float4(0.03, 0.02, 0.06, 1.0);
    }
    return 0.0;
}

// ---------------------------------------------------------------- alien formation (Atari / arcade)

static float4 dcInvaders(Ctx c, constant DCU& U, DCL L) {
    float H = U.res.y;
    float s = max(1.0, round(H / 120.0)) / H;          // one sprite pixel (whole console pixels)
    float cw = 12.0 * s, ch = 11.0 * s;
    float2 p = c.p;
    float3 green = float3(0.35, 1.0, 0.45);
    if (abs(p.y + 0.455) < s * 0.5 && abs(p.x) < 0.75) return float4(green, 1.0);
    // cannon (bottom-left corner of its sprite at the given x)
    float2 cq = (p - float2(L.e.x - 4.0 * s, -0.44)) / s;
    if (sprPix(7, int(floor(cq.x)), 7 - int(floor(cq.y))) != 0) return float4(green, 1.0);
    // its shot
    if (L.e.z > -1.0 && abs(p.x - L.e.y) < s * 0.5 && p.y > L.e.z && p.y < L.e.z + 4.0 * s) return float4(1.0);
    float x0 = -5.5 * cw + L.c.z * s;
    float y0 = 0.3 - L.c.w * 6.0 * s;
    float fx = (p.x - x0) / cw, fy = (y0 - p.y) / ch;
    if (fx < 0.0 || fx >= 11.0 || fy < 0.0 || fy >= 5.0) return 0.0;
    int col = int(fx), row = int(fy);
    int idx = row * 11 + col;
    uint word = idx < 32 ? L.d.x : L.d.y;
    bool alive = ((word >> uint(idx & 31)) & 1u) != 0u;
    bool boom = int(L.d.z) == idx;
    if (!alive && !boom) return 0.0;
    int sx = int(floor((fx - float(col)) * 12.0)) - 2, sy = int(floor((fy - float(row)) * 11.0)) - 1;
    int id = boom ? 6 : (row == 0 ? 4 : (row < 3 ? 0 : 2)) + int(L.d.w & 1u);
    if (sprPix(id, sx, sy) == 0) return 0.0;
    float3 cl = boom ? float3(1.0, 0.9, 0.5) : (row == 0 ? float3(1.0, 0.35, 0.9) : (row < 3 ? float3(0.35, 0.9, 1.0) : float3(1.0, 0.95, 0.4)));
    return float4(saturate(cl * (1.0 + 0.5 * U.hits.w * c.r)), 1.0);
}

// ---------------------------------------------------------------- brick breaker (Atari)

static float4 dcBreaker(Ctx c, constant DCU& U, DCL L) {
    float2 p = c.p;
    float3 wall = float3(0.62, 0.62, 0.68);
    if (p.y < 0.467 && p.y > -0.5 && abs(abs(p.x) - 0.64) < 0.012) return float4(wall, 1.0);
    if (abs(p.y - 0.455) < 0.012 && abs(p.x) < 0.652) return float4(wall, 1.0);
    float bx = (p.x + 0.62) / 0.124, by = (0.27 - p.y) / 0.03;
    if (bx >= 0.0 && bx < 10.0 && by >= 0.0 && by < 6.0) {
        int col = int(bx), row = int(by);
        int idx = row * 10 + col;
        uint word = idx < 32 ? L.d.x : L.d.y;
        if (((word >> uint(idx & 31)) & 1u) != 0u) {
            float fx = bx - float(col), fy = by - float(row);
            if (fx < 0.04 || fx > 0.96 || fy < 0.1 || fy > 0.9) return 0.0;
            float3 cl = row == 0 ? float3(1.0, 0.25, 0.25) : row == 1 ? float3(1.0, 0.55, 0.2) : row == 2 ? float3(1.0, 0.85, 0.25)
                      : row == 3 ? float3(0.3, 0.9, 0.35) : row == 4 ? float3(0.25, 0.75, 1.0) : float3(0.6, 0.4, 1.0);
            if (fy < 0.35) cl = mix(cl, float3(1.0), 0.25);
            return float4(saturate(cl * (1.0 + 0.4 * U.hits.w * c.r)), 1.0);
        }
    }
    if (abs(p.y + 0.4) < 0.012 && abs(p.x - L.e.z) < 0.08) {
        float3 cl = abs(p.x - L.e.z) > 0.065 ? float3(1.0, 0.3, 0.3) : float3(0.88, 0.88, 0.96);
        return float4(cl, 1.0);
    }
    if (all(abs(p - L.e.xy) < float2(0.009))) return float4(1.0);
    return 0.0;
}

// ---------------------------------------------------------------- platformer (8-bit)

static int pfGround(int i) {
    int seg = int(floor(float(i) / 8.0));
    return 2 + int(hash1(seg * 13 + 5) * 2.99);
}

static float4 dcPlatformer(Ctx c, constant DCU& U, DCL L) {
    float H = U.res.y;
    float u = max(1.0, round(H / 240.0)) / H;           // one console pixel (whole)
    float T = 16.0 * u;                                  // a tile
    float2 p = c.p;
    int st = c.style;
    float scroll = c.t * 6.0;
    float wx = p.x / T + scroll;
    float ty = (p.y + 0.5) / T;
    int i = int(floor(wx)), r = int(floor(ty));
    int lx = int(floor(fract(wx) * 16.0)), ly = int(floor(fract(ty) * 16.0));
    // colours per world
    float3 top, topDark, dirt, dirtDark, brick, mortar, hill, hillDark;
    if (st == 0) {
        top = float3(0.40, 0.85, 0.25); topDark = float3(0.15, 0.50, 0.12); dirt = float3(0.80, 0.48, 0.22); dirtDark = float3(0.52, 0.28, 0.10);
        brick = float3(0.82, 0.36, 0.16); mortar = float3(0.32, 0.12, 0.05); hill = float3(0.30, 0.68, 0.32); hillDark = float3(0.18, 0.50, 0.24);
    } else if (st == 1) {
        top = float3(0.30, 0.55, 0.85); topDark = float3(0.08, 0.15, 0.35); dirt = float3(0.16, 0.32, 0.62); dirtDark = float3(0.06, 0.12, 0.28);
        brick = float3(0.25, 0.50, 0.80); mortar = float3(0.05, 0.10, 0.25); hill = float3(0.0); hillDark = float3(0.0);
    } else {
        top = float3(0.72, 0.72, 0.76); topDark = float3(0.30, 0.30, 0.36); dirt = float3(0.55, 0.55, 0.60); dirtDark = float3(0.30, 0.30, 0.36);
        brick = float3(0.66, 0.60, 0.58); mortar = float3(0.28, 0.24, 0.24); hill = float3(0.0); hillDark = float3(0.0);
    }
    // the runner (a fixed spot on screen; stands on the ground under it, jumps on kicks)
    float hx = -0.35;
    float hw = hx / T + scroll;
    int hi = int(floor(hw));
    float gy = mix(float(pfGround(hi)), float(pfGround(hi + 1)), smoothstep(0.6, 1.0, fract(hw)));
    float heroY = -0.5 + (gy + L.e.x) * T;
    float2 hq = (p - float2(hx - 8.0 * u, heroY)) / (2.0 * u);
    if (hq.x >= 0.0 && hq.x < 8.0 && hq.y >= 0.0 && hq.y < 16.0) {
        int sx = int(hq.x), up = int(hq.y);
        int v = up >= 8 ? sprPix(8, sx, 15 - up)
                        : sprPix(L.e.y > 0.5 ? 12 : 9 + int(fmod(c.t * 10.0, 3.0)), sx, 7 - up);
        if (v == 1) return float4(0.18, 0.10, 0.22, 1.0);
        if (v == 2) return float4(1.0, 0.76, 0.56, 1.0);
        if (v == 3) return float4(st == 1 ? float3(0.95, 0.85, 0.2) : float3(0.92, 0.18, 0.2), 1.0);
    }
    int g = pfGround(i);
    int chunk = int(floor(float(i) / 12.0));
    bool hasPlat = hash1(chunk * 7 + 3) < 0.75;
    int ps = chunk * 12 + 2 + int(hash1(chunk * 7 + 4) * 4.0);
    int pl = 3 + int(hash1(chunk * 7 + 6) * 3.0);
    int py = pfGround(ps) + 3 + int(hash1(chunk * 7 + 8) * 2.0);
    bool inPlat = hasPlat && i >= ps && i < ps + pl;
    // spinning coins (they hop on the beat)
    bool coin = (inPlat && r == py + 1 && ((i - ps) & 1) == 0) || (!inPlat && r == g + 1 && hash1(i * 3 + 11) > 0.8);
    if (coin) {
        float2 cc = float2(fract(wx) - 0.5, fract(ty) - 0.5 - 0.12 * U.hits.w * c.r) * 16.0;
        float wd = 1.0 + 4.0 * abs(cos(c.t * 4.0 + float(i)));
        if (abs(cc.x) < wd && abs(cc.y) < 6.0) {
            float3 cl = (abs(cc.x) > wd - 1.0 || abs(cc.y) > 5.0) ? float3(0.70, 0.42, 0.05) : float3(1.0, 0.85, 0.2);
            if (cc.x < -wd + 2.0 && abs(cc.y) < 4.0 && wd > 2.5) cl = float3(1.0, 1.0, 0.75);
            return float4(cl, 1.0);
        }
    }
    if (inPlat && r == py) {
        bool m = (ly & 7) == 0 || lx == (((ly >> 3) & 1) == 0 ? 0 : 8);
        float3 cl = m ? mortar : brick;
        if (ly == 15 && !m) cl = mix(cl, float3(1.0), 0.3);
        return float4(cl, 1.0);
    }
    if (r >= 0 && r < g) {
        float3 cl;
        if (st == 0) {
            int2 sp = int2(i * 8 + lx / 2, r * 8 + ly / 2);
            cl = hash2(sp) > 0.82 ? dirtDark : dirt;
            if (r == g - 1) {
                if (ly >= 12) cl = top;
                else if (ly == 11 || (ly == 10 && hash1(i * 16 + lx) > 0.5)) cl = topDark;
            }
        } else {
            cl = (lx == 0 || ly == 0) ? dirtDark : ((lx == 1 || ly == 14) ? mix(dirt, float3(1.0), 0.2) : dirt);
            if (r == g - 1 && ly >= 13) cl = ly == 15 ? top : topDark;
        }
        return float4(cl, 1.0);
    }
    // rolling hills far behind (grassland), scrolling slower
    if (st == 0) {
        float bx = p.x / T + scroll * 0.5;
        float cell = floor(bx / 22.0);
        float hc = cell * 22.0 + 6.0 + 10.0 * hash1(int(cell) + 90);
        float rad = 4.0 + 3.0 * hash1(int(cell) + 91);
        float2 d = float2(bx - hc, ty - 2.0);
        if (d.y >= 0.0 && length(d) < rad) {
            float3 cl = (length(d) > rad - 0.4 || d.x > rad * 0.45) ? hillDark : hill;
            if (hash2(int2(floor(bx * 4.0), floor(ty * 4.0))) > 0.93) cl = hillDark;
            return float4(cl, 1.0);
        }
    }
    return 0.0;
}

// ---------------------------------------------------------------- raster bars (16-bit / demoscene)

static float4 dcRaster(Ctx c, constant DCU& U) {
    float2 p = c.p;
    int st = c.style;
    if (st == 2) {
        float v = p.y * 2.5 + c.t * 0.15 + 0.15 * U.music.x * c.r;
        float q = floor(fract(v) * 24.0) / 24.0;
        float3 col = pal4(U, q) * (0.55 + 0.45 * (0.5 + 0.5 * sin(q * 6.2831853 * 3.0)));
        return float4(col, 1.0);
    }
    float coord = st == 0 ? p.y : p.x;
    float span = st == 0 ? 0.33 : 0.55;
    float best = -2.0;
    float4 o = 0.0;
    for (int i = 0; i < 8; i++) {
        float ph = c.t * 1.6 + float(i) * 0.55;
        float z = cos(ph);
        float centre = sin(ph) * span;
        float lev = bandOf(U, i * 2);
        float hb = 0.026 * (0.7 + 1.2 * lev * c.r + 0.3 * (1.0 - c.r));
        float d = abs(coord - centre) / hb;
        if (d < 1.0 && z > best) {
            best = z;
            float sh = floor((1.0 - d) * 7.0) / 7.0;
            float3 col = rainbow(float(i) / 8.0) * (0.3 + 0.9 * sh) * (0.7 + 0.3 * z) + float3(sh * sh * sh * sh * 0.45);
            o = float4(saturate(col), 1.0);
        }
    }
    return o;
}

// ---------------------------------------------------------------- sine scroller (16-bit / demoscene)

static float4 dcScroller(Ctx c, constant DCU& U, constant DCT* T, DCL L) {
    float H = U.res.y;
    float f = max(1.0, round(H / 80.0)) / H;             // font pixel: 3 console pixels at 240 lines
    float cw = 6.0 * f;
    int st = c.style;
    float2 p = c.p;
    bool mirror = st == 2 && p.y < -0.06;
    float3 tint = float3(1.0);
    if (mirror) {
        p.y = -0.12 - p.y;
        p.x += sin(p.y * 120.0 + c.time * 6.0) * f * 0.8;
        tint = float3(0.45, 0.55, 0.9);
    }
    float xr = (p.x - L.e.y) / cw + L.e.x;
    int k = int(floor(xr));
    int n = int(L.c.w) * 16;
    if (k < 0 || k >= n) return 0.0;
    float gk = float(k) + L.e.w;
    float amp = 0.1 * (1.0 + 0.8 * c.r * U.music.x);
    float yo = st == 1 ? abs(sin(gk * 0.6 + c.time * 4.0)) * amp * 1.4 - 0.05 : sin(gk * 0.45 + c.time * 2.5) * amp;
    yo += c.r * bandOf(U, k & 15) * 0.04;
    int gx = int(floor((xr - float(k)) * 6.0));
    int gy = int(floor((yo + 3.5 * f - p.y) / f));
    int item = int(L.c.z) + k / 16, slot = k & 15;
    uint code = (T[item].ch[slot >> 2] >> uint((slot & 3) * 8)) & 255u;
    if (glyphBit(code, gx, gy)) {
        float3 col = rainbow(float(gy) / 9.0 + c.time * 0.2 + gk * 0.02);
        col = mix(col, float3(1.0), gy == 0 ? 0.5 : 0.0);
        return float4(col * tint, 1.0);
    }
    // a dark drop shadow
    if (!mirror && glyphBit(code, gx - 1, gy - 1)) return float4(0.02, 0.0, 0.06, 1.0);
    return 0.0;
}

// ---------------------------------------------------------------- demo effects (16-bit / demoscene)

static float4 dcDemo(Ctx c, constant DCU& U) {
    float2 p = c.p;
    float b = bay(c.ip);
    float t = c.t;
    float bass = c.r * U.music.x;
    float3 col;
    if (c.style == 0) {
        float v = sin(p.x * 9.0 + t) + sin(p.y * 7.0 - t * 1.3) + sin((p.x + p.y) * 6.0 + t * 0.7)
                + sin(length(p - 0.3 * float2(sin(t * 0.4), cos(t * 0.5))) * 14.0 - t * 2.0);
        col = pal4(U, dq(fract(v * 0.125 + t * 0.05 + bass * 0.3), 16.0, b));
    } else if (c.style == 1) {
        float r = length(p) + 1e-3;
        float a = atan2(p.y, p.x) / PI;
        float2 uv = float2(a * 2.0 + t * 0.1, 0.3 / r + t * 1.2 + bass * 0.5);
        int tx = int(floor(uv.x * 8.0)), tyy = int(floor(uv.y * 8.0));
        float v = float((tx ^ tyy) & 7) / 7.0;
        col = pal4(U, v * 0.5 + t * 0.05) * (0.25 + 0.75 * dq(saturate(r * 3.0), 6.0, b));
    } else {
        float2 uv = rot2(p, t * 0.35) * (2.0 + 1.2 * sin(t * 0.3) - bass) + float2(t * 0.4, t * 0.2);
        int tx = int(floor(uv.x * 6.0)), tyy = int(floor(uv.y * 6.0));
        float v = float((tx ^ tyy) & 15) / 15.0;
        col = pal4(U, v * 0.6 + t * 0.03);
    }
    return float4(col, 1.0);
}

// ---------------------------------------------------------------- console colours

static float3 atariColour(float3 c) {
    float3x3 toYIQ = float3x3(float3(0.299, 0.596, 0.211), float3(0.587, -0.274, -0.523), float3(0.114, -0.322, 0.312));
    float3x3 toRGB = float3x3(float3(1.0, 1.0, 1.0), float3(0.956, -0.272, -1.106), float3(0.621, -0.647, 1.703));
    float3 y = toYIQ * c;
    float lq = floor(saturate(y.x) * 7.0 + 0.5) / 7.0;
    if (length(y.yz) < 0.045) return float3(lq);
    float step = 2.0 * PI / 15.0;
    float h = round(atan2(y.z, y.y) / step) * step;
    float chroma = 0.13 + 0.12 * sin(PI * saturate(lq * 0.9 + 0.05));
    return saturate(toRGB * float3(lq * 0.9 + 0.05, chroma * cos(h), chroma * sin(h)));
}

static float3 nesColour(float3 c) {
    float best = 1e9;
    float3 o = c;
    for (int i = 0; i < NES_COUNT; i++) {
        float3 d = c - dcNES[i];
        float e = dot(d * d, float3(2.0, 4.0, 3.0));
        if (e < best) { best = e; o = dcNES[i]; }
    }
    return o;
}

static float3 consoleColour(float3 c, int con, float b) {
    if (con == 0) return atariColour(c);
    if (con == 1) return nesColour(saturate(c + (b - 0.5) * 0.07));
    if (con == 2) {
        float l = floor(saturate(luma(c) * 1.1) * 3.0 + b) / 3.0;
        return l < 0.2 ? float3(0.06, 0.22, 0.06) : (l < 0.5 ? float3(0.19, 0.38, 0.19) : (l < 0.8 ? float3(0.55, 0.67, 0.06) : float3(0.61, 0.74, 0.06)));
    }
    if (con == 3) return floor(c * 7.0 + b) / 7.0;
    if (con == 4) return floor(c * 31.0 + b) / 31.0;
    return float3(floor(c.r * 31.0 + b) / 31.0, floor(c.g * 63.0 + b) / 63.0, floor(c.b * 31.0 + b) / 31.0);
}

// ---------------------------------------------------------------- the stack

fragment float4 dcLayersFrag(DCOut in [[stage_in]], constant DCU& U [[buffer(0)]], constant DCL* Ls [[buffer(1)]],
                             constant DCT* T [[buffer(2)]]) {
    float2 res = U.res.xy;
    float2 pix = in.position.xy;
    float pxA = max(U.outp.z, 1.0);   // the 2600's pixels are twice as wide
    float2 q = float2((pix.x - res.x * 0.5) * pxA, res.y * 0.5 - pix.y) / res.y;
    int2 ip = int2(pix);
    float4 acc = 0.0;
    int n = int(U.res.w);
    for (int i = n - 1; i >= 0; i--) {
        DCL L = Ls[i];
        float op = L.a.z;
        if (op <= 0.001) continue;
        float sc = max(L.b.z, 0.02);
        Ctx c;
        c.p = rot2(q - L.b.xy, -L.b.w) / sc;
        c.px = 1.0 / (res.y * sc);
        c.ip = ip;
        c.t = L.c.x;
        c.r = L.a.w;
        c.style = int(L.a.y);
        c.time = U.crt.z;
        float4 col = 0.0;
        switch (int(L.a.x)) {
            case 0: col = dcSky(c, U); break;
            case 1: col = dcClouds(c, U); break;
            case 2: col = dcSun(c, U); break;
            case 3: col = dcSkyline(c, U); break;
            case 4: col = dcOcean(c, U); break;
            case 5: col = dcRoad(c, U); break;
            case 6: col = dcPalmLayer(c, U); break;
            case 7: col = dcGrid(c, U); break;
            case 8: col = dcChecker(c, U); break;
            case 9: col = dcStars(c, U); break;
            case 10: col = dcPlanet(c, U); break;
            case 11: col = dcPolygon(c, U); break;
            case 12: col = dcCar(c, U); break;
            case 13: col = dcJet(c, U); break;
            case 14: col = dcEqualizer(c, U); break;
            case 15: col = dcHud(c, U, T, int(L.c.z), int(L.c.w)); break;
            case 16: col = dcInvaders(c, U, L); break;
            case 17: col = dcBreaker(c, U, L); break;
            case 18: col = dcPlatformer(c, U, L); break;
            case 19: col = dcRaster(c, U); break;
            case 20: col = dcScroller(c, U, T, L); break;
            case 21: col = dcDemo(c, U); break;
            default: break;
        }
        if (col.a <= 0.0) continue;
        if (L.c.y != 0.0) col.rgb = max(hueRot(col.rgb, L.c.y * 2.0 * PI), 0.0);
        acc += (1.0 - acc.a) * col * op;
        if (acc.a > 0.996) break;
    }
    // the console's colours; what no layer covers stays transparent (premultiplied, so soundwatch's background shows)
    if (acc.a <= 0.002) return 0.0;
    float a = saturate(acc.a);
    return float4(saturate(consoleColour(saturate(acc.rgb / a), int(U.crt.w), bay(ip))) * a, a);
}

// ---------------------------------------------------------------- CRT

/// The screen's surface in world units: x ±aspect, y ±1, bulging towards the viewer (+z) by `bulge` in the middle.
// ext = the screen's half width / height in window units (x ±asp, y ±1 = the whole window)
static float dcSurf(float2 h, float2 ext, float bulge) {
    float2 q = h / ext;
    return bulge * (1.0 - 0.5 * dot(q, q));
}

fragment float4 dcCrtFrag(DCOut in [[stage_in]], constant DCU& U [[buffer(0)]], texture2d<float> src [[texture(0)]]) {
    float2 outS = U.outp.xy;
    float asp = outS.x / outS.y;
    float crt = U.crt.x, warp = U.crt.y;
    // the screen is a surface in 3D, seen through the orbit camera (at rest: head-on, filling the window exactly)
    const float D = 3.0;
    float2 ext = float2(asp * clamp(U.outp.w, 0.05, 1.0), clamp(U.view.w, 0.05, 1.0));
    float bulge = 0.4 * warp * min(ext.x / asp, ext.y);
    float2 ndc = float2(in.position.x / outS.x * 2.0 - 1.0, 1.0 - in.position.y / outS.y * 2.0) - U.view.yz;
    float tanH = (1.0 + 0.12 * bulge) / (D * max(U.view.x, 0.05));
    float3 dc = normalize(float3(ndc.x * asp * tanH, ndc.y * tanH, -1.0));
    float3x3 Rt = float3x3(U.cam[0].xyz, U.cam[1].xyz, U.cam[2].xyz);   // view → world: R's rows as columns = Rᵀ
    float3 o = Rt * float3(0.0, 0.0, D);
    float3 d = Rt * dc;
    if (abs(d.z) < 1e-5) return 0.0;
    float t = (bulge - o.z) / d.z;
    for (int i = 0; i < 6; i++) {
        float3 h = o + t * d;
        t = (dcSurf(h.xy, ext, bulge) - o.z) / d.z;
    }
    if (t <= 0.0) return 0.0;
    float3 h = o + t * d;
    float2 cc = float2(h.x / ext.x, -h.y / ext.y);
    // the picture's own barrel on the tube (lines bow out more along the long side)
    float2 cw = cc * (1.0 + float2(cc.y * cc.y, cc.x * cc.x) * float2(0.11, 0.16) * warp * 0.9);
    // the screen's edge: rounded corners, softened over ~1.5 output pixels
    float pxw = max(length(fwidth(cw)), 1e-5);
    float rad = 0.015 + 0.09 * max(warp, crt * 0.3);
    float sd = length(max(abs(cw) - (1.0 - rad), 0.0)) - rad;
    float inside = saturate(-sd / (pxw * 1.5));
    if (inside <= 0.0) return 0.0;
    float2 tsz = float2(src.get_width(), src.get_height());
    float2 sp = (cw * 0.5 + 0.5) * tsz;
    // output pixels per console pixel (changes across a turned screen)
    float2 ppt = 1.0 / max(float2(length(float2(dfdx(sp.x), dfdy(sp.x))), length(float2(dfdx(sp.y), dfdy(sp.y)))), 1e-4);
    float2 tp = floor(sp) + 0.5;
    float2 off = clamp((sp - tp) * ppt, -0.5, 0.5);          // sharp pixels with a 1-pixel soft edge
    float4 sharp = src.sample(dcLin, (tp + off) / tsz);
    // the back of the screen: the picture shows through dimmed
    float back = o.z < dcSurf(o.xy, ext, bulge) ? 0.45 : 1.0;
    // glass: a soft sheen where the curved face mirrors a light above-left (only with Warp)
    float4 sheen = 0.0;
    if (bulge > 0.0) {
        float2 q = float2(h.x / ext.x, h.y / ext.y);
        float3 n = normalize(float3(bulge * q.x / ext.x, bulge * q.y / ext.y, 1.0));
        float spec = pow(saturate(dot(reflect(d, n), normalize(float3(-0.5, 0.6, 0.6)))), 24.0) * 0.22 * warp;
        sheen = float4(float3(spec), spec * 0.5);
    }
    if (crt < 0.001) return (sharp * back + sheen) * inside;
    // two nearest lines, each softened horizontally, as gaussian beams (bright lines are wider); premultiplied
    float hx = mix(tp.x + off.x, sp.x, 0.65);
    float y = sp.y - 0.5;
    float r0 = floor(y), fy = y - r0;
    float4 c0 = src.sample(dcLin, float2(hx, r0 + 0.5) / tsz);
    float4 c1 = src.sample(dcLin, float2(hx, r0 + 1.5) / tsz);
    float4 w0 = float4(mix(float3(0.28), float3(0.5), c0.rgb), mix(0.28, 0.5, max(c0.r, max(c0.g, c0.b))));
    float4 w1 = float4(mix(float3(0.28), float3(0.5), c1.rgb), mix(0.28, 0.5, max(c1.r, max(c1.g, c1.b))));
    float4 beam = c0 * exp(-0.5 * fy * fy / (w0 * w0)) / (w0 * 2.5066) + c1 * exp(-0.5 * (1.0 - fy) * (1.0 - fy) / (w1 * w1)) / (w1 * 2.5066);
    float vis = saturate((ppt.y - 1.5) / 2.5);               // scanlines only where a line is several pixels tall
    float4 soft = mix(c0, c1, smoothstep(0.0, 1.0, fy));
    float4 col = mix(sharp, mix(soft, beam, vis), crt);
    // halation: bright parts glow into their surroundings (also over the background)
    float3 glow = 0.0;
    for (int i = 0; i < 8; i++) {
        float a = float(i) * PI * 0.25;
        glow += src.sample(dcLin, (sp + float2(cos(a), sin(a)) * 1.8) / tsz).rgb;
    }
    glow *= 0.125;
    float3 g = glow * glow * 0.45 * crt;
    col += float4(g, max(g.r, max(g.g, g.b)));
    // aperture grille: RGB stripes three output pixels wide (only when big enough to read as a mask)
    float ph = fmod(in.position.x, 3.0);
    float3 m = float3(ph < 1.0 ? 1.0 : 0.0, ph >= 1.0 && ph < 2.0 ? 1.0 : 0.0, ph >= 2.0 ? 1.0 : 0.0);
    col.rgb *= mix(float3(1.0), float3(0.62) + m * 1.14, 0.4 * crt * saturate(ppt.x / 3.0));
    // vignette, a slow rolling brightness band, noise (only where there is picture)
    float vig = 1.0 - crt * 0.35 * pow(saturate(dot(cc, cc) * 0.5), 1.5);
    float roll = 1.0 + crt * 0.035 * smoothstep(0.85, 1.0, 0.5 + 0.5 * sin(cc.y * 1.5 - U.crt.z * 1.3));
    int fr = int(U.crt.z * 60.0);
    float nz = (hash2(int2(in.position.xy) + int2(fr * 7, fr * 13)) - 0.5) * 0.035 * crt;
    col.rgb = col.rgb * vig * roll * (1.0 + 0.12 * crt) + nz * col.a;
    col = max(col, 0.0);
    col.a = min(col.a, 1.0);
    return (col * back + sheen) * inside;
}
"""
