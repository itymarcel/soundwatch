import AppKit
import SwiftUI

/// Fixed node geometry, so port positions can be computed without measuring views.
private enum NL {
    static let width: CGFloat = 196
    static let header: CGFloat = 26
    static let row: CGFloat = 22
    static let pad: CGFloat = 4

    static func rows(_ k: NodeKind) -> Int { k.inputs.count + k.fields.count + (k == .param ? 1 : 0) }
    static func height(_ k: NodeKind) -> CGFloat { header + pad * 2 + CGFloat(rows(k)) * row }
    static func inPort(_ n: GraphNode, _ i: Int) -> CGPoint {
        CGPoint(x: n.x, y: n.y + header + pad + row * (CGFloat(i) + 0.5))
    }
    static func outPort(_ n: GraphNode) -> CGPoint { CGPoint(x: n.x + width, y: n.y + header / 2) }
}

extension NodeCategory {
    var color: Color {
        switch self {
        case .input: Color(red: 0.35, green: 0.85, blue: 0.55)
        case .generator: Color(red: 0.75, green: 0.5, blue: 1)
        case .modifier: Color(red: 0.4, green: 0.68, blue: 1)
        case .output: Color(red: 1, green: 0.62, blue: 0.3)
        }
    }
}

struct NodeEditorView: View {
    @Bindable var store: SettingsStore
    @Bindable var app: AppState
    let engine: VizEngine
    @State private var window: NSWindow?
    @State private var keyMonitor: Any?
    @State private var scrollMonitor: Any?
    /// The editor's frame in its window's content view (top-left origin), for the trackpad pan.
    @State private var frameInWindow = CGRect.zero

    @State private var pan = CGSize(width: 40, height: 40)
    @State private var panStart: CGSize?
    @State private var hover = CGPoint(x: 200, y: 200)
    @State private var selection: UUID?
    @State private var moving: (id: UUID, offset: CGSize)?
    @State private var wire: (from: UUID, to: CGPoint)?
    @State private var size = CGSize(width: 900, height: 320)
    @State private var showExamples = false

    private var graph: NodeGraph { store.v.nodes }

    var body: some View {
        ZStack(alignment: .topLeading) {
            background
            wires.allowsHitTesting(false)
            ForEach(graph.nodes) { n in
                NodeCard(store: store, app: app, engine: engine, id: n.id, selected: selection == n.id,
                         onSelect: { selection = n.id; endTyping() },
                         onMove: { t in moving = (n.id, t) },
                         onMoveEnd: { t in commitMove(n.id, t) })
                    .position(center(of: n))
            }
            ports
            if graph.nodes.isEmpty {
                Text("Click + (or right-click) to add nodes, or try \u{201C}Add example patch\u{201D}.\nDrag from a node's output (right dot) to an input (left dot).")
                    .multilineTextAlignment(.center)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
            toolbar
        }
        .coordinateSpace(.named("canvas"))
        .onContinuousHover(coordinateSpace: .named("canvas")) { phase in
            if case .active(let p) = phase { hover = p }
        }
        .background(Color(white: 0.075))
        .background(GeometryReader { g in
            Color.clear.onAppear { size = g.size; frameInWindow = g.frame(in: .global) }
                .onChange(of: g.size) { _, new in size = new }
                .onChange(of: g.frame(in: .global)) { _, new in frameInWindow = new }
        })
        .clipped()
        .sheet(isPresented: $showExamples) {
            ExamplePatchDialog { patch in
                showExamples = false
                if let patch { addExample(patch) }
            }
        }
        .environment(\.colorScheme, .dark)
        .background(WindowAccessor { w in window = w })
        .onAppear {
            installKeyMonitor()
            DispatchQueue.main.async { takePendingParams() }   // after the size reader has measured the editor
        }
        .onChange(of: app.pendingParamNodes) { _, _ in takePendingParams() }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
            keyMonitor = nil
            scrollMonitor = nil
        }
    }

    // MARK: - Layers

