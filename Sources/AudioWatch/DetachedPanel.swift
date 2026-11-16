import AppKit
import SwiftUI

/// A window of its own for the settings or the node editor when the user detaches them from the main window.
/// The frame is remembered per `autosave` name. Closing it with its red button calls `onUserClose`.
final class DetachedPanel: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    var onUserClose: (() -> Void)?

    func show(title: String, autosave: String, size: NSSize, minSize: NSSize, dark: Bool, floating: Bool,
              content: () -> AnyView) {
        if let w = window {
            w.level = floating ? .floating : .normal
            return
        }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        if dark { w.appearance = NSAppearance(named: .darkAqua) }
        let host = NSHostingView(rootView: content())
        host.sizingOptions = []          // the window decides the size, not the SwiftUI content
        w.contentView = host
        w.setContentSize(size)
        w.contentMinSize = minSize
        w.center()
        w.setFrameAutosaveName(autosave)  // puts back the last frame, if there is one
        w.delegate = self
        w.level = floating ? .floating : .normal
        window = w
        w.makeKeyAndOrderFront(nil)
    }

    func hide() {
        guard let w = window else { return }
        window = nil
        w.delegate = nil
        w.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        onUserClose?()
    }
}
