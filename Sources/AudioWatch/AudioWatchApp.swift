import AppKit
import SwiftUI

@main
struct AudioWatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = SettingsStore()
    @State private var app = AppState()
    @State private var engine = VizEngine()

    var body: some Scene {
        Window("soundwatch", id: "main") {
            ContentView(store: store, app: app, engine: engine)
                .frame(minWidth: 420, minHeight: 300)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 720)
        .commands { VizCommands(store: store, app: app) }

        Window("Nodes", id: "nodes") {
            NodeEditorView(store: store, app: app, engine: engine)
                .frame(minWidth: 520, minHeight: 360)
        }
        .defaultSize(width: 1000, height: 640)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct VizCommands: Commands {
    @Bindable var store: SettingsStore
    @Bindable var app: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Visualizer") {
            ForEach(Array(VizMode.stable.prefix(9).enumerated()), id: \.element) { i, mode in
                Button(mode.title) { store.s.mode = mode }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [])
                    .disabled(app.textEditing)
            }
            Menu("Experimental") {
                ForEach(VizMode.experimental) { mode in
                    Button(mode.title) { store.s.mode = mode }
                }
            }
            Divider()
            Button(app.showSettings ? "Hide Settings" : "Show Settings") { app.showSettings.toggle() }
                .keyboardShortcut("s", modifiers: [])
                .disabled(app.textEditing)
            Button(app.frozen ? "Unfreeze" : "Freeze Frame") { app.frozen.toggle() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(app.textEditing)
            Button("Nodes…") { openWindow(id: "nodes") }
                .keyboardShortcut("n", modifiers: [])
                .disabled(app.textEditing)
            Button("Centre View") { app.camera.centre() }
                .keyboardShortcut("r", modifiers: [])
                .disabled(app.textEditing)
            Button("Toggle Full Screen") { app.window?.toggleFullScreen(nil) }
                .keyboardShortcut("f", modifiers: [])
                .disabled(app.textEditing)
            Toggle("Always on Top", isOn: $store.s.alwaysOnTop)
                .keyboardShortcut("t", modifiers: [])
                .disabled(app.textEditing)
        }
    }
}

/// Grabs the hosting NSWindow so we can make it transparent / floating.
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = WindowView()
        v.onWindow = onWindow
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class WindowView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { DispatchQueue.main.async { self.onWindow?(window) } }
        }
    }
}
