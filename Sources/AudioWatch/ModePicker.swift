import AppKit
import SwiftUI

/// The mode previews (`Resources/modes/<raw value>.jpg`, made by `Resources/make_mode_previews.sh`, copied into the
/// app's Resources/modes by build.sh), loaded once each.
enum ModePreview {
    private static var cache: [VizMode: NSImage] = [:]
    static func image(_ m: VizMode) -> NSImage? {
        if let i = cache[m] { return i }
        guard let url = Bundle.main.url(forResource: m.rawValue, withExtension: "jpg", subdirectory: "modes"),
              let i = NSImage(contentsOf: url) else { return nil }
        cache[m] = i
        return i
    }
}

/// The mode menu: a select showing the current mode's preview and name; clicking it opens a light gallery of every
/// mode (thumbnails in three columns, or a list), with a search field. Picking one closes it.
struct ModePicker: View {
    @Binding var mode: VizMode
    @Bindable var app: AppState
    @State private var open = false
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            Text("Mode")
            Spacer(minLength: 4)
            Button { open.toggle() } label: {
                HStack(spacing: 7) {
                    ModeThumb(mode: mode, corner: 3)
                        .frame(width: 28, height: 21)
                    Text(mode.title).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 3).padding(.trailing, 7).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovered || open ? 0.1 : 0.06)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .popover(isPresented: $open, arrowEdge: .bottom) {
                ModeGallery(mode: $mode) { open = false }
            }
            .help("Choose what the music is drawn as")
        }
        .onChange(of: open) { _, o in app.textEditing = o }    // typing in the search field mustn't trigger shortcuts
    }
}

/// A preview image, or the mode's symbol on a dark tile when there is none.
struct ModeThumb: View {
    let mode: VizMode
    var corner: CGFloat = 8

    var body: some View {
        ZStack {
            Color(white: 0.08)
            if let img = ModePreview.image(mode) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: mode.symbol).font(.system(size: 18)).foregroundStyle(.white.opacity(0.6))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

struct ModeGallery: View {
    @Binding var mode: VizMode
    var close: () -> Void
    @State private var search = ""
    @AppStorage("AudioViz.modePickerList") private var listView = false
    @FocusState private var searchFocused: Bool

    private func matches(_ m: VizMode) -> Bool {
        search.isEmpty || m.title.localizedCaseInsensitiveContains(search) || m.rawValue.localizedCaseInsensitiveContains(search)
    }
    private var groups: [(String?, [VizMode])] {
        [(nil, VizMode.stable.filter(matches)), ("Experimental", VizMode.experimental.filter(matches))].filter { !$0.1.isEmpty }
    }
    private func pick(_ m: VizMode) { mode = m; close() }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search", text: $search)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onSubmit { if let first = groups.first?.1.first { pick(first) } }
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                            .buttonStyle(.plain)
                    }
                }
                .font(.system(size: 13))
                .padding(.horizontal, 9).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.75)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.black.opacity(0.08)))

                Picker("", selection: $listView) {
                    Text("Thumbs").tag(false)
                    Text("List").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            }
            .padding(.horizontal, 14)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(groups, id: \.0) { title, modes in
                            if let title {
                                Text(title.uppercased())
                                    .font(.system(size: 10, weight: .semibold)).tracking(0.6)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 2).padding(.top, 2)
                            }
                            if listView {
                                VStack(spacing: 2) {
                                    ForEach(modes) { m in ModeRow(mode: m, selected: m == mode) { pick(m) }.id(m) }
                                }
                            } else {
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3),
                                          spacing: 12) {
                                    ForEach(modes) { m in ModeTile(mode: m, selected: m == mode) { pick(m) }.id(m) }
                                }
                            }
                        }
                        if groups.isEmpty {
                            Text("No mode called “\(search)”").foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(.top, 30)
                        }
                    }
                    .padding(.horizontal, 14).padding(.bottom, 14)
                }
                .onAppear { proxy.scrollTo(mode, anchor: .center) }
            }
        }
        .padding(.top, 14)
        .frame(width: 470, height: 560)
        .background(Color(white: 0.9))
        .environment(\.colorScheme, .light)
        .preferredColorScheme(.light)
        .onAppear { searchFocused = true }
    }
}

/// A thumbnail in a soft frame, the name below (like a media library).
private struct ModeTile: View {
    let mode: VizMode
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ModeThumb(mode: mode, corner: 8)
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(hovered || selected ? 0.95 : 0.55)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : Color.black.opacity(0.08), lineWidth: selected ? 2 : 1))
                    .shadow(color: .black.opacity(hovered ? 0.12 : 0), radius: 6, y: 2)
                Text(mode.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(Color.black.opacity(0.85))
                    .lineLimit(1)
                    .padding(.leading, 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovered = h } }
    }
}

private struct ModeRow: View {
    let mode: VizMode
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ModeThumb(mode: mode, corner: 5).frame(width: 48, height: 36)
                Text(mode.title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(Color.black.opacity(0.85))
                Spacer()
                if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accentColor) }
            }
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.95 : hovered ? 0.6 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
