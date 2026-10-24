import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var state: AppState
    @State private var renamingCategory: String?
    @State private var categoryText = ""

    var body: some View {
        List(selection: $state.sidebar) {
            Section("Library") {
                row("All Photos", "photo.on.rectangle", .allPhotos)
                row("Videos", "video", .videos)
                row("Uncategorised", "questionmark.folder", .uncategorized)
            }

            Section("Device") {
                DeviceRow()
                    .tag(SidebarItem.onIPhone)
                    .contextMenu {
                        Button("Index New Photos") { state.syncNow() }
                        Button("Reindex iPhone from Scratch") { state.reindexIPhone() }
                    }
                if state.count(.pendingDelete) > 0 {
                    row("Waiting to Delete", "trash", .pendingDelete)
                }
            }

            Section("iCloud") {
                if state.photos.isAuthorized && !state.photos.mirrorsICloud {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("iCloud Status Unknown", systemImage: "icloud.slash")
                        Text("Photos on this Mac isn't syncing with iCloud, so FrameFold can't tell what's in iCloud. Turn on iCloud Photos in Photos › Settings › iCloud.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open Photos") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Photos.app"))
                        }
                        .controlSize(.small)
                    }
                    .padding(.vertical, 2)
                } else if state.photos.isAuthorized {
                    row("In iCloud", "icloud", .inCloud)
                    row("Not in iCloud", "icloud.slash", .notInCloud)
                } else {
                    Button {
                        Task {
                            await state.photos.openSettings()
                            await state.sync.refreshCloudState()
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Allow Photos Access…", systemImage: "icloud.slash")
                            Text("Needed to see what's in iCloud and to delete from it")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 26)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Section {
                ForEach(state.library.categories) { category in
                    row(category.name, category.symbol, .category(category.name))
                        .dropDestination(for: String.self) { strings, _ in
                            let ids = GridDrag.ids(from: strings)
                            guard !ids.isEmpty else { return false }
                            state.move(ids, to: category.name)
                            return true
                        }
                        .contextMenu {
                            Button("Rename…") {
                                categoryText = category.name
                                renamingCategory = category.name
                            }
                            Button("Delete Category", role: .destructive) {
                                if state.sidebar == .category(category.name) { state.sidebar = .allPhotos }
                                state.library.deleteCategory(category.name)
                            }
                        }
                }
            } header: {
                HStack {
                    Text("Categories")
                    Spacer()
                    Button {
                        state.categorize(.uncategorized)
                    } label: {
                        Image(systemName: "sparkles")
                    }
                    .buttonStyle(.borderless)
                    .help("Categorise uncategorised photos with \(LocalModel.displayName) (⌘K)")
                    .disabled(state.categorizer.isRunning)
                    Button {
                        state.newCategoryFor = []
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("New category")
                }
            }

            if !state.visiblePeople.isEmpty {
                Section("People") {
                    ForEach(state.visiblePeople) { person in
                        PersonRow(person: person, count: state.count(.person(person.id)))
                            .tag(SidebarItem.person(person.id))
                            .contextMenu {
                                Button("Rename…") { state.renamingPerson = person }
                                Menu("Merge Into") {
                                    ForEach(state.visiblePeople.filter { $0.id != person.id }) { other in
                                        Button(other.name) {
                                            state.library.mergePerson(person.id, into: other.id)
                                            state.sidebar = .person(other.id)
                                        }
                                    }
                                }
                                Button("Hide") {
                                    state.library.updatePerson(person.id) { $0.isHidden = true }
                                }
                            }
                    }
                }
            }

            if !state.albumNames.isEmpty {
                Section("Photos Albums") {
                    ForEach(state.albumNames, id: \.self) { album in
                        row(album, "rectangle.stack", .album(album))
                    }
                }
            }

            Section("Utilities") {
                row("Duplicates", "square.on.square", .duplicates)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { ActivityFooter() }
        .onChange(of: state.sidebar) { _, value in
            if value == .duplicates, state.analysis.duplicateGroups.isEmpty, !state.analysis.isFindingDuplicates {
                Task { await state.analysis.findDuplicates() }
            }
        }
        .alert("Rename Category", isPresented: Binding(get: { renamingCategory != nil }, set: { if !$0 { renamingCategory = nil } })) {
            TextField("Name", text: $categoryText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let old = renamingCategory {
                    state.library.renameCategory(old, to: categoryText)
                    if state.sidebar == .category(old) { state.sidebar = .category(categoryText) }
                }
            }
        }
    }

    private func row(_ title: String, _ symbol: String, _ item: SidebarItem) -> some View {
        Label(title, systemImage: symbol)
            .badge(state.count(item))
            .tag(item)
    }
}

private struct PersonRow: View {
    private static let avatars = NSCache<NSURL, NSImage>()

    /// Avatars are read from disk once, not on every redraw.
    private static func avatar(_ url: URL) -> NSImage? {
        if let cached = avatars.object(forKey: url as NSURL) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        avatars.setObject(image, forKey: url as NSURL)
        return image
    }

    @EnvironmentObject private var state: AppState
    let person: Person
    let count: Int

    var body: some View {
        Label {
            Text(person.name)
        } icon: {
            avatar
        }
        .badge(count)
    }

    @ViewBuilder private var avatar: some View {
        if let path = person.avatarPath, let image = Self.avatar(state.library.facesDir.appendingPathComponent(path)) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 18, height: 18)
                .clipShape(Circle())
        } else {
            Image(systemName: "person.crop.circle")
        }
    }
}

/// Connection state of the iPhone and sync progress.
private struct DeviceRow: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let progress = syncProgress {
                    ProgressView(value: progress)
                        .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
            if state.device.isReady {
                Button {
                    state.sync.isRunning ? state.sync.cancel() : state.sync.start()
                } label: {
                    Image(systemName: state.sync.isRunning ? "stop.circle" : "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)
                .help(state.sync.isRunning ? "Stop syncing" : "Sync now (⇧⌘I)")
            }
        }
        .padding(.vertical, 2)
    }

    private var syncProgress: Double? {
        switch state.sync.phase {
        case .indexing(let done, let total), .copying(let done, let total): return Double(done) / Double(max(total, 1))
        default: return nil
        }
    }

    private var icon: String {
        switch state.device.status {
        case .ready, .loadingCatalog: return "iphone"
        case .locked: return "lock.iphone"
        case .failed: return "exclamationmark.triangle"
        default: return "cable.connector"
        }
    }

    private var iconColor: Color {
        switch state.device.status {
        case .ready: return .accentColor
        case .failed, .locked: return .orange
        default: return .secondary
        }
    }

    private var title: String {
        switch state.device.status {
        case .idle: return state.stats.hasDeviceItems ? "iPhone Not Connected" : "No iPhone Connected"
        case .connecting(let name), .locked(let name), .loadingCatalog(let name, _), .ready(let name): return name
        case .failed: return "Connection Problem"
        }
    }

    private var detail: String {
        switch state.device.status {
        case .idle:
            return state.stats.hasDeviceItems
                ? "Browsing saved thumbnails. Connect to open originals."
                : "Connect with a USB cable"
        case .connecting: return "Connecting…"
        case .locked: return "Unlock the iPhone and tap Trust"
        case .loadingCatalog(_, let percent): return "Reading library… \(percent)%"
        case .failed(let message): return message
        case .ready:
            switch state.sync.phase {
            case .preparing: return "Reading library…"
            case .indexing(let done, let total): return "Indexing \(done + 1) of \(total)"
            case .copying(let done, let total): return "Copying \(done + 1) of \(total) to this Mac"
            case .matchingCloud: return "Checking iCloud…"
            default:
                let onDevice = state.count(.onIPhone)
                return state.sync.storageMode == .browseOnly ? "\(onDevice) items · browsing on iPhone" : "\(onDevice) items · copied to this Mac"
            }
        }
    }
}

/// Background work at the bottom of the sidebar.
private struct ActivityFooter: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let progress = state.device.deleteProgress {
                activity("Deleting from \(state.device.deviceName ?? "iPhone")", done: Int(progress * 100), total: 100, cancel: nil)
            } else if !state.deletingIDs.isEmpty {
                activity("Deleting \(state.deletingIDs.count) item\(state.deletingIDs.count == 1 ? "" : "s")", done: 0, total: 0, cancel: nil)
            }
            if state.categorizer.isRunning {
                activity("Categorising \(state.categorizer.done) of \(state.categorizer.total)\(Self.eta(state.categorizer.remaining))", done: state.categorizer.done, total: state.categorizer.total) {
                    state.categorizer.cancel()
                }
            }
            if state.analysis.isAnalyzing {
                activity("Analysing on this Mac", done: state.analysis.analyzed, total: state.analysis.total, cancel: nil)
            }
            if case .pullingModel(_, let completed, let total) = state.model.state {
                activity("Downloading \(LocalModel.displayName)", done: Int(completed / 1_000_000), total: Int(total / 1_000_000)) {
                    state.showModelSheet = true
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, hasActivity ? 10 : 0)
        .animation(.smooth, value: hasActivity)
    }

    static func eta(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite else { return "" }
        if seconds < 60 { return " · under a minute left" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .abbreviated
        return " · about \(formatter.string(from: seconds) ?? "") left"
    }

    private var hasActivity: Bool {
        !state.deletingIDs.isEmpty || state.categorizer.isRunning || state.analysis.isAnalyzing || { if case .pullingModel = state.model.state { return true } else { return false } }()
    }

    private func activity(_ title: String, done: Int, total: Int, cancel: (() -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let cancel {
                    Button(action: cancel) { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.tertiary)
                }
            }
            if total > 0 {
                ProgressView(value: Double(done), total: Double(total))
                    .controlSize(.small)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            }
        }
    }
}
