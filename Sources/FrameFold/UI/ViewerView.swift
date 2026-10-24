import AVKit
import SwiftUI

/// Full-size view of one item, over the grid so the user keeps their place.
struct ViewerView: View {
    @EnvironmentObject private var state: AppState
    let id: String
    @State private var image: NSImage?
    @State private var player: AVPlayer?
    @State private var isFetching = false
    @State private var notice: String?
    @State private var showInfo = UserDefaults.standard.bool(forKey: "viewerInfo")
    @FocusState private var focused: Bool

    var body: some View {
        let item = state.library.item(id)
        HStack(spacing: 0) {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                media(item)
                    .padding(24)
                if isFetching || notice != nil {
                    VStack {
                        Spacer()
                        HStack(spacing: 8) {
                            if isFetching { ProgressView().controlSize(.small) }
                            Text(isFetching ? "Loading the original from the iPhone…" : notice ?? "")
                        }
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 72)
                    }
                    .allowsHitTesting(false)
                }
                VStack {
                    HStack {
                        circleButton("xmark", help: "Close (Esc)") { close() }
                        Spacer()
                        circleButton("info", help: "Info (⌘I)") {
                            showInfo.toggle()
                            UserDefaults.standard.set(showInfo, forKey: "viewerInfo")
                        }
                    }
                    Spacer()
                    HStack {
                        circleButton("chevron.left", help: "Previous (←)") { step(-1) }
                        Spacer()
                        circleButton("chevron.right", help: "Next (→)") { step(1) }
                    }
                    Spacer()
                    if let item { actionBar(item) }
                }
                .padding(16)
            }
            if showInfo, let item {
                Divider()
                InfoPanel(item: item)
                    .frame(width: 260)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.smooth(duration: 0.25), value: showInfo)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.escape) { close(); return .handled }
        .onKeyPress(.space) { close(); return .handled }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .task(id: id) { await load(item) }
        .onDisappear { player?.pause() }
    }

    @ViewBuilder private func media(_ item: PhotoItem?) -> some View {
        if let player {
            PlayerView(player: player)
        } else if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        } else {
            ProgressView()
        }
    }

    private func actionBar(_ item: PhotoItem) -> some View {
        HStack(spacing: 2) {
            Menu {
                ForEach(state.library.categories) { category in
                    Button(category.name) { state.move([item.id], to: category.name) }
                }
            } label: {
                Image(systemName: "folder")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Move to category")
            .padding(.horizontal, 6)
            Button { state.share([item.id]) } label: { Image(systemName: "square.and.arrow.up") }
                .buttonStyle(.borderless)
                .help("Share")
                .padding(.horizontal, 6)
            Button { state.export([item.id]) } label: { Image(systemName: "square.and.arrow.down") }
                .buttonStyle(.borderless)
                .help("Export original (⇧⌘E)")
                .padding(.horizontal, 6)
            Button { state.requestDelete([item.id]) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Delete (⌘⌫)")
                .padding(.horizontal, 6)
        }
        .font(.system(size: 14))
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
    }

    private func circleButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.separator, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func load(_ item: PhotoItem?) async {
        player?.pause()
        player = nil
        notice = nil
        guard let item else { return }
        // Show the thumbnail straight away, then swap in the original.
        image = NSImage(contentsOf: state.library.thumbnailURL(for: item.id))
        let needsPhone = state.library.localURL(for: item) == nil
        isFetching = needsPhone && item.onDevice
        defer { isFetching = false }
        guard let url = try? await state.sync.fetchOriginal(item.id) else {
            if !Task.isCancelled {
                notice = item.isFromDevice ? "Connect \(item.deviceName ?? "the iPhone") to see the original" : "The original is missing"
            }
            return
        }
        guard !Task.isCancelled else { return }
        if item.isVideo {
            player = AVPlayer(url: url)
            player?.play()
        } else if let cg = await MediaTools.cgImage(for: url, maxPixel: 3000), !Task.isCancelled {
            image = NSImage(cgImage: cg, size: .zero)
        }
    }

    private func step(_ delta: Int) {
        let ids = state.visibleItems.map(\.id)
        guard let index = ids.firstIndex(of: id) else { return }
        let next = index + delta
        if ids.indices.contains(next) {
            state.viewerID = ids[next]
            state.selection = [ids[next]]
        }
    }

    private func close() {
        state.selection = [id]
        state.viewerID = nil
    }
}

private struct InfoPanel: View {
    @EnvironmentObject private var state: AppState
    let item: PhotoItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.captureDate.formatted(date: .complete, time: .omitted))
                        .font(.headline)
                    Text(item.captureDate.formatted(date: .omitted, time: .shortened))
                        .foregroundStyle(.secondary)
                }
                group("File") {
                    row("Name", item.fileName)
                    if item.pixelWidth > 0 { row("Size", "\(item.pixelWidth) × \(item.pixelHeight)") }
                    row("Bytes", ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))
                    if let duration = item.duration { row("Length", Duration.seconds(duration).formatted(.time(pattern: .minuteSecond))) }
                }
                group("Where It Is") {
                    if item.isFromDevice {
                        status(item.onDevice, item.onDevice ? "On \(item.deviceName ?? "iPhone"), connected" : "On \(item.deviceName ?? "iPhone"), not connected", "iphone")
                    }
                    status(item.isCopied, item.isCopied ? "Copy on this Mac" : "Not copied to this Mac", "laptopcomputer")
                    if item.editedOnPhoneOnly {
                        status(true, "Edited on iPhone: delete it in the Photos app", "pencil.slash")
                    }
                    if item.pendingDeviceDelete {
                        HStack {
                            status(true, "Deletes when the iPhone connects", "trash")
                            Spacer()
                            Button("Keep") { state.cancelPendingDelete([item.id]) }
                                .controlSize(.small)
                        }
                    }
                    switch item.cloud {
                    case .inCloud: status(true, "In iCloud Photos", "icloud")
                    case .notInCloud: status(false, "Not in iCloud Photos", "icloud.slash")
                    case .unknown: status(false, "iCloud status unknown", "icloud")
                    }
                }
                group("Category") {
                    if let category = item.category {
                        HStack {
                            Label(category, systemImage: PhotoCategory.symbol(for: category, in: state.library.categories))
                            Spacer()
                            Text(sourceText).font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Not categorised").foregroundStyle(.secondary)
                    }
                }
                if !item.personIDs.isEmpty {
                    group("People") {
                        ForEach(item.personIDs.compactMap(state.library.person)) { person in
                            Label(person.name, systemImage: "person.crop.circle")
                        }
                    }
                }
                if !item.albums.isEmpty {
                    group("Photos Albums") {
                        ForEach(item.albums, id: \.self) { Label($0, systemImage: "rectangle.stack") }
                    }
                }
                if !item.labels.isEmpty {
                    group("Seen in the Photo") {
                        Text(item.labels.joined(separator: ", ")).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background.secondary)
    }

    private var sourceText: String {
        switch item.categorySource {
        case .model:
            let confidence = item.categoryConfidence.map { " · \(Int($0 * 100))%" } ?? ""
            return "Local model\(confidence)"
        case .photos: return "Photos album"
        case .manual: return "Set by you"
        case nil: return ""
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            content()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }

    private func status(_ on: Bool, _ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .foregroundStyle(on ? Color.primary : Color.secondary)
    }
}

/// AppKit's player view. SwiftUI's `VideoPlayer` is avoided on purpose: built against the macOS
/// 15 SDK it crashes on macOS 26 while instantiating its type metadata.
private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
