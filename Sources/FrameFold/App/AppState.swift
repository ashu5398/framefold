import AppKit
import Combine
import SwiftUI

enum SidebarItem: Hashable {
    case allPhotos
    case videos
    case onIPhone
    case pendingDelete
    case inCloud
    case notInCloud
    case duplicates
    case uncategorized
    case category(String)
    case person(String)
    case album(String)
}

enum TimeScale: String, CaseIterable, Identifiable {
    case years = "Years"
    case months = "Months"
    case all = "All Photos"
    var id: String { rawValue }

    /// Thumbnail edge length range for the zoom slider.
    var sizeRange: ClosedRange<Double> {
        switch self {
        case .years: return 36...110
        case .months: return 80...260
        case .all: return 110...520
        }
    }
}

/// A date filter: a preset or a custom range of local days.
enum DateRangeFilter: Hashable {
    case allTime
    case lastDays(Int)
    case year(Int)
    case custom(from: Date, to: Date)

    /// Whole local days, from the start of the first to the end of the last.
    var interval: DateInterval? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: today)!
        switch self {
        case .allTime:
            return nil
        case .lastDays(let days):
            return DateInterval(start: calendar.date(byAdding: .day, value: -days, to: endOfToday)!, end: endOfToday)
        case .year(let year):
            let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
            return DateInterval(start: start, end: calendar.date(byAdding: .year, value: 1, to: start)!)
        case .custom(let from, let to):
            let start = calendar.startOfDay(for: min(from, to))
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(from, to)))!
            return DateInterval(start: start, end: end)
        }
    }

    var title: String {
        switch self {
        case .allTime: return "All Time"
        case .lastDays(let days): return "Last \(days) Days"
        case .year(let year): return String(year)
        case .custom(let from, let to):
            let a = min(from, to), b = max(from, to)
            return a.formatted(date: .abbreviated, time: .omitted) + " – " + b.formatted(date: .abbreviated, time: .omitted)
        }
    }
}

struct GridSection: Hashable {
    var id: String
    var title: String
    var subtitle: String
    var itemIDs: [String]
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var message: String
    var symbol: String = "checkmark.circle.fill"
    var isError = false
}

enum DeleteMode {
    /// From the iPhone's own storage (over USB). iCloud keeps its copy.
    case iPhoneOnly
    /// From iCloud Photos, and so from every device including the iPhone.
    case iPhoneAndCloud
    /// Forget the items in FrameFold and drop anything it stored on this Mac. Nothing else changes.
    case frameFoldOnly
}

@MainActor
final class AppState: ObservableObject {
    let library: LibraryStore
    let device: DeviceManager
    let photos: PhotosBridge
    let sync: SyncEngine
    let analysis: AnalysisEngine
    let model: LocalModelService
    let categorizer: Categorizer