    private var background: some View {
        Canvas { ctx, size in
            let step: CGFloat = 22
            let ox = pan.width.truncatingRemainder(dividingBy: step), oy = pan.height.truncatingRemainder(dividingBy: step)
            var dots = Path()
            var y = oy - step
            while y < size.height + step {
                var x = ox - step
                while x < size.width + step {
                    dots.addEllipse(in: CGRect(x: x - 0.9, y: y - 0.9, width: 1.8, height: 1.8))
                    x += step
                }
                y += step
            }
            ctx.fill(dots, with: .color(Color(white: 0.28)))
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 2)
            .onChanged { g in
                if panStart == nil { panStart = pan }
                pan = CGSize(width: panStart!.width + g.translation.width, height: panStart!.height + g.translation.height)
            }
            .onEnded { _ in panStart = nil })
        .onTapGesture { selection = nil; endTyping() }
        .contextMenu { addMenu(atCursor: true) }
    }

    /// The list of node kinds: the right-click menu drops the node at the cursor, the + button in the middle.
    @ViewBuilder private func addMenu(atCursor: Bool) -> some View {
        ForEach(NodeKind.menu, id: \.category) { section in
            Section(section.category.rawValue) {
                ForEach(section.items, id: \.title) { item in
                    Button(item.title) { add(item.kind, values: item.values, atCursor: atCursor) }
                }
            }
        }
    }

    private var wires: some View {
        Canvas { ctx, _ in
            for l in graph.links {
                guard let a = node(l.from), let b = node(l.to) else { continue }
                let p0 = view(NL.outPort(a)), p1 = view(NL.inPort(b, l.port))
                ctx.stroke(curve(p0, p1), with: .color(a.kind.category.color.opacity(0.8)), lineWidth: 2)
            }
            if let w = wire, let a = node(w.from) {
                ctx.stroke(curve(view(NL.outPort(a)), w.to), with: .color(.white.opacity(0.7)),
                           style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
            }
        }
    }

    private var ports: some View {
        ForEach(graph.nodes) { stored in
            let n = node(stored.id) ?? stored   // follows the card while it's being dragged
            if n.kind.hasOutput {
                PortDot(color: n.kind.category.color, filled: graph.links.contains { $0.from == n.id })
                    .position(view(NL.outPort(n)))
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
                        .onChanged { g in wire = (n.id, g.location) }
                        .onEnded { g in connect(from: n.id, at: g.location); wire = nil })
                    .help("Drag to an input")
            }
            ForEach(n.kind.inputs.indices, id: \.self) { i in
                let link = graph.link(into: n.id, port: i)
                PortDot(color: link.flatMap { node($0.from) }?.kind.category.color ?? .gray, filled: link != nil)
                    .position(view(NL.inPort(n, i)))
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
                        .onChanged { g in
                            // pulling a connected input detaches the wire and keeps it on the cursor
                            if wire == nil, let l = graph.link(into: n.id, port: i) {
                                store.v.nodes.links.removeAll { $0 == l }
                                wire = (l.from, g.location)
                            } else if let w = wire { wire = (w.from, g.location) }
                        }
                        .onEnded { g in
                            if let w = wire { connect(from: w.from, at: g.location) }
                            wire = nil
                        })
                    .help(link == nil ? "Input" : "Drag to disconnect or re-route")
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Menu { addMenu(atCursor: false) } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add a node (or right-click the grid)")
            Button("Add example patch…") { showExamples = true }
                .help("Ready-made little patches to start from")
            Toggle("Patch active", isOn: $store.v.nodes.enabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
            Text("Drag background: pan · ⌫: delete selected")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button("Reset view") { pan = CGSize(width: 40, height: 40) }
            Button("Clear all") {
                store.v.nodes.nodes = []
                store.v.nodes.links = []
                selection = nil
            }
            .disabled(graph.nodes.isEmpty)
            Button {
                withAnimation(.easeOut(duration: 0.25)) { app.nodesDetached.toggle() }
            } label: {
                Image(systemName: app.nodesDetached ? "rectangle.bottomthird.inset.filled" : "macwindow.on.rectangle")
            }
            .help(app.nodesDetached ? "Put the nodes back into the main window" : "Detach: show the nodes in a window of their own")
            Button { app.toggleNodes() } label: { Image(systemName: "xmark") }
                .help("Hide nodes (N)")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.regularMaterial)
    }

    // MARK: - Geometry

    private func node(_ id: UUID) -> GraphNode? {
        guard var n = graph.node(id) else { return nil }
        if let m = moving, m.id == id { n.x += m.offset.width; n.y += m.offset.height }
        return n
    }
    private func view(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + pan.width, y: p.y + pan.height) }
    private func center(of n: GraphNode) -> CGPoint {
        let n = node(n.id) ?? n
        return view(CGPoint(x: n.x + NL.width / 2, y: n.y + NL.height(n.kind) / 2))
    }
    private func curve(_ a: CGPoint, _ b: CGPoint) -> Path {
        let dx = max(40, abs(b.x - a.x) * 0.5)
        var p = Path()
        p.move(to: a)
        p.addCurve(to: b, control1: CGPoint(x: a.x + dx, y: a.y), control2: CGPoint(x: b.x - dx, y: b.y))
        return p
    }

    // MARK: - Editing

    /// Clicking a node or the grid finishes any number being typed (so ⌫ deletes nodes again).
    private func endTyping() {
        if window?.firstResponder is NSText { window?.makeFirstResponder(nil) }
    }

    /// ⌫ / ⌦ deletes the selected node, unless a number box is being typed in.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.keyCode == 51 || e.keyCode == 117, let w = window, e.window === w,
                  !(w.firstResponder is NSText), let id = selection else { return e }
            delete(id)
            return nil
        }
        // Two-finger scroll (or the mouse wheel) over the editor pans the grid. SwiftUI has no scroll gesture, so a
        // local monitor takes the scroll events that land inside the editor's frame.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
            guard let w = window, e.window === w, let cv = w.contentView else { return e }
            let p = cv.convert(e.locationInWindow, from: nil)
            let pt = CGPoint(x: p.x, y: cv.isFlipped ? p.y : cv.bounds.height - p.y)
            guard frameInWindow.contains(pt) else { return e }
            let k: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 10
            pan = CGSize(width: pan.width + e.scrollingDeltaX * k, height: pan.height + e.scrollingDeltaY * k)
            Renderer.markUIActive()   // the event is swallowed here, so the renderer's own monitor may never see it
            return nil
        }
    }

    private func add(_ kind: NodeKind, values: [String: Double], atCursor: Bool) {
        // from the + button: the middle of the visible grid, stepping down-right so several adds don't stack
        let step = CGFloat(graph.nodes.count % 6) * 22
        let at = atCursor ? hover : CGPoint(x: size.width / 2 - NL.width / 2 + step, y: size.height / 2 - 40 + step)
        var n = GraphNode(kind: kind, x: at.x - pan.width - 20, y: at.y - pan.height - 12, values: values)
        if kind == .param { n.target = "size" }
        store.v.nodes.nodes.append(n)
        selection = n.id
    }

    /// Parameter nodes asked for by the settings' workflow buttons: each goes to a free spot in view, selected.
    private func takePendingParams() {
        let ids = app.pendingParamNodes
        guard !ids.isEmpty else { return }
        app.pendingParamNodes = []
        for id in ids {
            let at = freeSpot(.param)
            var n = GraphNode(kind: .param, x: at.x, y: at.y)
            n.target = id
            store.v.nodes.nodes.append(n)
            selection = n.id
        }
    }

    /// Grid position for a new node: the middle of the visible editor, else the nearest place around it that doesn't
    /// overlap another node (still in view if possible).
    private func freeSpot(_ kind: NodeKind) -> CGPoint {
        let w = Double(NL.width), h = Double(NL.height(kind))
        let cx = Double(size.width / 2 - pan.width) - w / 2, cy = Double(size.height / 2 - pan.height) - h / 2
        let view = CGRect(x: -pan.width, y: -pan.height, width: size.width, height: size.height)
        func free(_ x: Double, _ y: Double) -> Bool {
            let r = CGRect(x: x - 12, y: y - 12, width: w + 24, height: h + 24)
            return !graph.nodes.contains { r.intersects(CGRect(x: $0.x, y: $0.y, width: w, height: Double(NL.height($0.kind)))) }
        }
        var best: (CGPoint, Double)?
        for gy in -4...4 { for gx in -4...4 {
            let x = cx + Double(gx) * (w + 24), y = cy + Double(gy) * 60
            guard free(x, y) else { continue }
            let inView = view.contains(CGRect(x: x, y: y, width: w, height: min(h, Double(size.height) - 8)))
            let d = Double(gx * gx) + Double(gy * gy) * 0.5 + (inView ? 0 : 1000)
            if best == nil || d < best!.1 { best = (CGPoint(x: x, y: y), d) }
        } }
        guard let p = best?.0 else { return CGPoint(x: cx, y: cy) }
        // out of view: scroll so it is
        if !view.contains(CGRect(x: p.x, y: p.y, width: w, height: min(h, Double(size.height) - 8))) {
            pan = CGSize(width: size.width / 2 - p.x - w / 2, height: size.height / 2 - p.y - h / 2)
        }
        return p
    }

    /// Adds an example below whatever is already there, switches the patch on and scrolls to it.
    private func addExample(_ patch: ExamplePatch) {
        let x = graph.nodes.map(\.x).min() ?? 0
        let y = graph.nodes.map { $0.y + Double(NL.height($0.kind)) + 40 }.max() ?? 0
        let built = patch.build(x: x, y: y)
        var g = store.v.nodes
        g.nodes += built.nodes
        g.links += built.links
        g.enabled = true
        store.v.nodes = g
        selection = nil
        pan = CGSize(width: 40 - x, height: 60 - y)
    }

    private func delete(_ id: UUID) {
        store.v.nodes.links.removeAll { $0.from == id || $0.to == id }
        store.v.nodes.nodes.removeAll { $0.id == id }
        if selection == id { selection = nil }
    }

    private func commitMove(_ id: UUID, _ t: CGSize) {
        if let i = store.v.nodes.nodes.firstIndex(where: { $0.id == id }) {
            store.v.nodes.nodes[i].x += t.width
            store.v.nodes.nodes[i].y += t.height
        }
        moving = nil
    }

    /// Connects `from` to the input under `p`: the nearest port, or the first free input of the node under it.
    private func connect(from: UUID, at p: CGPoint) {
        var best: (id: UUID, port: Int, d: CGFloat)?
        for n in graph.nodes where n.id != from && !n.kind.inputs.isEmpty {
            for i in n.kind.inputs.indices {
                let q = view(NL.inPort(n, i))
                let d = hypot(q.x - p.x, q.y - p.y)
                if d < 18, d < (best?.d ?? .infinity) { best = (n.id, i, d) }
            }
            if best == nil {
                let o = view(CGPoint(x: n.x, y: n.y))
                if CGRect(x: o.x, y: o.y, width: NL.width, height: NL.height(n.kind)).contains(p) {
                    let free = n.kind.inputs.indices.first { graph.link(into: n.id, port: $0) == nil } ?? 0
                    best = (n.id, free, 0)
                }
            }
        }
        guard let b = best, !reaches(b.id, from) else { return }
        store.v.nodes.links.removeAll { $0.to == b.id && $0.port == b.port }
        store.v.nodes.links.append(NodeLink(from: from, to: b.id, port: b.port))
    }

    /// True if `a`'s output already flows (directly or not) into `b`: connecting b → a would make a loop.
    private func reaches(_ a: UUID, _ b: UUID) -> Bool {
        if a == b { return true }
        var stack = [a], seen: Set<UUID> = []
        while let x = stack.popLast() {
            if x == b { return true }
            guard seen.insert(x).inserted else { continue }
            stack += graph.links.filter { $0.from == x }.map(\.to)
        }
        return false
    }
}

