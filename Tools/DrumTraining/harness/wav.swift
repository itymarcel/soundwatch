import Foundation
struct Wav { var sr: Double; var mono: [Float] }
func readWav(_ path: String) -> Wav {
    let d = try! Data(contentsOf: URL(fileURLWithPath: path))
    func u32(_ o: Int) -> Int { Int(d[o]) | Int(d[o+1]) << 8 | Int(d[o+2]) << 16 | Int(d[o+3]) << 24 }
    func u16(_ o: Int) -> Int { Int(d[o]) | Int(d[o+1]) << 8 }
    var o = 12, fmt = 1, ch = 2, sr = 44100, bits = 16
    var out: [Float] = []
    while o + 8 <= d.count {
        let id = String(bytes: d[o..<o+4], encoding: .ascii) ?? "", sz = u32(o + 4)
        if id == "fmt " { fmt = u16(o+8); ch = u16(o+10); sr = u32(o+12); bits = u16(o+22); if fmt == 0xFFFE { fmt = u16(o+32) } }
        if id == "data" {
            let n = min(sz, d.count - o - 8) / (bits / 8 * ch)
            out = .init(repeating: 0, count: n)
            d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let base = raw.baseAddress! + o + 8
                for i in 0..<n {
                    var acc: Float = 0
                    for c in 0..<ch {
                        let p = base + (i * ch + c) * bits / 8
                        switch (fmt, bits) {
                        case (1, 16): acc += Float(p.loadUnaligned(as: Int16.self)) / 32768
                        case (1, 24): let v = Int32(p.load(as: UInt8.self)) | Int32(p.load(fromByteOffset: 1, as: UInt8.self)) << 8 | Int32(Int8(bitPattern: p.load(fromByteOffset: 2, as: UInt8.self))) << 16; acc += Float(v) / 8388608
                        case (1, 32): acc += Float(p.loadUnaligned(as: Int32.self)) / 2147483648
                        case (3, 32): acc += p.loadUnaligned(as: Float.self)
                        default: break
                        }
                    }
                    out[i] = acc / Float(ch)
                }
            }
            break
        }
        o += 8 + sz + (sz & 1)
    }
    return Wav(sr: Double(sr), mono: out)
}
