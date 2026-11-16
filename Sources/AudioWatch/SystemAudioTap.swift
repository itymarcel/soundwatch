import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Taps the mixed system output (whatever output device is selected) using a
/// Core Audio global process tap (macOS 14.2+). Audio is observed, never altered.
/// With `inputUID` set it reads that input device (microphone, interface) instead.
final class SystemAudioTap {
    struct TapError: Error, CustomStringConvertible {
        let step: String
        let status: OSStatus
        var description: String { "Could not \(step) (OSStatus \(status))" }
    }

    private let ring: AudioRing
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    /// The device the IO callback runs on: the aggregate (system audio) or the chosen input device.
    private var ioDevice = AudioObjectID(kAudioObjectUnknown)
    /// "" = system audio, else the UID of an input device. Set it, then call `start()`.
    var inputUID = ""
    var inputName = ""
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
        listenForDeviceChanges()
        if !inputUID.isEmpty {
            // Reading an input device needs the microphone permission; without it the device delivers silence.
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .notDetermined:
                stop()
                let uid = inputUID
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                    DispatchQueue.main.async { if let self, self.inputUID == uid { self.start() } }
                }
                return
            case .denied, .restricted:
                stop()
                onStatus?("soundwatch isn't allowed to use audio inputs. Allow it in System Settings › Privacy & Security › Microphone, or switch Input back to System audio (Settings › Response).")
                return
            default: break
            }
        }
        do {
            if inputUID.isEmpty { try startCapture() } else { try startInput() }
            onStatus?(nil)
        } catch {
            stop()
            onStatus?("\(error)")
        }
    }

    func stop() {
        if ioDevice != kAudioObjectUnknown, let procID {
            AudioDeviceStop(ioDevice, procID)
            AudioDeviceDestroyIOProcID(ioDevice, procID)
        }
        ioDevice = AudioObjectID(kAudioObjectUnknown)
        if aggregateID != kAudioObjectUnknown {
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

        // Don't shrink the IO buffer size here. The aggregate wraps the real output device, so a smaller buffer is
        // applied to the speakers themselves: every app then has to deliver audio every few ms and playback glitches
        // (it did at 128 frames). The default (usually 512) costs ~10 ms of reaction time; A/V sync covers that.

        var rate = Float64(0)
        try? property(aggregateID, kAudioDevicePropertyNominalSampleRate, &rate)
        ring.sampleRate = rate > 0 ? rate : (format.mSampleRate > 0 ? format.mSampleRate : 48_000)

        // 4. Pull buffers into the ring.
        let ring = self.ring
        ioDevice = aggregateID
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { _, input, _, _, _ in
            ring.write(input)
        }, "create the IO callback")
        try check(AudioDeviceStart(aggregateID, procID), "start capturing")
    }

    /// Reads the chosen input device directly (its first two channels). The sound is heard live, not through the
    /// speakers, so there is no output delay to wait for.
    private func startInput() throws {
        stop()
        guard let device = AudioInputs.device(uid: inputUID) else {
            throw InputError(text: "The input \u{201C}\(inputName.isEmpty ? inputUID : inputName)\u{201D} isn't connected. Plug it in, or pick another Input in Settings › Response.")
        }
        outputName = (try? stringProperty(device, kAudioObjectPropertyName)) ?? inputName
        ring.outputLatency = 0
        var rate = Float64(0)
        try? property(device, kAudioDevicePropertyNominalSampleRate, &rate)
        ring.sampleRate = rate > 0 ? rate : 48_000
        let ring = self.ring
        ioDevice = device
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, device, ioQueue) { _, input, _, _, _ in
            ring.write(input, first: true)
        }, "create the IO callback for the input")
        try check(AudioDeviceStart(device, procID), "start the input")
    }

    struct InputError: Error, CustomStringConvertible {
        let text: String
        var description: String { text }
    }

    /// Rebuild the capture when the user switches output device (sample rate / clock may change; system audio only)
    /// or when devices come and go (a chosen input that was unplugged starts again when it's back).
    private func listenForDeviceChanges() {
        guard !listening else { return }
        listening = true
        func restartSoon() {
            restartWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.start() }
            restartWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            guard let self, self.inputUID.isEmpty else { return }
            restartSoon()
        }
        var devices = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devices, .main) { [weak self] _, _ in
            NotificationCenter.default.post(name: AudioInputs.changed, object: nil)
            guard let self, !self.inputUID.isEmpty else { return }
            // only when the chosen input appeared or vanished (our own aggregate device also changes this list)
            let present = AudioInputs.device(uid: self.inputUID) != nil
            if present != (self.ioDevice != kAudioObjectUnknown) { restartSoon() }
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

/// The audio input devices (microphones, interfaces, loopback drivers) that can be picked as the source.
enum AudioInputs {
    static let changed = Notification.Name("soundwatch.audioInputsChanged")

    static func list() -> [(uid: String, name: String)] {
        devices().compactMap { id in
            guard hasInput(id), let uid = string(id, kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix("local.audiowatch.aggregate") else { return nil }
            return (uid, string(id, kAudioObjectPropertyName) ?? uid)
        }
    }

    static func device(uid: String) -> AudioObjectID? {
        devices().first { hasInput($0) && string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    private static func devices() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func hasInput(_ id: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
