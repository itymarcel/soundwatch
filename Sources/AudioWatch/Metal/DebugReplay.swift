import Foundation

/// Debug aid for exact A/B stills of the ray-marched shader modes (Glass, Diamond, Orbs, Infinity, …):
/// AUDIOWATCH_SM_DUMP=/path writes the shader uniforms + float data of frame AUDIOWATCH_SNAPSHOT_FRAMES (its first
/// number); AUDIOWATCH_SM_LOAD=/path draws every frame from such a dump (the pass is a pure function of them).
enum DebugReplay {
    private static let env = ProcessInfo.processInfo.environment
    private static let dump = env["AUDIOWATCH_SM_DUMP"], load = env["AUDIOWATCH_SM_LOAD"]
    private static let dumpFrame = Int(env["AUDIOWATCH_SNAPSHOT_FRAMES"]?.split(separator: ",").first ?? "") ?? 0
    private static var frame = 0
    private static var loaded: (ShaderModeUniforms, [Float])?

    static func apply(_ u: inout ShaderModeUniforms, _ data: inout [Float]) {
        frame += 1
        let n = MemoryLayout<ShaderModeUniforms>.stride
        if let load {
            if loaded == nil, let d = FileManager.default.contents(atPath: load), d.count >= n {
                loaded = d.withUnsafeBytes { b in
                    (b.loadUnaligned(as: ShaderModeUniforms.self),
                     (0..<(d.count - n) / 4).map { b.loadUnaligned(fromByteOffset: n + $0 * 4, as: Float.self) })
                }
            }
            if let loaded { u = loaded.0; data = loaded.1 }
        } else if let dump, frame == dumpFrame {
            var d = withUnsafeBytes(of: u) { Data($0) }
            data.withUnsafeBytes { d.append(contentsOf: $0) }
            FileManager.default.createFile(atPath: dump, contents: d)
        }
    }
}
