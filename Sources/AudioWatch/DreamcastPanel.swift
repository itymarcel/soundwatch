import SwiftUI

/// Settings → Layers (Dreamcast mode): the stack of up to 10 layers, front-most at the top of the list (the saved
/// array is bottom-first). Each layer folds open into its type, style and transform / music sliders.
struct DreamcastLayersSection: View {
    @Bindable var store: SettingsStore
    @Bindable var app: AppState
    /// Layers shown open (not saved).
    @State private var open: Set<UUID> = []
    @FocusState private var typing: Bool

    private var layers: [DCLayer] { store.v.dcLayers }

    var body: some View {
        FoldSection("Layers", icon: "square.3.layers.3d", open: true) {
            HStack(spacing: 6) {
                Menu {
                    ForEach(DCEra.allCases, id: \.self) { era in
                        Section(era.title) {
                            ForEach(DCKind.allCases.filter { $0.era == era }) { k in
                                Button { add(k) } label: { Label(k.title, systemImage: k.symbol) }
                            }
                        }
                    }
                } label: { Label("Add layer", systemImage: "plus") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(layers.count >= DCScene.maxLayers)
                .help("Adds a layer on top of the stack (at most \(DCScene.maxLayers)).")
                Spacer()
                Menu("Presets") {
                    ForEach(DCScene.all) { sc in
                        Button("\(sc.name)  ·  \(sc.console.title)") {
                            store.v.dcLayers = sc.layers.map { $0.copy() }
                            store.v.dcConsole = sc.console
                            store.v.dcRes = sc.console.lines
                            open = []
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Replaces the layers with a ready-made stack (and switches to its console). To keep your own stacks, save them as presets in the Presets group above.")
            }
            if layers.isEmpty {
                Hint("No layers: add one, or pick one of the presets.")
            }
            Text("\(layers.count) of \(DCScene.maxLayers) · top of the list = front")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            ForEach(Array(layers.enumerated().reversed()), id: \.element.id) { idx, layer in
                card(layer, index: idx)
            }
        }
    }

    // MARK: - One layer

    @ViewBuilder private func card(_ layer: DCLayer, index: Int) -> some View {
        let id = layer.id
        let isOpen = open.contains(id)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Button { set(id) { $0.on.toggle() } } label: {
                    Image(systemName: layer.on ? "eye" : "eye.slash").frame(width: 16)
                }
                .buttonStyle(.borderless)
                .help(layer.on ? "Hide this layer" : "Show this layer")
                Image(systemName: layer.kind.symbol).frame(width: 16).foregroundStyle(.secondary)
                Text(layer.kind.title + (layer.kind.styles.count > 1 ? " · " + layer.kind.styles[min(layer.style, layer.kind.styles.count - 1)] : ""))
                    .lineLimit(1)
                    .opacity(layer.on ? 1 : 0.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { toggleOpen(id) }
                iconButton("chevron.up", "Move towards the front", disabled: index >= layers.count - 1) { move(id, by: 1) }
                iconButton("chevron.down", "Move towards the back", disabled: index == 0) { move(id, by: -1) }
                iconButton("plus.square.on.square", "Duplicate", disabled: layers.count >= DCScene.maxLayers) { duplicate(id) }
                iconButton("trash", "Remove this layer", disabled: false) { remove(id) }
                Button { toggleOpen(id) } label: {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(isOpen ? 90 : 0)).frame(width: 14)
                }
                .buttonStyle(.borderless)
            }
            if isOpen {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Type", selection: Binding(get: { layer.kind }, set: { k in set(id) { $0.kind = k; $0.style = 0 } })) {
                        ForEach(DCEra.allCases, id: \.self) { era in
                            Section(era.title) {
                                ForEach(DCKind.allCases.filter { $0.era == era }) { Text($0.title).tag($0) }
                            }
                        }
                    }
                    .controlSize(.small)
                    .help(layer.kind.help)
                    if layer.kind.styles.count > 1 {
                        Picker("Style", selection: Binding(get: { min(layer.style, layer.kind.styles.count - 1) }, set: { v in set(id) { $0.style = v } })) {
                            ForEach(Array(layer.kind.styles.enumerated()), id: \.offset) { i, name in Text(name).tag(i) }
                        }
                        .controlSize(.small)
                    }
                    if layer.kind == .scroller {
                        TextField("Text", text: Binding(get: { store.v.dcLayers.first { $0.id == id }?.text ?? "" },
                                                        set: { v in set(id) { $0.text = v } }))
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .focused($typing)
                            .help("What scrolls by. Letters, digits and : ' \" - . / ! % * (lowercase is shown as capitals).")
                    }
                    LayerSlider("Speed", value(id, \.speed), 0...4, def: 1, "%.2f×")
                        .help("How fast it moves, scrolls or turns. The music speeds it up on top (Music).")
                    LayerSlider("Music", value(id, \.react), 0...1, def: 0.5, "%.2f")
                        .help("How much the music drives this layer: speed with the loudness and kicks, plus its own reaction. 0 = runs on its own; 1 = crawls in silence and races when it's loud.")
                    LayerSlider("X", value(id, \.x), -1...1, def: 0, "%+.2f")
                    LayerSlider("Y", value(id, \.y), -1...1, def: 0, "%+.2f")
                    LayerSlider("Scale", value(id, \.scale), 0.1...4, def: 1, "%.2f×")
                    LayerSlider("Rotation", value(id, \.rotation), -180...180, def: 0, "%.0f°")
                    LayerSlider("Opacity", value(id, \.opacity), 0...1, def: 1, "%.2f")
                    LayerSlider("Hue", value(id, \.hue), 0...1, def: 0, "%.2f")
                        .help("Turns the layer's colours around the colour wheel (0 = its own colours).")
                }
                .padding(.leading, 20)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        // single-key shortcuts mustn't swallow typing in the scroller's text
        .onChange(of: typing) { _, t in app.textEditing = t }
    }

    private func iconButton(_ symbol: String, _ help: String, disabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 14) }
            .buttonStyle(.borderless)
            .disabled(disabled)
            .help(help)
    }

