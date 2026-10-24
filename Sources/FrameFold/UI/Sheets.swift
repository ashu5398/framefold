import SwiftUI

/// Asks where to delete from: the iPhone, the iPhone and iCloud, or only FrameFold.
struct DeleteSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let ids: [String]
    @State private var mode: DeleteMode = .iPhoneOnly

    var body: some View {
        let items = ids.compactMap(state.library.item)
        let inCloud = items.filter { $0.photosAssetID != nil }.count
        let offline = items.filter { $0.isFromDevice && state.sync.deviceFiles[$0.id] == nil }.count
        let noun = items.count == 1 ? "item" : "items"

        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "trash")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.red)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Delete \(items.count) \(noun)?")
                        .font(.headline)
                    Text(summary(items: items, inCloud: inCloud, offline: offline))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 8) {
                option(.iPhoneOnly,
                       title: "Delete from iPhone only",
                       detail: phoneDetail(offline: offline),
                       symbol: "iphone")
                option(.iPhoneAndCloud,
                       title: "Delete from iPhone and iCloud",
                       detail: cloudDetail(inCloud: inCloud),
                       symbol: "icloud")
                    .disabled(!state.photos.isAuthorized || !state.photos.mirrorsICloud)
                option(.frameFoldOnly,
                       title: "Remove from FrameFold only",
                       detail: "Nothing is deleted from your iPhone or iCloud. FrameFold forgets these and won't show them again.",
                       symbol: "eye.slash")
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    state.performDelete(ids, mode: mode)
                } label: {
                    Text(buttonTitle)
                }
                .keyboardShortcut(.defaultAction)
                .tint(.red)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var buttonTitle: String {
        switch mode {
        case .iPhoneOnly: return "Delete from iPhone"
        case .iPhoneAndCloud: return "Delete Everywhere"
        case .frameFoldOnly: return "Remove"
        }
    }

    private func summary(items: [PhotoItem], inCloud: Int, offline: Int) -> String {
        var parts: [String] = []
        if inCloud > 0 { parts.append("\(inCloud) in iCloud Photos") }
        let notInCloud = items.count - inCloud
        if notInCloud > 0 { parts.append("\(notInCloud) not in iCloud") }
        if offline > 0 { parts.append("\(offline) on an iPhone that isn't connected") }
        let editedOnly = items.filter(\.editedOnPhoneOnly).count
        var text = parts.joined(separator: " · ")
        if editedOnly > 0 {
            text += "\n\(editedOnly) \(editedOnly == 1 ? "was" : "were") edited on the iPhone; their edited version isn't reachable over USB, so they'll be skipped. Delete those in the Photos app."
        }
        return text
    }

    private func phoneDetail(offline: Int) -> String {
        var text = "Deletes from the iPhone's storage over USB. iCloud keeps its copy, but if this iPhone uses iCloud Photos it usually refuses USB deletes — then use the next option."
        if offline > 0 { text += " Items on a disconnected iPhone are deleted the next time it connects." }
        return text
    }

    private func cloudDetail(inCloud: Int) -> String {
        guard state.photos.isAuthorized else {
            return "Needs access to Photos to reach iCloud. Allow it in System Settings › Privacy & Security › Photos."
        }
        guard state.photos.mirrorsICloud else {
            return "Unavailable: Photos on this Mac isn't syncing with iCloud, so FrameFold can't reach iCloud. Turn on iCloud Photos in Photos › Settings › iCloud."
        }
        return "Deletes from iCloud Photos, which removes them from the iPhone and all your devices. They stay in Recently Deleted for 30 days. Items not in iCloud are deleted from the iPhone directly."
    }

    private func option(_ value: DeleteMode, title: String, detail: String, symbol: String) -> some View {
        Button {
            mode = value
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: mode == value ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(mode == value ? Color.accentColor : Color.secondary)
                    .font(.system(size: 14))
                VStack(alignment: .leading, spacing: 3) {
                    Label(title, systemImage: symbol).font(.body.weight(.medium))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(mode == value ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(mode == value ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Install and manage the local model. Everything is downloaded once and runs on this Mac.
struct ModelSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let service = state.model
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Categorise on This Mac").font(.headline)
                    Text("FrameFold sorts photos with a small open model that runs entirely on this Mac. Photos never leave it, and nothing is sent to any server.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(LocalModel.displayName).font(.body.weight(.medium))
                    Text(LocalModel.name).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: LocalModel.approximateBytes, countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(LocalModel.summary).font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

            InstallLocations()

            status

            if !service.log.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(service.log.suffix(60).joined(separator: "\n"))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id("log")
                    }
                    .frame(height: 80)
                    .padding(8)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    .onChange(of: service.log.count) { proxy.scrollTo("log", anchor: .bottom) }
                }
            }

            HStack {
                if service.isReady {
                    Button("Remove Model", role: .destructive) { Task { await service.removeModel() } }
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                primaryButton
            }
        }
        .padding(20)
        .frame(width: 520)
        .task {
            await service.refresh()
            // Opened from Categorise: set everything up without another click.
            if state.installModelWhenShown, !service.isReady, !service.isBusy {
                state.installModelWhenShown = false
                service.install()
            }
        }
    }

    @ViewBuilder private var status: some View {
        let service = state.model
        switch service.state {
        case .checking:
            HStack { ProgressView().controlSize(.small); Text("Checking…").foregroundStyle(.secondary) }
        case .runtimeMissing:
            Label("Install sets up the Ollaya runtime and downloads \(LocalModel.displayName), about 3 GB, once. No admin password needed.", systemImage: "arrow.down.circle")
                .font(.callout).foregroundStyle(.secondary)
        case .installingRuntime:
            HStack { ProgressView().controlSize(.small); Text("Installing the Ollaya runtime…") }
        case .modelMissing:
            Label("The runtime is installed. \(LocalModel.displayName) needs a one-time download.", systemImage: "arrow.down.circle")
                .font(.callout).foregroundStyle(.secondary)
        case .pullingModel(let status, let completed, let total):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(completed), total: Double(max(total, 1)))
                Text("\(status) · \(ByteCountFormatter.string(fromByteCount: completed, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .ready:
            Label("Ready. The model starts when you categorise and unloads afterwards.", systemImage: "checkmark.circle.fill")
                .font(.callout).foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(.orange)
        }
    }

    @ViewBuilder private var primaryButton: some View {
        let service = state.model
        switch service.state {
        case .installingRuntime, .pullingModel:
            Button("Cancel Download") { service.cancelInstall() }
        case .ready:
            Button("Categorise Uncategorised") {
                dismiss()
                state.categorize(.uncategorized)
            }
            .keyboardShortcut(.defaultAction)
        case .checking:
            Button("Install") {}.disabled(true)
        case .failed:
            Button("Try Again") { service.install() }
                .keyboardShortcut(.defaultAction)
        default:
            Button(service.binaryURL == nil ? "Install" : "Download Model") { service.install() }
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// Where the local model's pieces live on disk, with buttons to show them in Finder.
struct InstallLocations: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        let service = state.model
        VStack(alignment: .leading, spacing: 6) {
            Text("Installed On This Mac").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            row("Runtime", service.binaryURL?.deletingLastPathComponent().deletingLastPathComponent() ?? service.installPrefix)
            row("Model files", service.modelStore)
            if FaceRecognizer.shared.isAvailable, let face = Bundle.main.url(forResource: "AuraFace", withExtension: "mlpackage") {
                row("Face model", face)
            }
            row("Your library", state.library.root)
        }
    }

    /// The path as shown, with the home folder abbreviated to `~`.
    static func display(_ url: URL) -> String {
        var path = url.path
        #if DEBUG
        // Screenshot mode: show where a normal install keeps things, not the scratch folders.
        if DebugSnapshot.isDemo {
            if let bundle = Bundle.main.bundlePath as String?, path.hasPrefix(bundle) {
                path = "/Applications/FrameFold.app" + path.dropFirst(bundle.count)
            }
            if path == LibraryStore.defaultRoot.path {
                path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/FrameFold Library").path
            }
        }
        #endif
        return path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    private func row(_ title: String, _ url: URL) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).frame(width: 82, alignment: .leading).foregroundStyle(.secondary)
            Text(Self.display(url))
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            Button {
                let target = FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
                NSWorkspace.shared.activateFileViewerSelecting([target])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
        }
        .font(.callout)
    }
}

struct ShortcutsView: View {
    @Environment(\.dismiss) private var dismiss

    private let groups: [(String, [(String, String)])] = [
        ("Library", [("Index iPhone", "⇧⌘I"), ("Export originals", "⇧⌘E"), ("Years · Months · All Photos", "⌘1 ⌘2 ⌘3"), ("Zoom in / out", "⌘+ ⌘− or pinch"), ("Collapse / expand all", "⌥⌘← ⌥⌘→"), ("Search", "⌘F"), ("Show iCloud badges", "⌥⌘B")]),
        ("Selection", [("Toggle an item", "⌘-click or ⌃-click"), ("Select a range", "⇧-click"), ("Select all", "⌘A"), ("Deselect", "Esc or ⇧⌘A"), ("Context menu", "Right-click")]),
        ("Actions", [("Open / Quick view", "Space or double-click"), ("Delete", "⌘⌫ or ⌫"), ("Categorise uncategorised", "⌘K"), ("Categorise selection", "⇧⌘K"), ("New category from selection", "⇧⌘M"), ("Reveal in Finder", "⇧⌘R")]),
        ("Duplicates", [("Find duplicates", "⇧⌘D"), ("Select duplicates", "⌥⌘D")]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Keyboard Shortcuts").font(.title3.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 32, verticalSpacing: 18) {
                GridRow(alignment: .top) {
                    section(groups[0]); section(groups[1])
                }
                GridRow(alignment: .top) {
                    section(groups[2]); section(groups[3])
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 640)
    }

    private func section(_ group: (String, [(String, String)])) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(group.0).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            ForEach(group.1, id: \.0) { row in
                HStack {
                    Text(row.0)
                    Spacer(minLength: 12)
                    Text(row.1)
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 280)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var cacheBytes: Int64 = 0
    @State private var confirmRemoveCopies = false
    @State private var confirmReset = false

    var body: some View {
        TabView {
            Form {
                Section {
                    Picker("Storage", selection: Binding(get: { state.sync.storageMode }, set: { state.sync.storageMode = $0 })) {
                        Text("Browse on iPhone").tag(StorageMode.browseOnly)
                        Text("Keep a copy on this Mac").tag(StorageMode.copyToMac)
                    }
                    .pickerStyle(.radioGroup)
                    LabeledContent("Originals cache") {
                        HStack {
                            Text(ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file)).foregroundStyle(.secondary)
                            Button("Clear") {
                                state.library.clearCache()
                                cacheBytes = state.library.cacheSize()
                            }
                        }
                    }
                    .onAppear { cacheBytes = state.library.cacheSize() }
                    let copies = state.library.redundantCopies
                    if state.sync.storageMode == .browseOnly && copies.count > 0 {
                        LabeledContent("Copies on this Mac") {
                            HStack {
                                Text("\(copies.count) · \(ByteCountFormatter.string(fromByteCount: copies.bytes, countStyle: .file))")
                                    .foregroundStyle(.secondary)
                                Button("Remove Copies…") { confirmRemoveCopies = true }
                            }
                        }
                        .confirmationDialog("Remove \(copies.count) copies from this Mac?", isPresented: $confirmRemoveCopies) {
                            Button("Remove Copies", role: .destructive) { state.library.removeRedundantCopies() }
                        } message: {
                            Text("These photos stay on your iPhone. FrameFold keeps their thumbnails, categories and people, and reads originals from the iPhone when needed.")
                        }
                    }
                } header: {
                    Text("iPhone Photos")
                } footer: {
                    Text(state.sync.storageMode == .browseOnly
                         ? "Only thumbnails and organisation data are kept on this Mac. Originals are read from the iPhone when you open, share or export them, and recently used ones are cached (up to 3 GB)."
                         : "Every original is also copied into the FrameFold library on this Mac.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    LabeledContent("Reset") {
                        Button("Reset Library…", role: .destructive) { confirmReset = true }
                    }
                    .confirmationDialog("Reset the FrameFold library?", isPresented: $confirmReset) {
                        Button("Reset Library", role: .destructive) { state.resetLibrary() }
                    } message: {
                        Text("Deletes FrameFold's thumbnails, categories, people, any copies on this Mac and the cache. Nothing on your iPhone or in iCloud is touched. A connected iPhone is indexed again.")
                    }
                } header: {
                    Text("Library")
                }
                Section("Sync") {
                    Toggle("Index automatically when an iPhone connects", isOn: Binding(get: { state.sync.autoSync }, set: { state.sync.autoSync = $0 }))
                    LabeledContent("Library") {
                        HStack {
                            Text(state.library.root.path).truncationMode(.middle).lineLimit(1).foregroundStyle(.secondary)
                            Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([state.library.root]) }
                        }
                    }
                }
                Section {
                    LabeledContent("Photos access") {
                        if state.photos.isAuthorized {
                            Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button("Allow…") {
                                Task {
                                    await state.photos.requestAccess()
                                    if !state.photos.isAuthorized {
                                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
                                    }
                                    await state.sync.refreshCloudState()
                                }
                            }
                        }
                    }
                    Toggle("Show iCloud badges on thumbnails", isOn: $state.showCloudBadges)
                    Button("Check iCloud Status Again") { Task { await state.sync.refreshCloudState() } }
                        .disabled(!state.photos.isAuthorized)
                } header: {
                    Text("iCloud")
                } footer: {
                    Text("FrameFold reads the Photos library on this Mac. With iCloud Photos turned on in Photos › Settings, that library mirrors iCloud, so a match means the item is in iCloud.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Section("Local Model") {
                    LabeledContent(LocalModel.displayName) {
                        Button("Manage…") { state.showModelSheet = true }
                    }
                    Text(LocalModel.summary).font(.caption).foregroundStyle(.secondary)
                    InstallLocations()
                }
                Section("Similarity") {
                    LabeledContent("Duplicates") {
                        Slider(value: Binding(get: { state.analysis.duplicateThreshold }, set: { state.analysis.duplicateThreshold = $0 }), in: 0.1...0.6) {
                            EmptyView()
                        } minimumValueLabel: { Text("Strict") } maximumValueLabel: { Text("Loose") }
                    }
                    LabeledContent("Faces") {
                        Slider(value: Binding(get: { state.analysis.faceSimilarity }, set: { state.analysis.faceSimilarity = $0 }), in: 0.25...0.65) {
                            EmptyView()
                        } minimumValueLabel: { Text("Group more") } maximumValueLabel: { Text("Split more") }
                    }
                    Button("Regroup People") { state.analysis.clusterPeople(force: true) }
                        .disabled(state.analysis.isGroupingPeople)
                    if !FaceRecognizer.shared.isAvailable {
                        Text("The face model isn't bundled in this build. Run scripts/make-face-model.sh, then rebuild.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Section("Categories") {
                    ForEach(state.library.categories) { category in
                        LabeledContent {
                            Text(category.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        } label: {
                            Label(category.name, systemImage: category.symbol)
                        }
                    }
                    Text("The local model chooses from the first \(LocalModel.maxOptions) categories. Add one from the sidebar's + button.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Organising", systemImage: "sparkles") }
        }
        .frame(width: 560, height: 520)
    }
}
