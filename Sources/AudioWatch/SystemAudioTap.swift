import AudioToolbox
import CoreAudio
import Foundation

/// Taps the mixed system output (whatever output device is selected) using a
/// Core Audio global process tap (macOS 14.2+). Audio is observed, never altered.
final class SystemAudioTap {
    struct TapError: Error, CustomStringConvertible {
        let step: String
        let status: OSStatus
        var description: String { "Could not \(step) (OSStatus \(status))" }
    }

    private let ring: AudioRing
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "soundwatch.io", qos: .userInteractive)
    private var listening = false
    private var restartWork: DispatchWorkItem?

    /// Called on main with an error message, or nil when capture is running.
    var onStatus: ((String?) -> Void)?
    private(set) var outputName = ""

    init(ring: AudioRing) { self.ring = ring }

    deinit { stop() }

    func start() {
        do {
            try startCapture()
            onStatus?(nil)
        } catch {
            stop()
            onStatus?("\(error)")
        }
        listenForDeviceChanges()
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        procID = nil
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func startCapture() throws {
        stop()

        // 1. Global stereo tap of everything that plays, excluding nobody.
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.name = "soundwatch Tap"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(desc, &tapID), "create the system audio tap")

        let tapUID = try stringProperty(tapID, kAudioTapPropertyUID)
        var format = AudioStreamBasicDescription()
        try property(tapID, kAudioTapPropertyFormat, &format)

        // 2. The current output device acts as the clock source.
        var outputID = AudioObjectID(kAudioObjectUnknown)
        try property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, &outputID)
        let outputUID = try stringProperty(outputID, kAudioDevicePropertyDeviceUID)
        outputName = (try? stringProperty(outputID, kAudioObjectPropertyName)) ?? ""

        ring.outputLatency = outputLatency(of: outputID)

        // 3. Private aggregate device that exposes the tap as an input stream.
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "soundwatch Aggregate",
            kAudioAggregateDeviceUIDKey: "local.audiowatch.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapUID,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID),
                  "create the aggregate device")

        // Small IO buffers: the picture can only react once a buffer has arrived, and the analyzer keeps a safety
        // margin of about one buffer on top. The default (512 frames ≈ 11 ms) costs ~10 ms more than 128 does.
        // Only this app's own private device is affected; if the device refuses, the default stays.
        var frames = UInt32(128)
        var range = AudioValueRange()
        if (try? property(aggregateID, kAudioDevicePropertyBufferFrameSizeRange, &range)) != nil, range.mMinimum > 0 {
            frames = UInt32(min(max(Double(frames), range.mMinimum), range.mMaximum))
        }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(aggregateID, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)

        var rate = Float64(0)
        try? property(aggregateID, kAudioDevicePropertyNominalSampleRate, &rate)
        ring.sampleRate = rate > 0 ? rate : (format.mSampleRate > 0 ? format.mSampleRate : 48_000)

        // 4. Pull buffers into the ring.
        let ring = self.ring
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { _, input, _, _, _ in
            ring.write(input)
        }, "create the IO callback")
        try check(AudioDeviceStart(aggregateID, procID), "start capturing")
    }

    /// Rebuild the tap when the user switches output device (sample rate / clock may change).
    private func listenForDeviceChanges() {
        guard !listening else { return }
        listening = true
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            guard let self else { return }
            self.restartWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.start() }
            self.restartWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }

    /// Device latency + safety offset + stream latency + IO buffer of the output device, in seconds: the time between
    /// a sample being mixed (when the tap sees it) and leaving the speaker. ~30 ms for built-in speakers, a lot more
    /// for Bluetooth. The analyzer holds the picture back by whatever exceeds its own delay, so the two line up.
    private func outputLatency(of device: AudioObjectID) -> Double {
        func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope, _ v: inout T) {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var size = UInt32(MemoryLayout<T>.size)
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &v)
        }
        var latency = UInt32(0), safety = UInt32(0), buffer = UInt32(0), stream = UInt32(0), rate = Float64(0)
        value(device, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, &latency)
        value(device, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput, &safety)
        value(device, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, &buffer)
        value(device, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, &rate)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        if AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size >= 4 {
            var streams = [AudioStreamID](repeating: 0, count: Int(size) / 4)
            if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &streams) == noErr, let first = streams.first {
                value(first, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal, &stream)
            }
        }
        guard rate > 0 else { return 0 }
        return Double(latency + safety + buffer + stream) / rate
    }

    // MARK: - Property helpers

    private func check(_ status: OSStatus, _ step: String) throws {
        if status != noErr { throw TapError(step: step, status: status) }
    }

    private func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) throws {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value), "read property \(selector)")
    }

    private func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var value: Unmanaged<CFString>?
        try property(object, selector, &value)
        guard let value else { throw TapError(step: "read string property \(selector)", status: -1) }
        return value.takeRetainedValue() as String
    }
}
