import AppKit
import Metal
import SwiftUI

/// Debug aid: with AUDIOWATCH_SNAPSHOT=/path/prefix set, saves the composited frame as PNG at the frame numbers
/// listed in AUDIOWATCH_SNAPSHOT_FRAMES (comma separated, default "60"), then quits after the last one.
enum DebugSnapshot {
    static let prefix = ProcessInfo.processInfo.environment["AUDIOWATCH_SNAPSHOT"]
    static let frames: [Int] = (ProcessInfo.processInfo.environment["AUDIOWATCH_SNAPSHOT_FRAMES"] ?? "60")
        .split(separator: ",").compactMap { Int($0) }
    static var enabled: Bool { prefix != nil }
    /// AUDIOWATCH_RECORD=start,seconds,fps: instead of frame numbers, saves `<prefix>-0000.png`, `-0001` … at evenly spaced
    /// times (seconds since the first frame), for GIFs. A slow frame that passes several sample times is written for each.
    static let record: (start: Double, dur: Double, fps: Double)? = {
        let v = (ProcessInfo.processInfo.environment["AUDIOWATCH_RECORD"] ?? "").split(separator: ",").compactMap { Double($0) }
        return v.count == 3 && v[2] > 0 ? (v[0], v[1], v[2]) : nil
    }()
    private static var recNext = 0
    private static let writes = DispatchGroup()

    static func capture(_ tex: MTLTexture, frame: Int, time: Double, cmd: MTLCommandBuffer, device: MTLDevice) {
        guard let prefix else { return }
        var names: [String] = []
        var last = false
        if let r = record {
            let total = max(1, Int((r.dur * r.fps).rounded()))
            while recNext < total && time >= r.start + Double(recNext) / r.fps {
                names.append(String(format: "%@-%04d.png", prefix, recNext)); recNext += 1
            }
            last = recNext >= total
        } else if frames.contains(frame) {
            names = ["\(prefix)-\(frame).png"]
            last = frame == frames.max()
        }
        guard !names.isEmpty else { return }
        let w = tex.width, h = tex.height
        guard let dst = device.makeBuffer(length: w * h * 4, options: .storageModeShared),
              let blit = cmd.makeBlitCommandEncoder() else { return }
        blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: dst, destinationOffset: 0, destinationBytesPerRow: w * 4, destinationBytesPerImage: w * h * 4)
        blit.endEncoding()
        // PNG encoding happens off the completion handler: done there, it held up the next frames (recordings repeated frames).
        cmd.addCompletedHandler { _ in
            writes.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let cs = CGColorSpace(name: CGColorSpace.sRGB)!
                let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
                // The buffer outlives the context, so its memory stays valid while the image is made.
                if let ctx = CGContext(data: dst.contents(), width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                       space: cs, bitmapInfo: info),
                   let img = ctx.makeImage() {
                    let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
                    for n in names { try? png?.write(to: URL(fileURLWithPath: n)) }
                }
                writes.leave()
            }
            if last { writes.notify(queue: .main) { NSApp.terminate(nil) } }
        }
    }
}

extension DebugSnapshot {
    /// Debug aid: AUDIOWATCH_NODES_SNAPSHOT=/path.png renders the node editor panel in its own off-screen window,
    /// saves a picture after ~3 s and quits.
    static let nodesPath = ProcessInfo.processInfo.environment["AUDIOWATCH_NODES_SNAPSHOT"]
    @MainActor private static var nodesWindow: NSWindow?

    @MainActor static func captureNodes(store: SettingsStore, app: AppState, engine: VizEngine) {
        guard let nodesPath else { return }
        // AUDIOWATCH_NODES_EXAMPLES=1: show every example patch (stacked) instead of the saved patch
        if ProcessInfo.processInfo.environment["AUDIOWATCH_NODES_EXAMPLES"] != nil {
            var g = NodeGraph(), y = 0.0
            for p in ExamplePatch.all {
                let b = p.build(x: 0, y: y)
                g.nodes += b.nodes; g.links += b.links
                y += 240
            }
            store.s.nodes = g
        }
        let size = NSSize(width: 1100, height: ProcessInfo.processInfo.environment["AUDIOWATCH_NODES_EXAMPLES"] != nil ? 1300 : 320)
        let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: 0), size: size),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: NodesPanel(store: store, app: app, engine: engine, maxHeight: size.height)
            .frame(width: size.width, height: size.height))
        w.orderFrontRegardless()
        nodesWindow = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard let view = w.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: nodesPath))
            NSApp.terminate(nil)
        }
    }
}