    @Published var sidebar: SidebarItem? = .allPhotos {
        didSet { if oldValue != sidebar { selection = [] } }
    }
    @Published var selection: Set<String> = []
    @Published var scale: TimeScale = .months
    @Published var sizes: [TimeScale: Double] = [.years: 56, .months: 150, .all: 220]
    @Published var search = ""
    @Published var viewerID: String?
    @Published var pendingDelete: [String]?
    @Published var showModelSheet = false
    /// Set when Categorise opens the model sheet, so setup starts without another click.
    var installModelWhenShown = false
    @Published var showShortcuts = false
    @Published var toast: Toast?
    @Published var scrollTarget: String?
    @Published var showCloudBadges = UserDefaults.standard.object(forKey: "showCloudBadges") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showCloudBadges, forKey: "showCloudBadges") }
    }
    @Published var renamingPerson: Person?
    /// Duplicates view: only groups taken within this range (by local day), or all when nil.
    @Published var duplicateRange: DateRangeFilter = .allTime
    /// Folded sections, as `<time scale>|<section id>` so each scale keeps its own.
    @Published private(set) var collapsedKeys: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "collapsedSections") ?? []) {
        didSet { UserDefaults.standard.set(Array(collapsedKeys), forKey: "collapsedSections") }
    }
    /// Items being deleted; hidden from the grid straight away while the phone or iCloud works.
    @Published private(set) var deletingIDs: Set<String> = []
    /// Why the last delete on the phone failed, for the message shown to the user.
    private var lastDeleteProblem: String?
    /// Items a delete left alone on purpose, added to its result message.
    private var skippedNotice: String?
    @Published var newCategoryFor: [String]?

    private var bag = Set<AnyCancellable>()
    private var toastTask: Task<Void, Never>?

    init() {
        library = LibraryStore()
        device = DeviceManager()
        photos = PhotosBridge()
        sync = SyncEngine(library: library, device: device, photos: photos)
        analysis = AnalysisEngine(library: library)
        model = LocalModelService()
        categorizer = Categorizer(library: library, model: model)

        // Background work (indexing, analysis, deletes) changes these engines many times a second.
        // Redrawing the window for each change starves the main thread, so coalesce them.
        Publishers.MergeMany([library.objectWillChange, device.objectWillChange, photos.objectWillChange,
                              sync.objectWillChange, analysis.objectWillChange, model.objectWillChange,
                              categorizer.objectWillChange])
            .throttle(for: .milliseconds(160), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)

        device.onCatalogReady = { [weak self] in self?.sync.catalogDidLoad() }
        #if DEBUG
        if ProcessInfo.processInfo.environment["FRAMEFOLD_BENCH"] != nil {
            device.onCatalogReady = { [weak self] in
                guard let self else { return }
                let files = device.files
                Task { await DebugSnapshot.benchmark(files: files) }
            }
        }
        #endif
        device.onDisconnect = { [weak self] in self?.sync.deviceDidDisconnect() }
        sync.onSyncFinished = { [weak self] in
            guard let self else { return }
            if case .finished(let added) = sync.phase {
                let listed = sync.deviceFiles.count
                show(Toast(message: added > 0
                           ? "Found \(added) new item\(added == 1 ? "" : "s") on \(device.deviceName ?? "iPhone")"
                           : "\(device.deviceName ?? "iPhone") is fully indexed: \(listed) files", symbol: "iphone"))
            }
            analysis.analyzePending()
        }
        sync.onMessage = { [weak self] message in
            self?.show(Toast(message: message, symbol: "iphone"))
        }
        sync.onPendingDeletes = { [weak self] ids in
            guard let self else { return }
            Task {
                let result = await self.deleteFromDevice(ids)
                self.finishDelete(result.deleted, failed: result.failed, note: "queued deletes from \(self.device.deviceName ?? "iPhone")")
            }
        }
        categorizer.onFinished = { [weak self] count in
            guard let self else { return }
            if let error = categorizer.lastError {
                show(Toast(message: error, symbol: "exclamationmark.triangle.fill", isError: true))
            } else {
                show(Toast(message: "Categorised \(count) item\(count == 1 ? "" : "s") with \(LocalModel.displayName)", symbol: "sparkles"))
            }
        }
    }

    func start() {
        #if DEBUG
        let skipDevice = ProcessInfo.processInfo.environment["FRAMEFOLD_NO_DEVICE"] != nil || DebugSnapshot.isDemo
        if DebugSnapshot.isDemo {
            device.showDemoDevice()
            analysis.analyzePending()
            Task { await model.refresh() }
            return
        }
        #else
        let skipDevice = false
        #endif
        if !skipDevice { device.start() }
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                let wasAuthorized = photos.isAuthorized
                photos.refreshStatus()
                if photos.isAuthorized != wasAuthorized { Task { await self.sync.refreshCloudState() } }
            }
            .store(in: &bag)
        // Nothing here waits on the Photos permission prompt, which can sit unanswered.
        analysis.analyzePending()
        Task { await model.refresh() }
        Task {
            // Clears badges from an earlier session if access is missing, before asking for it.
            await sync.refreshCloudState()
            if photos.authorization == .notDetermined {
                await photos.requestAccess()
                await sync.refreshCloudState()
            }
        }
    }

    // MARK: Derived data

    private var memoKey: (Int, SidebarItem?, String, Int) = (-1, nil, "", 0)
    private var memoItems: [PhotoItem] = []

    /// Items for the current sidebar selection and search, newest first.
    var visibleItems: [PhotoItem] {
        let key = (library.revision, sidebar, search, deletingIDs.count)
        if key == memoKey { return memoItems }
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let peopleNames = Dictionary(uniqueKeysWithValues: library.people.map { ($0.id, $0.name.lowercased()) })
        memoItems = library.items
            .filter { !$0.isCompanion && !deletingIDs.contains($0.id) && matches($0, sidebar ?? .allPhotos) }
            .filter { item in
                guard !query.isEmpty else { return true }
                return item.fileName.lowercased().contains(query)
                    || (item.category?.lowercased().contains(query) ?? false)
                    || item.labels.contains { $0.lowercased().contains(query) }
                    || item.albums.contains { $0.lowercased().contains(query) }
                    || (item.recognizedText?.lowercased().contains(query) ?? false)
                    || item.personIDs.contains { peopleNames[$0]?.contains(query) ?? false }
            }
            .sorted { $0.captureDate > $1.captureDate }
        memoKey = key
        return memoItems
    }

    private func matches(_ item: PhotoItem, _ filter: SidebarItem) -> Bool {
        switch filter {
        case .allPhotos, .duplicates: return true
        case .videos: return item.isVideo
        case .onIPhone: return item.onDevice
        case .pendingDelete: return item.pendingDeviceDelete
        case .inCloud: return item.cloud == .inCloud
        case .notInCloud: return item.cloud == .notInCloud
        case .uncategorized: return item.category == nil
        case .category(let name): return item.category == name
        case .person(let id): return item.personIDs.contains(id)
        case .album(let name): return item.albums.contains(name)
        }
    }

    private var sectionsKey: (Int, SidebarItem?, String, Int, TimeScale, Int) = (-1, nil, "", 0, .months, -1)
    private var sectionsMemo: [GridSection] = []
    /// Changes whenever `sections` does, so the grid can skip comparing thousands of ids.
    private(set) var sectionsToken = 0
    /// Photo and video counts across `sections`.
    private(set) var sectionTotals = (photos: 0, videos: 0)

    var sections: [GridSection] {
        let dupVersion = sidebar == .duplicates
            ? (analysis.duplicateGroups.count &* 31 &+ analysis.duplicateGroups.first.map(\.count).hashValue) ^ duplicateRange.hashValue
            : -1
        let key = (library.revision, sidebar, search, deletingIDs.count, scale, dupVersion)
        if key == sectionsKey { return sectionsMemo }
        let fresh = sidebar == .duplicates ? duplicateSections : groupByDate(visibleItems)
        sectionsKey = key
        // Most library changes (labels, categories, thumbnails) leave the grouping as it was;
        // only a real change should make the grid reload.
        if fresh != sectionsMemo {
            sectionsMemo = fresh
            sectionsToken &+= 1
        }
        return sectionsMemo
    }

    /// Calendar parts per local day, so grouping 10k+ items doesn't ask the calendar for each.
    private var dayParts: [Int: DateComponents] = [:]
    private var sectionTitles: [String: String] = [:]

    private func groupByDate(_ items: [PhotoItem]) -> [GridSection] {
        let calendar = Calendar.current
        let zone = TimeZone.current
        var result: [GridSection] = []
        var videos: [Int] = []
        var currentID: String?
        for item in items {
            let seconds = item.captureDate.timeIntervalSince1970 + Double(zone.secondsFromGMT(for: item.captureDate))
            let day = Int((seconds / 86_400).rounded(.down))
            let parts: DateComponents
            if let cached = dayParts[day] {
                parts = cached
            } else {
                parts = calendar.dateComponents([.year, .month, .day], from: item.captureDate)
                dayParts[day] = parts
            }
            var comps = DateComponents(year: parts.year)
            if scale != .years { comps.month = parts.month }
            if scale == .all { comps.day = parts.day }
            let id = Self.sectionID(comps)
            if id != currentID {
                currentID = id
                let titleKey = "\(scale.rawValue)|\(id)"
                let title = sectionTitles[titleKey] ?? Self.title(for: item.captureDate, scale: scale)
                sectionTitles[titleKey] = title
                result.append(GridSection(id: id, title: title, subtitle: "", itemIDs: []))
                videos.append(0)
            }
            result[result.count - 1].itemIDs.append(item.id)
            if item.isVideo { videos[videos.count - 1] += 1 }
        }
        for i in result.indices {
            result[i].subtitle = Self.countText(photos: result[i].itemIDs.count - videos[i], videos: videos[i])
        }
        let videoTotal = videos.reduce(0, +)
        sectionTotals = (items.count - videoTotal, videoTotal)
        return result
    }

    private var duplicateSections: [GridSection] {
        let query = search.lowercased()
        let interval = duplicateRange.interval
        return analysis.duplicateGroups.enumerated().compactMap { n, ids in
            let items = ids.compactMap(library.item)
            guard items.count > 1 else { return nil }
            if let interval, !items.contains(where: { interval.contains($0.captureDate) }) { return nil }
            if !query.isEmpty, !items.contains(where: { $0.fileName.lowercased().contains(query) }) { return nil }
            let date = items[0].captureDate.formatted(date: .abbreviated, time: .shortened)
            return GridSection(id: "dup-\(ids[0])", title: date, subtitle: "\(items.count) copies · keep the first", itemIDs: items.map(\.id))
        }
    }

    /// The first item of each duplicate group: the copy to keep.
    var bestDuplicateIDs: Set<String> {
        sidebar == .duplicates ? Set(analysis.duplicateGroups.compactMap(\.first)) : []
    }

    static func sectionID(_ c: DateComponents) -> String {
        "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    static func title(for date: Date, scale: TimeScale) -> String {
        switch scale {
        case .years: return date.formatted(.dateTime.year())
        case .months: return date.formatted(.dateTime.month(.wide).year())
        case .all: return date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        }
    }

    static func countText(photos: Int, videos: Int) -> String {
        var parts: [String] = []
        if photos > 0 { parts.append("\(photos) photo\(photos == 1 ? "" : "s")") }
        if videos > 0 { parts.append("\(videos) video\(videos == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }

    /// Every sidebar badge, the album list and the header counts, computed in one pass over the
    /// library and reused until the library changes.
    struct Stats {
        var counts: [SidebarItem: Int] = [:]
        var albums: [String] = []
        var hasDeviceItems = false
    }

    private var statsKey: (Int, Int) = (-1, 0)
    private var statsMemo = Stats()

    var stats: Stats {
        let key = (library.revision, deletingIDs.count)
        if key == statsKey { return statsMemo }
        var counts: [SidebarItem: Int] = [:]
        var albums = Set<String>()
        var hasDeviceItems = false
        func bump(_ item: SidebarItem) { counts[item, default: 0] += 1 }
        for item in library.items where !item.isCompanion && !deletingIDs.contains(item.id) {
            bump(.allPhotos)
            if item.isVideo { bump(.videos) }
            if item.onDevice { bump(.onIPhone) }
            if item.pendingDeviceDelete { bump(.pendingDelete) }
            if item.isFromDevice { hasDeviceItems = true }
            switch item.cloud {
            case .inCloud: bump(.inCloud)
            case .notInCloud: bump(.notInCloud)
            case .unknown: break
            }
            if let category = item.category { bump(.category(category)) } else { bump(.uncategorized) }
            for person in item.personIDs { bump(.person(person)) }
            for album in item.albums {
                bump(.album(album))
                albums.insert(album)
            }
        }
        statsMemo = Stats(counts: counts, albums: albums.sorted(), hasDeviceItems: hasDeviceItems)
        statsKey = key
        return statsMemo
    }

    func count(_ filter: SidebarItem) -> Int {
        if filter == .duplicates { return analysis.duplicateGroups.reduce(0) { $0 + $1.count - 1 } }
        return stats.counts[filter] ?? 0
    }

    var albumNames: [String] { stats.albums }

    var visiblePeople: [Person] {
        library.people.filter { !$0.isHidden && $0.faceKeys.count >= 2 }
    }

    // MARK: Collapsing

    private var scaleKey: String { sidebar == .duplicates ? "dup" : scale.rawValue }

    /// Folded section ids for the current view.
    var collapsedSections: Set<String> {
        let prefix = scaleKey + "|"
        return Set(collapsedKeys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
    }

    /// Folds or unfolds one section; with `all`, every section follows the clicked one.
    func toggleSection(_ id: String, all: Bool) {
        let key = scaleKey + "|" + id
        let collapse = !collapsedKeys.contains(key)
        if all {
            collapse ? collapseAll() : expandAll()
        } else if collapse {
            collapsedKeys.insert(key)
        } else {
            collapsedKeys.remove(key)
        }
    }

    func collapseAll() {
        let prefix = scaleKey + "|"
        collapsedKeys.formUnion(sections.map { prefix + $0.id })
    }

    func expandAll() {
        let prefix = scaleKey + "|"
        collapsedKeys = collapsedKeys.filter { !$0.hasPrefix(prefix) }
    }

    // MARK: Zoom

    var itemSize: Double {
        get { sizes[scale] ?? 150 }
        set { sizes[scale] = min(max(newValue, scale.sizeRange.lowerBound), scale.sizeRange.upperBound) }
    }

    func zoom(by factor: Double) {
        let range = scale.sizeRange
        let target = itemSize * factor
        // Pinching past the smallest size steps out to the next time scale, as in Photos.
        if target < range.lowerBound * 0.85, factor < 1 {
            if scale == .all { scale = .months } else if scale == .months { scale = .years }
            return
        }
        if target > range.upperBound * 1.15, factor > 1 {
            if scale == .years { scale = .months } else if scale == .months { scale = .all }
            return
        }
        itemSize = target
    }

    func zoomIn() { zoom(by: 1.25) }
    func zoomOut() { zoom(by: 0.8) }

    // MARK: Actions

    func open(_ id: String) {
        if scale == .years, sidebar != .duplicates, let item = library.item(id) {
            // In Years, a click zooms into that month.
            scale = .months
            scrollTarget = Self.sectionID(Calendar.current.dateComponents([.year, .month], from: item.captureDate))
            return
        }
        viewerID = id
    }

    func syncNow() {
        if device.isReady {
            sync.start()
        } else {
            device.reconnect()
            show(Toast(message: "Connect an iPhone with a USB cable to sync", symbol: "cable.connector", isError: true))
        }
    }

    /// Re-reads the connected phone's whole file list and indexes anything missing.
    func reindexIPhone() {
        guard device.camera != nil else {
            show(Toast(message: "Connect the iPhone with a USB cable to reindex it", symbol: "cable.connector", isError: true))
            return
        }
        sync.cancel()
        library.clearDeletionMarks()
        device.reloadCatalog()
        show(Toast(message: "Reading \(device.deviceName ?? "the iPhone") again…", symbol: "arrow.clockwise"))
    }

    func importFiles(_ urls: [URL]) {
        guard !sync.isRunning else { return }
        Task {
            let added = await sync.importFiles(urls)
            show(Toast(message: added == 0 ? "Nothing new to import" : "Imported \(added) item\(added == 1 ? "" : "s")", symbol: "square.and.arrow.down"))
            analysis.analyzePending()
        }
    }

    func chooseFilesToImport() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.image, .movie, .folder]
        panel.prompt = "Import"
        if panel.runModal() == .OK { importFiles(panel.urls) }
    }

    func categorize(_ scope: Categorizer.Scope) {
        guard model.isReady else {
            installModelWhenShown = true
            showModelSheet = true
            return
        }
        categorizer.start(scope: scope)
    }

    func findDuplicates() {
        sidebar = .duplicates
        Task {
            await analysis.findDuplicates()
            let count = analysis.duplicateGroups.count
            show(Toast(message: count == 0 ? "No duplicates found" : "Found \(count) group\(count == 1 ? "" : "s") of duplicates", symbol: "square.on.square"))
        }
    }

    /// Selects every copy except the best one in each duplicate group.
    /// Selects every copy except the best one, in the groups currently shown (date range and
    /// search applied).
    func selectDuplicates() {
        let wasDuplicates = sidebar == .duplicates
        if !wasDuplicates { sidebar = .duplicates }
        selection = Set(duplicateSections.flatMap { $0.itemIDs.dropFirst() })
    }

    /// How many copies `selectDuplicates` would select.
    var selectableDuplicateCount: Int {
        sidebar == .duplicates ? sections.reduce(0) { $0 + max($1.itemIDs.count - 1, 0) } : 0
    }

    func move(_ ids: some Sequence<String>, to category: String?) {
        let ids = Array(ids)
        library.updateAll(ids) {
            $0.category = category
            $0.categorySource = category == nil ? nil : .manual
            $0.categoryConfidence = nil
        }
        show(Toast(message: category.map { "Moved \(ids.count) to \($0)" } ?? "Removed category from \(ids.count)", symbol: "folder"))
    }

    /// Takes photos out of a person and remembers it, so regrouping doesn't put them back.
    func removeFromPerson(_ ids: some Sequence<String>, person personID: String) {
        let photos = Set(ids)
        library.updatePerson(personID) { person in
            person.rejectedPhotoIDs = Array(Set(person.rejectedPhotoIDs).union(photos))
            person.faceKeys.removeAll { key in photos.contains(String(key[..<(key.lastIndex(of: "_") ?? key.endIndex)])) }
            if let first = person.faceKeys.first { person.avatarPath = "\(first).jpg" }
        }
        library.updateAll(photos) { $0.personIDs.removeAll { $0 == personID } }
        selection.subtract(photos)
        show(Toast(message: "Removed \(photos.count) photo\(photos.count == 1 ? "" : "s") from \(library.person(personID)?.name ?? "person")", symbol: "person.crop.circle.badge.minus"))
    }

    func requestDelete(_ ids: some Sequence<String>) {
        let ids = Array(ids)
        guard !ids.isEmpty else { return }
        pendingDelete = ids
    }

    func performDelete(_ ids: [String], mode: DeleteMode) {
        pendingDelete = nil
        // Files folded behind an item (the original of an edit, other burst frames) go with it,
        // so the photo really disappears from the phone.
        var ids = ids + ids.flatMap { library.item($0)?.companionIDs ?? [] }
        // Photos edited on the phone whose edited version USB can't reach: deleting the original
        // would leave the photo in Photos backed only by its edit. Leave them for the Photos app.
        var protected: [PhotoItem] = []
        if mode != .frameFoldOnly {
            protected = ids.compactMap(library.item).filter { $0.editedOnPhoneOnly && $0.onDevice }
            let skip = Set(protected.map(\.id))
            ids.removeAll { skip.contains($0) }
            if !protected.isEmpty {
                AppLog.info("delete: skipped \(protected.count) edited on the phone only: " + protected.map(\.fileName).joined(separator: " "))
                let names = protected.prefix(3).map(\.fileName).joined(separator: ", ")
                skippedNotice = "\(protected.count) edited item\(protected.count == 1 ? "" : "s") (\(names)\(protected.count > 3 ? "…" : "")) skipped: delete \(protected.count == 1 ? "it" : "them") in the iPhone's Photos app, as the edited version isn't reachable over USB."
            }
        }
        guard !ids.isEmpty else {
            if let notice = skippedNotice {
                skippedNotice = nil
                show(Toast(message: notice, symbol: "pencil.slash", isError: true))
            }
            return
        }
        let items = ids.compactMap(library.item)
        let shown = items.filter { !$0.isCompanion }
        AppLog.info("delete: \(shown.count) selected (\(shown.filter { !$0.isVideo }.count) photos, \(shown.filter(\.isVideo).count) videos) + \(items.count - shown.count) folded files, mode=\(mode): "
                    + items.map { "\($0.fileName)\($0.isCompanion ? "*" : "")" }.joined(separator: " "))
        deletingIDs.formUnion(ids)
        selection.subtract(ids)
        Task {
            defer { deletingIDs.subtract(ids) }
            var removed: Set<String> = []
            var queued = 0
            var failed = 0

            switch mode {
            case .frameFoldOnly:
                removed = Set(items.map(\.id))
                library.remove(removed, exclude: true)
                finishDelete(removed, failed: 0, note: "from FrameFold")
                return

            case .iPhoneAndCloud:
                // iCloud deletes reach the iPhone through iCloud Photos.
                let cloudItems = items.filter { $0.photosAssetID != nil }
                if !cloudItems.isEmpty {
                    do {
                        let deleted = try await photos.deleteAssets(cloudItems.compactMap(\.photosAssetID))
                        removed.formUnion(cloudItems.filter { deleted.contains($0.photosAssetID!) }.map(\.id))
                        failed += cloudItems.count - deleted.count
                    } catch {
                        failed += cloudItems.count
                    }
                }
                let rest = items.filter { $0.photosAssetID == nil }
                let result = await deleteFromPhoneOrQueue(rest)
                removed.formUnion(result.deleted)
                queued = result.queued
                failed += result.failed

            case .iPhoneOnly:
                let result = await deleteFromPhoneOrQueue(items)
                removed.formUnion(result.deleted)
                queued = result.queued
                failed += result.failed
            }

            finishDelete(removed, failed: failed, note: mode == .iPhoneOnly ? "from the iPhone" : "from iCloud and the iPhone")
            if queued > 0 {
                show(Toast(message: "\(queued) item\(queued == 1 ? "" : "s") will be deleted when \(items.first?.deviceName ?? "the iPhone") connects", symbol: "clock"))
            }
        }
    }

    /// Deletes phone items now if their phone is connected, otherwise queues them. Items that
    /// only exist on this Mac (imports) are deleted from the Mac.
    private func deleteFromPhoneOrQueue(_ items: [PhotoItem]) async -> (deleted: Set<String>, queued: Int, failed: Int) {
        var deleted = Set(items.filter { !$0.isFromDevice }.map(\.id))
        let connected = items.filter { $0.isFromDevice && sync.deviceFiles[$0.id] != nil }
        let offline = items.filter { $0.isFromDevice && sync.deviceFiles[$0.id] == nil }

        let result = await deleteFromDevice(connected.map(\.id))
        deleted.formUnion(result.deleted)

        library.updateAll(offline.map(\.id)) { $0.pendingDeviceDelete = true }
        return (deleted, offline.count, result.failed)
    }

    /// Deletes files from the connected phone over USB.
    private func deleteFromDevice(_ ids: [String]) async -> (deleted: Set<String>, failed: Int) {
        let pairs = ids.compactMap { id in sync.deviceFiles[id].map { (id, $0) } }
        AppLog.info("delete: \(ids.count) requested, \(pairs.count) found in the phone's current file list")
        guard !pairs.isEmpty else { return ([], ids.count) }
        guard device.canDelete else {
            AppLog.info("delete: the phone reports it can't delete over USB")
            lastDeleteProblem = "The iPhone doesn't allow deleting over USB right now."
            library.updateAll(pairs.map(\.0)) { $0.pendingDeviceDelete = false }
            return ([], pairs.count)
        }
        let result = await device.delete(pairs.map(\.1))
        let done = Set(result.deleted.map(ObjectIdentifier.init))
        let deleted = Set(pairs.filter { done.contains(ObjectIdentifier($0.1)) }.map(\.0))
        if deleted.count < pairs.count {
            if result.reasons.contains(where: { $0.lowercased().contains("readonly") }) {
                lastDeleteProblem = "The iPhone marked these photos read-only over USB. This happens when iCloud Photos is on; use “Delete from iPhone and iCloud” or delete them on the phone."
            } else if let error = result.error {
                lastDeleteProblem = "The iPhone refused: \(error.localizedDescription)"
            }
        }
        // A refused delete shouldn't be retried on every connection.
        library.updateAll(pairs.map(\.0)) { $0.pendingDeviceDelete = false }
        return (deleted, pairs.count - deleted.count)
    }

    private func finishDelete(_ ids: Set<String>, failed: Int, note: String) {
        // Count what the user selected, not the files folded behind it.
        let selectedCount = ids.compactMap { library.item($0) }.filter { !$0.isCompanion }.count
        if !ids.isEmpty { library.remove(ids, exclude: false, deletedFromDevice: true) }
        selection.subtract(ids)
        analysis.forgetDuplicates(ids)
        if let viewerID, ids.contains(viewerID) { self.viewerID = nil }
        defer { skippedNotice = nil }
        if failed > 0 {
            let reason = lastDeleteProblem ?? "The iPhone didn't confirm the delete."
            lastDeleteProblem = nil
            show(Toast(message: "\(failed) couldn't be deleted. \(reason)", symbol: "exclamationmark.triangle.fill", isError: true))
        } else if !ids.isEmpty {
            let total = selectedCount > 0 ? selectedCount : ids.count
            if let notice = skippedNotice {
                show(Toast(message: "Deleted \(total) item\(total == 1 ? "" : "s") \(note). \(notice)", symbol: "pencil.slash", isError: true))
            } else {
                show(Toast(message: "Deleted \(total) item\(total == 1 ? "" : "s") \(note)", symbol: "trash"))
            }
        }
    }

    func cancelPendingDelete(_ ids: some Sequence<String>) {
        library.updateAll(ids) { $0.pendingDeviceDelete = false }
    }

    // MARK: Originals

    /// Shows the originals in Finder, fetching them from the phone first if needed.
    func revealInFinder(_ ids: some Sequence<String>) {
        let ids = Array(ids)
        Task {
            let (urls, missing) = await sync.fetchOriginals(ids)
            if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            if missing > 0 { reportUnreachable(missing) }
        }
    }

    /// Saves full-size originals into a folder the user picks.
    func export(_ ids: some Sequence<String>) {
        let ids = Array(ids)
        guard !ids.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose where to save \(ids.count) original\(ids.count == 1 ? "" : "s")"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task {
            var exported = 0
            var missing = 0
            for id in ids {
                guard let item = library.item(id), let source = try? await sync.fetchOriginal(id) else {
                    missing += 1
                    continue
                }
                let dest = Self.uniqueURL(in: folder, name: item.fileName)
                if (try? FileManager.default.copyItem(at: source, to: dest)) != nil { exported += 1 }
            }
            if exported > 0 { show(Toast(message: "Exported \(exported) original\(exported == 1 ? "" : "s")", symbol: "square.and.arrow.down")) }
            if missing > 0 { reportUnreachable(missing) }
        }
    }

    /// Opens the share menu for the originals, fetching them from the phone first if needed.
    func share(_ ids: some Sequence<String>) {
        let ids = Array(ids)
        Task {
            let (urls, missing) = await sync.fetchOriginals(ids)
            if missing > 0 { reportUnreachable(missing) }
            guard !urls.isEmpty, let view = NSApp.keyWindow?.contentView else { return }
            let picker = NSSharingServicePicker(items: urls)
            let point = view.convert(NSApp.keyWindow?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
            picker.show(relativeTo: NSRect(origin: point, size: CGSize(width: 1, height: 1)), of: view, preferredEdge: .minY)
        }
    }

    private func reportUnreachable(_ count: Int) {
        show(Toast(message: "Connect the iPhone to use \(count) original\(count == 1 ? "" : "s") that \(count == 1 ? "isn't" : "aren't") on this Mac",
                   symbol: "cable.connector", isError: true))
    }

    private static func uniqueURL(in folder: URL, name: String) -> URL {
        var url = folder.appendingPathComponent(name)
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            n += 1
            url = folder.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
        }
        return url
    }

    /// Files already on this Mac, for drag and drop.
    func urls(for ids: some Sequence<String>) -> [URL] {
        ids.compactMap { library.item($0) }.compactMap(library.localURL)
    }

    func item(atPath path: String) -> PhotoItem? {
        library.items.first { library.localURL(for: $0)?.path == path }
    }

    func show(_ toast: Toast) {
        withAnimation(.snappy) { self.toast = toast }
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(toast.isError ? 4 : 2.5))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth) { self.toast = nil }
        }
    }

    /// Wipes FrameFold's library and re-indexes the connected iPhone, if any.
    func resetLibrary() {
        sync.cancel()
        categorizer.cancel()
        analysis.reset()
        selection = []
        viewerID = nil
        sidebar = .allPhotos
        library.reset()
        if device.isReady { sync.catalogDidLoad() }
        show(Toast(message: "Library reset", symbol: "arrow.counterclockwise"))
    }

    func shutdown() {
        library.saveNow(synchronously: true)
        model.stopServer()
    }
}