// MARK: - Pieces

/// "Add example patch": a short list to pick from. Calls `done` with the choice, or nil for Cancel.
private struct ExamplePatchDialog: View {
    let done: (ExamplePatch?) -> Void
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add example patch").font(.system(size: 14, weight: .semibold))
            Text("Pick one to drop it into the editor. It is added below your own nodes, nothing is replaced.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 4) {
                ForEach(ExamplePatch.all) { p in
                    Button { done(p) } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.title).font(.system(size: 12, weight: .medium))
                                Text(p.summary).font(.system(size: 11)).foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "plus.circle").font(.system(size: 14)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(hovered == p.id ? 0.14 : 0.06)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovered = $0 ? p.id : (hovered == p.id ? nil : hovered) }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 420)
        // The sheet's own backdrop follows the system appearance: in light mode the dark-scheme (white) text sat on a
        // light sheet and nothing could be read. So the dialog brings its own dark ground.
        .background(Color(white: 0.13))
        .environment(\.colorScheme, .dark)
    }
}

private struct PortDot: View {
    let color: Color
    let filled: Bool
    var body: some View {
        ZStack {
            Circle().fill(Color(white: 0.1))
            Circle().strokeBorder(color, lineWidth: 2)
            if filled { Circle().fill(color).padding(4) }
        }
        .frame(width: 13, height: 13)
        .padding(5)               // bigger hit area
        .contentShape(Circle())
    }
}

