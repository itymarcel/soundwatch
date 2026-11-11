import AppKit
import MetalKit
import SwiftUI

struct ContentView: View {
    @Bindable var store: SettingsStore
    @Bindable var app: AppState
    let engine: VizEngine
    @Environment(\.openWindow) private var openWindow

    @State private var hudVisible = true
    @State private var hudHovered = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .top) {
            MetalVizView(store: store, app: app, engine: engine)
                .ignoresSafeArea()

            if hudVisible || hudHovered {
                HUD(store: store, app: app)
                    .padding(.top, 10)
                    .onHover { hudHovered = $0 }
                    .transition(.opacity)
            }

            if store.s.showFPS {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    Text(String(format: "%.0f fps · audio %.0f-frame bursts · %.0f ms buffer",
                                engine.fps, engine.analyzer.ioBurst, engine.analyzer.bufferMs))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.regularMaterial, in: Capsule())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(10)
                .allowsHitTesting(false)
            }

            if let status = app.status {
                VStack {
                    Spacer()
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 460)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, 56).padding(.horizontal, 30)
                }
                .allowsHitTesting(false)
            }
        }
        .background(WindowAccessor { window in
            app.window = window
            configure(window)
        })
        .onContinuousHover { phase in
            if case .active = phase { pokeHUD() }
        }
        .inspector(isPresented: $app.showSettings) {
            SettingsPanel(store: store, app: app)
                .inspectorColumnWidth(min: 230, ideal: 260, max: 360)
        }
        .onChange(of: store.s.alwaysOnTop) { _, onTop in
            app.window?.level = onTop ? .floating : .normal
        }
        .onAppear {
            engine.start(app: app)
            pokeHUD()
            if DebugSnapshot.nodesPath != nil { openWindow(id: "nodes") }
        }
    }

    private func configure(_ w: NSWindow) {
        w.isOpaque = false
        w.backgroundColor = .clear
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = false   // dragging the view orbits the camera; ⌘-drag moves the window
        w.collectionBehavior.insert(.fullScreenPrimary)
        w.level = store.s.alwaysOnTop ? .floating : .normal
    }

    private func pokeHUD() {
        if !hudVisible { withAnimation(.easeOut(duration: 0.2)) { hudVisible = true } }
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.4)) { hudVisible = false }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }
}

/// Hosts the Metal view; the renderer pulls settings each frame (no SwiftUI redraws involved).
struct MetalVizView: NSViewRepresentable {
    let store: SettingsStore
    let app: AppState
    let engine: VizEngine

    final class Coordinator { var renderer: Renderer? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MTKView {
        let v = DraggableMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        v.camera = app.camera
        v.colorPixelFormat = .bgra8Unorm
        v.framebufferOnly = !DebugSnapshot.enabled
        v.preferredFramesPerSecond = 120
        v.clearColor = MTLClearColorMake(0, 0, 0, 0)
        v.layer?.isOpaque = false
        context.coordinator.renderer = Renderer(view: v, store: store, app: app, engine: engine)
        return v
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}
}

/// Metal view with in-window camera controls:
/// drag = orbit, right-drag / ⌥-drag / ⇧-drag / two-finger scroll = pan, mouse wheel / pinch = zoom,
/// double-click = centre (zoom kept), ⌘-drag = move the window.
final class DraggableMTKView: MTKView {
    var camera: Camera?
    private enum Drag { case none, orbit, pan }
    private var drag = Drag.none

    override var mouseDownCanMoveWindow: Bool { false }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with e: NSEvent) {
        if e.modifierFlags.contains(.command) { window?.performDrag(with: e); drag = .none; return }
        if e.clickCount == 2 { camera?.centre(); drag = .none; return }
        drag = e.modifierFlags.contains(.option) || e.modifierFlags.contains(.shift) ? .pan : .orbit
        NSCursor.closedHand.push()
    }
    override func mouseDragged(with e: NSEvent) {
        switch drag {
        case .orbit: camera?.rotate(dx: Float(e.deltaX), dy: Float(e.deltaY))
        case .pan: camera?.pan(dx: Float(e.deltaX), dy: Float(e.deltaY))
        case .none: break
        }
    }
    override func mouseUp(with e: NSEvent) {
        if drag != .none { NSCursor.pop() }
        drag = .none
    }
    override func rightMouseDragged(with e: NSEvent) { camera?.pan(dx: Float(e.deltaX), dy: Float(e.deltaY)) }
    override func otherMouseDragged(with e: NSEvent) { camera?.pan(dx: Float(e.deltaX), dy: Float(e.deltaY)) }

    override func scrollWheel(with e: NSEvent) {
        if e.hasPreciseScrollingDeltas && !e.modifierFlags.contains(.command) {
            // Trackpad: two-finger scroll pans (⌘ + scroll zooms)
            camera?.pan(dx: Float(e.scrollingDeltaX), dy: Float(e.scrollingDeltaY))
        } else {
            let dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY * 0.01 : e.scrollingDeltaY * 0.1
            camera?.zoom(by: Float(exp(dy)), around: cursorOffset(e))
        }
    }
    override func magnify(with e: NSEvent) {
        camera?.zoom(by: Float(1 + e.magnification), around: cursorOffset(e))
    }

    /// Cursor position relative to the view centre, in points, y down.
    private func cursorOffset(_ e: NSEvent) -> SIMD2<Float> {
        let p = convert(e.locationInWindow, from: nil)
        return SIMD2(Float(p.x - bounds.midX), Float(bounds.midY - p.y))
    }
}

/// Small native toolbar that fades out when the mouse is idle.
struct HUD: View {
    @Bindable var store: SettingsStore
    @Bindable var app: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 6) {
            Picker("Mode", selection: $store.s.mode) {
                ForEach(VizMode.allCases) { m in Image(systemName: m.symbol).help(m.title).tag(m) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Button { app.camera.centre() } label: {
                Image(systemName: "scope").frame(width: 14)
            }
            .help("Centre the view, keeping the zoom (R). Drag to rotate, right/⌥-drag or two-finger scroll to pan, wheel or pinch to zoom, double-click to centre, ⌘-drag to move the window.")
            Button { app.frozen.toggle() } label: {
                Image(systemName: app.frozen ? "play.fill" : "pause.fill").frame(width: 14)
            }
            .help("Freeze (Space)")
            Button { openWindow(id: "nodes") } label: {
                Image(systemName: "point.3.connected.trianglepath.dotted").frame(width: 14)
            }
            .help("Nodes: connect the music to any setting (N)")
            Button { app.showSettings.toggle() } label: {
                Image(systemName: "slider.horizontal.3").frame(width: 14)
            }
            .help("Settings (S)")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
    }
}