extension DebugSnapshot {
    /// Debug aid: AUDIOWATCH_SIDEBAR_SNAPSHOT=/path.png renders the settings sidebar in its own off-screen window,
    /// saves a picture after ~2 s and quits. Add AUDIOWATCH_SIDEBAR_OPEN=1 to show every group open.
    static let sidebarPath = ProcessInfo.processInfo.environment["AUDIOWATCH_SIDEBAR_SNAPSHOT"]
    @MainActor private static var sidebarWindow: NSWindow?

    @MainActor static func captureSidebar(store: SettingsStore, app: AppState) {
        guard let sidebarPath else { return }
        let size = NSSize(width: 270, height: 2600)
        let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: 0), size: size),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: SettingsPanel(store: store, app: app)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        w.orderFrontRegardless()
        sidebarWindow = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard let view = w.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: sidebarPath))
            NSApp.terminate(nil)
        }
    }

    /// AUDIOWATCH_MODEPICKER_SNAPSHOT=/path.png (+ AUDIOWATCH_MODEPICKER_LIST=1 for the list view) renders the mode
    /// picker's gallery off-screen, saves it and quits.
    static let modePickerPath = ProcessInfo.processInfo.environment["AUDIOWATCH_MODEPICKER_SNAPSHOT"]

    @MainActor static func captureModePicker(store: SettingsStore) {
        guard let modePickerPath else { return }
        UserDefaults.standard.set(ProcessInfo.processInfo.environment["AUDIOWATCH_MODEPICKER_LIST"] != nil, forKey: "AudioViz.modePickerList")
        let size = NSSize(width: 470, height: 560)
        let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: 0), size: size),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .aqua)
        w.contentView = NSHostingView(rootView: ModeGallery(mode: .constant(store.s.mode)) {})
        w.orderFrontRegardless()
        sidebarWindow = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard let view = w.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: modePickerPath))
            NSApp.terminate(nil)
        }
    }
}

extension DebugSnapshot {
    /// Debug aid: AUDIOWATCH_SLIDE=<seconds> opens the settings sidebar and, from that many seconds after launch, moves Glow
    /// at 120 Hz (as a slider drag does), printing `MAINBUSY` (the main thread's busy share per second, incl. waits for a
    /// drawable) and the longest run-loop pass. With AUDIOWATCH_PERF=1 the frame rate shows whether the picture keeps up.
    @MainActor static func startSlideSim(store: SettingsStore, app: AppState) {
        guard let v = ProcessInfo.processInfo.environment["AUDIOWATCH_SLIDE"] else { return }
        app.showSettings = true
        var busyStart = 0.0, busy = 0.0, winStart = CACurrentMediaTime(), worst = 0.0, iters = 0
        let obs = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.allActivities.rawValue, true, 0) { _, act in
            let t = CACurrentMediaTime()
            if act == .afterWaiting { busyStart = t }
            if act == .beforeWaiting, busyStart > 0 { let d = t - busyStart; busy += d; worst = max(worst, d); iters += 1; busyStart = 0 }
            if t - winStart >= 1 {
                print(String(format: "MAINBUSY %.0f%% worst=%.1fms iters=%d", busy / (t - winStart) * 100, worst * 1000, iters))
                busy = 0; worst = 0; iters = 0; winStart = t
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
        let t0 = CACurrentMediaTime() + (Double(v) ?? 3)
        Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { _ in
            let t = CACurrentMediaTime()
            guard t > t0 else { return }
            MainActor.assumeIsolated { store.s.glow = 0.5 + 0.4 * sin((t - t0) * 3) }
        }
    }
}