private struct NodeCard: View {
    @Bindable var store: SettingsStore
    @Bindable var app: AppState
    let engine: VizEngine
    let id: UUID
    let selected: Bool
    let onSelect: () -> Void
    let onMove: (CGSize) -> Void
    let onMoveEnd: (CGSize) -> Void

    private var index: Int? { store.v.nodes.nodes.firstIndex { $0.id == id } }

    var body: some View {
        if let i = index {
            let n = store.v.nodes.nodes[i]
            let color = n.kind.category.color
            VStack(spacing: 0) {
                header(n, color)
                VStack(spacing: 0) {
                    ForEach(Array(n.kind.inputs.enumerated()), id: \.offset) { _, name in
                        Text(name).font(.system(size: 10)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 12)
                            .frame(height: NL.row)
                    }
                    if n.kind == .param { targetPicker(i).frame(height: NL.row) }
                    ForEach(n.kind.fields, id: \.key) { f in
                        // in Set mode the input spans the whole range, so Amount has no effect
                        let idle = n.kind == .param && f.key == "amount" && n.value("mode") >= 0.5
                        fieldRow(i, f).frame(height: NL.row)
                            .opacity(idle ? 0.35 : 1)
                            .allowsHitTesting(!idle)
                    }
                }
                .padding(.vertical, NL.pad)
                .padding(.horizontal, 8)
            }
            .frame(width: NL.width, height: NL.height(n.kind), alignment: .top)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.14)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? Color.white.opacity(0.8) : color.opacity(0.35), lineWidth: selected ? 1.5 : 1))
            .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
            .onTapGesture { onSelect() }
            .contextMenu {
                Button("Duplicate") {
                    var c = n
                    c.id = UUID(); c.x += 24; c.y += 24
                    store.v.nodes.nodes.append(c)
                }
                Button("Disconnect") { store.v.nodes.links.removeAll { $0.from == id || $0.to == id } }
                Divider()
                Button("Delete", role: .destructive) {
                    store.v.nodes.links.removeAll { $0.from == id || $0.to == id }
                    store.v.nodes.nodes.removeAll { $0.id == id }
                }
            }
        }
    }

    private func header(_ n: GraphNode, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(n.kind == .param ? (ModParam.byID[n.target]?.title ?? "Parameter") : title(n))
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
                let pinned = engine.nodes.limited.contains(n.id)
                HStack(spacing: 3) {
                    if pinned { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8)) }
                    Text(valueText(n)).font(.system(size: 10).monospacedDigit())
                }
                .foregroundStyle(pinned ? AnyShapeStyle(Color.yellow) : AnyShapeStyle(.secondary))
                .help(pinned ? "Pinned at the end of its range: lower Amount, or put a Map range before it." : "")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: NL.header)
        .background(color.opacity(0.16))
        .overlay(alignment: .bottomLeading) {
            // live level of this node's output
            TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
                Rectangle().fill(color)
                    .frame(width: NL.width * CGFloat(meter(n)), height: 3)
            }
        }
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
            .onChanged { g in onSelect(); onMove(g.translation) }
            .onEnded { g in onMoveEnd(g.translation) })
        .help(n.kind.help)
    }

    private func title(_ n: GraphNode) -> String {
        switch n.kind {
        case .band:
            let lo = n.value("lo"), hi = n.value("hi")
            if lo <= 40 && hi <= 200 { return "Bass" }
            if lo >= 250 && hi <= 2500 && lo < hi { return "Mids" }
            if lo >= 3000 { return "Highs" }
            return n.kind.title
        case .hit: return ["Kick", "Snare", "Hats"][min(2, max(0, Int(n.value("drum"))))] + " hit"
        default: return n.kind.title
        }
    }

    private func meter(_ n: GraphNode) -> Double {
        let v = Double(engine.nodes.values[n.id] ?? 0)
        if n.kind == .param, let p = ModParam.byID[n.target] {
            let lo = p.isLog ? log(p.range.lowerBound) : p.range.lowerBound
            let hi = p.isLog ? log(p.range.upperBound) : p.range.upperBound
            let x = p.isLog ? log(max(1e-6, v)) : v
            return min(1, max(0, (x - lo) / (hi - lo)))
        }
        if n.kind == .counter { return v - floor(v) }   // the count itself would pin the meter after a second
        return min(1, max(0, v))
    }

    private func valueText(_ n: GraphNode) -> String {
        guard store.v.nodes.enabled, let v = engine.nodes.values[n.id] else { return "–" }
        return abs(v) >= 100 ? String(format: "%.0f", v) : String(format: "%.2f", v)
    }

    private func targetPicker(_ i: Int) -> some View {
        let cur = store.v.nodes.nodes[i].target
        return Menu {
            ForEach(ModParam.groups, id: \.self) { g in
                Section(g) {
                    ForEach(ModParam.all.filter { $0.group == g }) { p in
                        Button(p.title) { store.v.nodes.nodes[i].target = p.id }
                    }
                }
            }
        } label: {
            Text(ModParam.byID[cur]?.title ?? "Choose…").font(.system(size: 10))
        }
        .menuStyle(.borderlessButton)
        .controlSize(.mini)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func fieldRow(_ i: Int, _ f: NodeField) -> some View {
        let binding = Binding<Double>(
            get: { store.v.nodes.nodes.indices.contains(i) ? store.v.nodes.nodes[i].value(f.key) : f.def },
            set: { v in if store.v.nodes.nodes.indices.contains(i) { store.v.nodes.nodes[i].values[f.key] = v } })
        if f.free {
            HStack(spacing: 4) {
                Text(f.label).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(minLength: 2)
                NumberBox(field: f, value: binding, app: app, autofocus: false, onDone: {})
                    .frame(width: 90)
            }
        } else if f.options.isEmpty {
            ScrubField(field: f, value: binding, app: app)
        } else {
            HStack(spacing: 4) {
                Text(f.label).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Picker(f.label, selection: Binding(get: { Int(binding.wrappedValue.rounded()) },
                                                   set: { binding.wrappedValue = Double($0) })) {
                    ForEach(f.options.indices, id: \.self) { Text(f.options[$0]).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.mini)
                .fixedSize()
            }
        }
    }
}

/// A number you change by dragging sideways (⌥ = fine). Double-click resets it.
private struct ScrubField: View {
    let field: NodeField
    @Binding var value: Double
    let app: AppState
    @State private var start: Double?
    @State private var editing = false

    private func norm(_ v: Double) -> Double {
        let r = field.range
        if field.isLog { return (log(v) - log(r.lowerBound)) / (log(r.upperBound) - log(r.lowerBound)) }
        return (v - r.lowerBound) / (r.upperBound - r.lowerBound)
    }
    private func denorm(_ t: Double) -> Double {
        let r = field.range, t = min(1, max(0, t))
        if field.isLog { return exp(log(r.lowerBound) + t * (log(r.upperBound) - log(r.lowerBound))) }
        return r.lowerBound + t * (r.upperBound - r.lowerBound)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.2))
                RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.12))
                    .frame(width: max(0, geo.size.width * min(1, max(0, norm(value)))))
                HStack {
                    Text(field.label).foregroundStyle(.secondary)
                    Spacer()
                    if editing {
                        NumberBox(field: field, value: $value, app: app, autofocus: true) { editing = false }
                            .frame(width: 70)
                    } else {
                        Text(String(format: field.format, value)).monospacedDigit()
                    }
                }
                .font(.system(size: 10))
                .padding(.horizontal, 6)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { g in
                    if start == nil { start = norm(value) }
                    let fine = NSEvent.modifierFlags.contains(.option) ? 0.1 : 1
                    var v = denorm(start! + g.translation.width / geo.size.width * fine)
                    if field.format.hasPrefix("%.0f") { v = v.rounded() }
                    value = v
                }
                .onEnded { _ in start = nil })
            .simultaneousGesture(TapGesture(count: 2).onEnded { editing = true })
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
        }
        .frame(height: 18)
        .help("Drag sideways to change (⌥ for fine steps). Double-click to type a value.")
    }
}

