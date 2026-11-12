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
    @AppStorage("AudioViz.introSeen") private var introSeen = false
    /// Harness runs (env overrides) never show the intro or mark it as seen.
    private static let debugRun = ["AUDIOWATCH_SETTINGS", "AUDIOWATCH_SNAPSHOT", "AUDIOWATCH_WAV", "AUDIOWATCH_NODES_SNAPSHOT"]
        .contains { ProcessInfo.processInfo.environment[$0] != nil }

    private func dismissIntro() {
        withAnimation(.easeOut(duration: 0.2)) { app.showIntro = false }
        if !Self.debugRun { introSeen = true }
        pokeHUD()
    }

    var body: some View {
        ZStack(alignment: .top) {
            MetalVizView(store: store, app: app, engine: engine)
                .ignoresSafeArea()

            if hudVisible || hudHovered || app.showIntro {
                HUD(store: store)
                    .padding(.top, 10)
                    .onHover { hudHovered = $0 }
                    .transition(.opacity)
                HStack(spacing: 6) {
                    CornerButton(symbol: "questionmark", help: "How to use soundwatch") { app.startIntro() }
                    CornerButton(symbol: "point.3.connected.trianglepath.dotted",
                                 help: "Nodes: connect the music to any setting (N)") { openWindow(id: "nodes") }
                    CornerButton(symbol: "slider.horizontal.3",
                                 help: app.showSettings ? "Hide settings (S)" : "Show settings (S)") { app.showSettings.toggle() }
                }
                .onHover { hudHovered = $0 }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 8).padding(.trailing, 10)
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

            if app.showIntro {
                IntroOverlay { dismissIntro() }
                    .transition(.opacity)
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
            if let cam = store.launchCamera { app.camera.set(cam, for: store.s.mode); store.launchCamera = nil }
            if !introSeen && !Self.debugRun { app.startIntro() }
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

/// Round button floating in the top-right corner.
struct CornerButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 28, height: 28)
                .background(.regularMaterial, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Mode switcher at the top; fades out when the mouse is idle.
struct HUD: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Picker("Mode", selection: $store.s.mode) {
            ForEach(VizMode.allCases) { m in Image(systemName: m.symbol).help(m.title).tag(m) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .controlSize(.small)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
    }
}

/// First-launch / help overlay: tips next to the controls they explain, one button to dismiss.
/// Lives over the canvas only; the settings sidebar (opened by `startIntro`) stays visible to its right.
struct IntroOverlay: View {
    let dismiss: () -> Void

    static let lastModeKey = min(9, VizMode.stable.count)

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            // The two cards are ~552 × 300 incl. the button; shrink them to fit small windows.
            let scale = min(1, (w - 32) / 552, (h - 40) / 330)
            ZStack {
                Color.black.opacity(0.6)
                    .contentShape(Rectangle())
                    .onTapGesture {}   // swallow clicks so the canvas doesn't orbit underneath
                    .ignoresSafeArea()  // dim under the title bar too; the tips stay in the safe area like the HUD

                // Mode bar (top centre)
                if h > 440 { Tip(arrow: "arrow.up", text: "Quick-switch modes here, or press 1–\(Self.lastModeKey).")
                    .frame(maxWidth: min(300, w - 40))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 50) }

                // Corner buttons (top right), only when there's room next to the mode tip
                if w > 760 && h > 440 {
                    Tip(arrow: "arrow.up.right", text: "Help, Nodes (wire the music to any setting) and Settings.")
                        .frame(maxWidth: 210)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(.top, 50).padding(.trailing, 12)
                }

                // Sidebar (right edge, low down)
                if h > 520 { Tip(arrow: "arrow.right", text: "All your settings live in this sidebar: presets, creative controls, colours, effects, media. S shows or hides it.",
                    arrowTrailing: true)
                    .frame(maxWidth: min(320, w - 40))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.bottom, 20).padding(.trailing, 12) }

                // Centre: controls + keys, side by side when there's room
                VStack(spacing: 16) {
                    HStack(alignment: .top, spacing: 12) { MouseCard(); KeysCard() }
                    Button(action: dismiss) { Text("Got it").frame(minWidth: 90) }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
                .fixedSize()
                .scaleEffect(scale)
                .frame(width: w, height: h)   // layout at window size; the natural width may be larger before scaling
            }
        }
    }
}

private struct Tip: View {
    let arrow: String
    let text: String
    var arrowTrailing = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if !arrowTrailing { arrowView }
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            if arrowTrailing { arrowView }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var arrowView: some View {
        Image(systemName: arrow).font(.system(size: 14, weight: .bold)).foregroundStyle(.tint)
    }
}

private struct IntroCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold))
            content
        }
        .padding(14)
        .frame(width: 270, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct MouseCard: View {
    private struct Row { let icon, action, how: String }
    private let rows = [
        Row(icon: "rotate.3d", action: "Rotate", how: "Drag"),
        Row(icon: "arrow.up.and.down.and.arrow.left.and.right", action: "Pan", how: "Right-drag or two-finger scroll"),
        Row(icon: "plus.magnifyingglass", action: "Zoom", how: "Scroll or pinch"),
        Row(icon: "scope", action: "Re-centre", how: "Double-click or R"),
        Row(icon: "macwindow", action: "Move window", how: "⌘-drag"),
    ]

    var body: some View {
        IntroCard(title: "Mouse & trackpad") {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                ForEach(rows, id: \.action) { r in
                    GridRow {
                        Image(systemName: r.icon)
                            .font(.system(size: 14))
                            .foregroundStyle(.tint)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.action).font(.system(size: 12, weight: .medium))
                            Text(r.how).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

private struct KeysCard: View {
    private struct Row { let keys: [String]; let label: String }
    private let rows = [
        Row(keys: ["1", "–", "\(IntroOverlay.lastModeKey)"], label: "Modes"),
        Row(keys: ["S"], label: "Settings sidebar"),
        Row(keys: ["N"], label: "Nodes"),
        Row(keys: ["F"], label: "Full screen"),
        Row(keys: ["T"], label: "Always on top"),
        Row(keys: ["Space"], label: "Freeze the picture"),
        Row(keys: ["R"], label: "Re-centre the view"),
    ]

    var body: some View {
        IntroCard(title: "Keys") {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                ForEach(rows, id: \.label) { r in
                    GridRow {
                        HStack(spacing: 3) {
                            ForEach(Array(r.keys.enumerated()), id: \.offset) { _, k in
                                if k == "–" { Text("–").foregroundStyle(.secondary) } else { Keycap(k) }
                            }
                        }
                        .gridColumnAlignment(.trailing)
                        Text(r.label).font(.system(size: 12))
                    }
                }
            }
        }
    }
}

private struct Keycap: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.3), lineWidth: 1))
            .overlay(alignment: .bottom) {   // thicker bottom edge, like a real key
                RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.25)).frame(height: 2).padding(.horizontal, 3)
            }
    }
}