    // MARK: - Editing

    private func set(_ id: UUID, _ change: (inout DCLayer) -> Void) {
        guard let i = store.v.dcLayers.firstIndex(where: { $0.id == id }) else { return }
        change(&store.v.dcLayers[i])
    }

    private func value(_ id: UUID, _ kp: WritableKeyPath<DCLayer, Double>) -> Binding<Double> {
        Binding(get: { store.v.dcLayers.first { $0.id == id }?[keyPath: kp] ?? 0 },
                set: { v in set(id) { $0[keyPath: kp] = v } })
    }

    private func toggleOpen(_ id: UUID) {
        if open.contains(id) { open.remove(id) } else { open.insert(id) }
    }

    private func add(_ k: DCKind) {
        guard store.v.dcLayers.count < DCScene.maxLayers else { return }
        let l = DCLayer(k)
        store.v.dcLayers.append(l)
        open.insert(l.id)
    }

    private func duplicate(_ id: UUID) {
        guard store.v.dcLayers.count < DCScene.maxLayers, let i = store.v.dcLayers.firstIndex(where: { $0.id == id }) else { return }
        store.v.dcLayers.insert(store.v.dcLayers[i].copy(), at: i + 1)
    }

    private func remove(_ id: UUID) {
        store.v.dcLayers.removeAll { $0.id == id }
        open.remove(id)
    }

    /// +1 = one step towards the front (later in the bottom-first array).
    private func move(_ id: UUID, by d: Int) {
        guard let i = store.v.dcLayers.firstIndex(where: { $0.id == id }) else { return }
        let j = i + d
        guard j >= 0, j < store.v.dcLayers.count else { return }
        store.v.dcLayers.swapAt(i, j)
    }
}

/// A slider row for a layer value; double-click (label or slider) = `def`.
private struct LayerSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let def: Double
    let format: String

    init(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, def: Double, _ format: String) {
        self.title = title; self._value = value; self.range = range; self.def = def; self.format = format
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title).lineLimit(1).frame(width: 52, alignment: .leading)
                .contentShape(Rectangle()).onTapGesture(count: 2) { value = def }
            Slider(value: $value, in: range).labelsHidden()
                .background(DoubleClickReset { value = def })
            Text(String(format: format, value))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }
}