/// Typed number entry. Enter or clicking elsewhere commits, Escape cancels.
private struct NumberBox: View {
    let field: NodeField
    @Binding var value: Double
    let app: AppState
    let autofocus: Bool
    let onDone: () -> Void
    @State private var text = ""
    @FocusState private var focus: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 10).monospacedDigit())
            .multilineTextAlignment(.trailing)
            .padding(.horizontal, 4)
            .frame(height: 16)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color(white: focus ? 0.24 : 0.19)))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.white.opacity(focus ? 0.4 : 0), lineWidth: 1))
            .focused($focus)
            .onAppear {
                text = Self.show(value)
                if autofocus { DispatchQueue.main.async { focus = true } }
            }
            .onChange(of: value) { _, v in if !focus { text = Self.show(v) } }
            .onChange(of: focus) { _, f in
                // single-key menu shortcuts (S, F, N, Space, digits) are off while typing
                app.textEditing = f
                if !f { commit(); onDone() }
            }
            .onSubmit { focus = false }
            .onExitCommand { text = Self.show(value); focus = false }
    }

    private func commit() {
        let t = text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard let v = Double(t), v.isFinite else { text = Self.show(value); return }
        value = min(field.range.upperBound, max(field.range.lowerBound, v))
        text = Self.show(value)
    }

    private static func show(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 1e9 ? String(format: "%.0f", v) : String(format: "%g", v)
    }
}
