import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var state: AppState
    @State private var isDropTargeted = false

    var body: some View {
        let sections = state.sections
        ZStack(alignment: .bottom) {
            if state.library.items.isEmpty {
                WelcomeView()
            } else if sections.isEmpty {
                emptyFilter
            } else {
                PhotoGridView(
                    sections: sections,
                    sectionsToken: state.sectionsToken,
                    revision: state.library.revision,
                    itemSize: state.itemSize,
                    scale: state.sidebar == .duplicates ? .all : state.scale,
                    selection: $state.selection,
                    showCloudBadges: state.showCloudBadges,
                    bestIDs: state.bestDuplicateIDs,
                    copyMode: state.sync.storageMode == .copyToMac,
                    scrollTarget: $state.scrollTarget,
                    lookup: { state.library.item($0) },
                    thumbnailURL: { state.library.thumbnailURL(for: $0) },
                    originalURL: { id in state.library.item(id).flatMap(state.library.localURL) },
                    onOpen: { state.open($0) },
                    onDelete: { state.requestDelete($0) },
                    onMagnify: { state.zoom(by: $0) },
                    onVisibleChange: { state.sync.visibleIDs = $0 },
                    collapsed: state.collapsedSections,
                    onToggleSection: { state.toggleSection($0, all: $1) },
                    menu: { GridMenu.make(for: $0, state: state) }
                )
            }

            VStack(spacing: 10) {
                if let toast = state.toast {
                    ToastView(toast: toast)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if !state.selection.isEmpty {
                    SelectionBar()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.bottom, 16)
            .animation(.snappy(duration: 0.25), value: state.selection.isEmpty)

            if let id = state.viewerID {
                ViewerView(id: id)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.smooth(duration: 0.2), value: state.viewerID)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                    .background(Color.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(Label("Drop to import", systemImage: "square.and.arrow.down").font(.title3).foregroundStyle(.tint))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted.animation(.snappy(duration: 0.15))) { providers in
            let group = DispatchGroup()
            let lock = NSLock()
            var urls: [URL] = []
            for provider in providers {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url {
                        lock.lock()
                        urls.append(url)
                        lock.unlock()
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                // Ignore drags that start in our own grid.
                let outside = urls.filter { !$0.path.hasPrefix(state.library.originalsDir.path) }
                if !outside.isEmpty { state.importFiles(outside) }
            }
            return true
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .searchable(text: $state.search, placement: .toolbar, prompt: "Photos, categories, text, people")
        .toolbar { toolbar }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if state.sidebar != .duplicates {
                Picker("Time Scale", selection: $state.scale.animation(.smooth)) {
                    ForEach(TimeScale.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Years ⌘1 · Months ⌘2 · All Photos ⌘3. Pinch to zoom between them.")
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("Uncategorised Photos") { state.categorize(.uncategorized) }
                Button("Selected Photos") { state.categorize(.items(state.selection)) }
                    .disabled(state.selection.isEmpty)
                Button("Everything Again") { state.categorize(.all) }
                Divider()
                Button("Local Model…") { state.showModelSheet = true }
            } label: {
                Label("Categorise", systemImage: "sparkles")
            } primaryAction: {
                state.categorize(state.selection.isEmpty ? .uncategorized : .items(state.selection))
            }
            .help("Categorise with \(LocalModel.displayName), on this Mac (⌘K)")
            .disabled(state.categorizer.isRunning)
            Button {
                state.syncNow()
            } label: {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
            }
            .help("Sync from iPhone (⇧⌘I)")
            .disabled(state.sync.isRunning)

            if state.sidebar == .duplicates {
                DuplicateRangeControl()
                Button {
                    state.selectDuplicates()
                } label: {
                    let count = state.selectableDuplicateCount
                    Label(count > 0 ? "Select \(count) Duplicate\(count == 1 ? "" : "s")" : "Select Duplicates", systemImage: "checkmark.circle")
                        .labelStyle(.titleAndIcon)
                }
                .help("Select every copy except the one to keep, in the groups shown (⌥⌘D)")
                .disabled(state.selectableDuplicateCount == 0)
                Button {
                    state.findDuplicates()
                } label: {
                    Label("Scan Again", systemImage: "arrow.clockwise")
                }
                .help("Scan the library for duplicates again (⇧⌘D)")
            } else {
                ZoomControl()
            }

        }
    }

    private var title: String {
        switch state.sidebar ?? .allPhotos {
        case .allPhotos: return "All Photos"
        case .videos: return "Videos"
        case .onIPhone: return state.device.deviceName ?? "iPhone"
        case .pendingDelete: return "Waiting to Delete"
        case .inCloud: return "In iCloud"
        case .notInCloud: return "Not in iCloud"
        case .duplicates: return "Duplicates"
        case .uncategorized: return "Uncategorised"
        case .category(let name): return name
        case .person(let id): return state.library.person(id)?.name ?? "Person"
        case .album(let name): return name
        }
    }

    private var subtitle: String {
        if state.sidebar == .duplicates {
            let groups = state.sections.count
            return state.analysis.isFindingDuplicates ? "Scanning…" : "\(groups) group\(groups == 1 ? "" : "s")"
        }
        _ = state.sections
        return AppState.countText(photos: state.sectionTotals.photos, videos: state.sectionTotals.videos)
    }

    @ViewBuilder private var emptyFilter: some View {
        if !state.search.isEmpty {
            ContentUnavailableView.search(text: state.search)
        } else {
            switch state.sidebar ?? .allPhotos {
            case .duplicates:
                if state.analysis.isFindingDuplicates {
                    ProgressView("Looking for duplicates…")
                } else {
                    ContentUnavailableView {
                        Label(state.duplicateRange == .allTime ? "No Duplicates" : "No Duplicates in \(state.duplicateRange.title)", systemImage: "square.on.square")
                    } description: {
                        Text("Exact copies and near-identical shots show up here, grouped with the best copy first.")
                    } actions: {
                        if state.duplicateRange != .allTime && !state.analysis.duplicateGroups.isEmpty {
                            Button("Show All Time") { state.duplicateRange = .allTime }
                        }
                        Button("Scan Again") { state.findDuplicates() }
                    }
                }
            case .uncategorized:
                ContentUnavailableView("Everything Is Categorised", systemImage: "checkmark.circle",
                                       description: Text("New photos land here until you categorise them."))
            case .category(let name):
                ContentUnavailableView {
                    Label("No Photos in \(name)", systemImage: "folder")
                } description: {
                    Text("Categorise with the local model, or select photos and move them here.")
                } actions: {
                    Button("Categorise Uncategorised") { state.categorize(.uncategorized) }
                }
            case .onIPhone:
                if state.device.isReady || state.sync.isRunning {
                    ProgressView("Reading \(state.device.deviceName ?? "the iPhone")…")
                } else {
                    ContentUnavailableView("No iPhone Connected", systemImage: "cable.connector",
                                           description: Text("Connect an iPhone with a USB cable, unlock it and tap Trust."))
                }
            case .notInCloud:
                ContentUnavailableView("Everything Is in iCloud", systemImage: "icloud",
                                       description: Text("Every synced item was found in iCloud Photos."))
            default:
                ContentUnavailableView("No Photos", systemImage: "photo.on.rectangle")
            }
        }
    }
}

/// Date range for the Duplicates view: presets plus a custom From–To range.
private struct DuplicateRangeControl: View {
    @EnvironmentObject private var state: AppState
    @State private var showCustom = false
    @State private var from = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
    @State private var to = Date()

    var body: some View {
        Menu {
            Button("All Time") { state.duplicateRange = .allTime }
            Button("Last 30 Days") { state.duplicateRange = .lastDays(30) }
            Button("Last 90 Days") { state.duplicateRange = .lastDays(90) }
            Divider()
            ForEach(years, id: \.self) { year in
                Button(String(year)) { state.duplicateRange = .year(year) }
            }
            Divider()
            Button("Custom Range…") {
                if case .custom(let a, let b) = state.duplicateRange { from = a; to = b }
                showCustom = true
            }
        } label: {
            Label(state.duplicateRange.title, systemImage: "calendar")
                .labelStyle(.titleAndIcon)
        }
        .help("Only show duplicates taken in this period")
        .popover(isPresented: $showCustom, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Duplicates Taken Between").font(.headline)
                DatePicker("From", selection: $from, in: ...Date(), displayedComponents: .date)
                DatePicker("To", selection: $to, in: ...Date(), displayedComponents: .date)
                HStack {
                    Spacer()
                    Button("Cancel") { showCustom = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Apply") {
                        state.duplicateRange = .custom(from: from, to: to)
                        showCustom = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .datePickerStyle(.field)
            .padding(16)
            .frame(width: 280)
        }
    }

    /// Years that have duplicate groups, newest first.
    private var years: [Int] {
        let calendar = Calendar.current
        let set = Set(state.analysis.duplicateGroups.compactMap { $0.first.flatMap(state.library.item) }
            .map { calendar.component(.year, from: $0.captureDate) })
        return set.sorted(by: >)
    }
}

private struct ZoomControl: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 4) {
            Button { state.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                .buttonStyle(.borderless)
                .help("Zoom out (⌘−)")
            Slider(value: Binding(get: { state.itemSize }, set: { state.itemSize = $0 }), in: state.scale.sizeRange)
                .frame(width: 80)
                .controlSize(.small)
            Button { state.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                .buttonStyle(.borderless)
                .help("Zoom in (⌘+)")
        }
    }
}

/// Floating actions for the current selection.
private struct SelectionBar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        let count = state.selection.count
        HStack(spacing: 4) {
            Text("\(count) selected")
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .padding(.horizontal, 8)

            Divider().frame(height: 18)

            Menu {
                ForEach(state.library.categories) { category in
                    Button {
                        state.move(state.selection, to: category.name)
                    } label: {
                        Label(category.name, systemImage: category.symbol)
                    }
                }
                Divider()
                Button("New Category…") { state.newCategoryFor = Array(state.selection) }
                Button("Remove Category") { state.move(state.selection, to: nil) }
            } label: {
                Label("Move to", systemImage: "folder")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Move to a category (⇧⌘M for a new one)")

            barButton("Categorise", "sparkles", help: "Categorise selection (⇧⌘K)") {
                state.categorize(.items(state.selection))
            }
            barButton("Export", "square.and.arrow.down", help: "Save the originals to a folder (⇧⌘E)") {
                state.export(state.selection)
            }
            barButton("Share", "square.and.arrow.up", help: "Share the originals") {
                state.share(state.selection)
            }
            barButton("Delete", "trash", help: "Delete (⌘⌫)", role: .destructive) {
                state.requestDelete(state.selection)
            }

            Divider().frame(height: 18)

            Button {
                state.selection = []
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Deselect (Esc)")
            .padding(.horizontal, 6)
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }

    private func barButton(_ title: String, _ symbol: String, help: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: symbol)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(role == .destructive ? Color.red : Color.primary)
        .padding(.horizontal, 6)
        .help(help)
    }
}

struct ToastView: View {
    let toast: Toast

    var body: some View {
        Label(toast.message, systemImage: toast.symbol)
            .font(.callout)
            .foregroundStyle(toast.isError ? Color.orange : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
    }
}

/// First run: nothing synced yet.
private struct WelcomeView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("Connect Your iPhone")
                .font(.title2.weight(.semibold))
            Text("Plug your iPhone into this Mac with a USB cable, unlock it and tap **Trust**.\nFrameFold browses and organises your photos right on the iPhone — nothing is copied to this Mac unless you choose to.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            HStack(spacing: 6) {
                Button("Import Files…") { state.chooseFilesToImport() }
                switch state.device.status {
                case .ready:
                    Button("Sync Now") { state.syncNow() }
                        .keyboardShortcut(.defaultAction)
                case .connecting, .loadingCatalog:
                    ProgressView().controlSize(.small)
                    Text("Reading your iPhone…").foregroundStyle(.secondary)
                case .locked:
                    Image(systemName: "lock.iphone")
                    Text("Unlock your iPhone and tap Trust").foregroundStyle(.secondary)
                default:
                    Text("Waiting for a device…").foregroundStyle(.tertiary)
                }
            }
            .font(.callout)
            .padding(.top, 4)
            Text("⇧⌘I to sync · ⌘O or drop files to import")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
