import CoreAudio
import os

/// Thread-safe stereo ring buffer. The audio IO queue writes, the render loop reads.
final class AudioRing: @unchecked Sendable {
    let capacity = 1 << 17
    private let mask: Int64
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private var written: Int64 = 0
    /// Recent largest IO callback (frames), decaying slowly: how bursty the device delivers audio.
    private var _burst: Double = 512
    private var _callbacks: Int64 = 0
    private var _sampleRate: Double = 48_000
    private var _outputLatency: Double = 0
    private let lock = OSAllocatedUnfairLock()

    init() {
        mask = Int64(capacity - 1)
        left = .allocate(capacity: capacity)
        right = .allocate(capacity: capacity)
        left.initialize(repeating: 0, count: capacity)
        right.initialize(repeating: 0, count: capacity)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    var sampleRate: Double {
        get { lock.lock(); defer { lock.unlock() }; return _sampleRate }
        set { lock.lock(); _sampleRate = newValue; lock.unlock() }
    }

    /// How long after the tap sees a sample the output device actually plays it (seconds), as the device reports it.
    var outputLatency: Double {
        get { lock.lock(); defer { lock.unlock() }; return _outputLatency }
        set { lock.lock(); _outputLatency = newValue; lock.unlock() }
    }

    var totalWritten: Int64 {
        lock.lock(); defer { lock.unlock() }; return written
    }

    var burst: Double { lock.lock(); defer { lock.unlock() }; return _burst }
    var callbacks: Int64 { lock.lock(); defer { lock.unlock() }; return _callbacks }

    /// Copies the `count` frames that end at absolute frame `end` (oldest first); frames not yet written are zero.
    func copy(endingAt end: Int64, count: Int, l: UnsafeMutablePointer<Float>, r: UnsafeMutablePointer<Float>) {
        lock.lock()
        let oldest = written - Int64(capacity)
        let start = end - Int64(count)
        for i in 0..<count {
            let pos = start + Int64(i)
            if pos < max(0, oldest) || pos >= written { l[i] = 0; r[i] = 0; continue }
            let idx = Int(pos & mask)
            l[i] = left[idx]
            r[i] = right[idx]
        }
        lock.unlock()
    }

    /// Accepts either one interleaved buffer or separate (non-interleaved) channel buffers, Float32.
    func write(_ list: UnsafePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard abl.count > 0, let d0 = abl[0].mData else { return }
        if abl.count == 1 {
            let ch = Int(max(1, abl[0].mNumberChannels))
            let frames = Int(abl[0].mDataByteSize) / (4 * ch)
            let p = d0.assumingMemoryBound(to: Float.self)
            write(l: p, ls: ch, r: ch > 1 ? p + 1 : p, rs: ch, frames: frames)
        } else {
            let frames = Int(abl[0].mDataByteSize) / 4
            let pl = d0.assumingMemoryBound(to: Float.self)
            let pr = (abl[1].mData ?? d0).assumingMemoryBound(to: Float.self)
            write(l: pl, ls: 1, r: pr, rs: 1, frames: frames)
        }
    }

    func writeFrames(l: UnsafePointer<Float>, r: UnsafePointer<Float>, frames: Int) {
        write(l: l, ls: 1, r: r, rs: 1, frames: frames)
    }

    private func write(l: UnsafePointer<Float>, ls: Int, r: UnsafePointer<Float>, rs: Int, frames: Int) {
        guard frames > 0 else { return }
        lock.lock()
        let base = written
        for i in 0..<frames {
            let idx = Int((base + Int64(i)) & mask)
            left[idx] = l[i * ls]
            right[idx] = r[i * rs]
        }
        written = base + Int64(frames)
        _burst = max(Double(frames), _burst * 0.998)
        _callbacks += 1
        lock.unlock()
    }

    /// Copies up to `count` frames starting at absolute frame `from`. Returns frames copied.
    func copy(from: Int64, count: Int, l: UnsafeMutablePointer<Float>, r: UnsafeMutablePointer<Float>) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let oldest = max(0, written - Int64(capacity))
        let start = max(from, oldest)
        let n = Int(min(Int64(count), written - start))
        guard n > 0 else { return 0 }
        for i in 0..<n {
            let idx = Int((start + Int64(i)) & mask)
            l[i] = left[idx]
            r[i] = right[idx]
        }
        return n
    }
}
