import AppKit
import Combine
import Foundation

/// Owns the on-disk library: thumbnails, analysis files, the JSON index and, in copy mode or for
/// imported files, originals. In browse-only mode originals fetched from the iPhone go to a
/// size-capped cache in `~/Library/Caches/FrameFold/Originals`.
///
/// Layout (default `~/Pictures/FrameFold Library`):
/// ```
/// Originals/YYYY/MM/<file>        copy mode and imports only
/// Thumbnails/<id>.jpg
/// FeaturePrints/<id>.fp
/// Faces/<id>_<n>.jpg / .fp
/// library.json
/// ```
@MainActor
final class LibraryStore: ObservableObject {
    /// Not `@Published`: every element change of a published array copies the whole array, which
    /// turns a pass over a large library quadratic. Mutations bump `revision` instead.
    private(set) var items: [PhotoItem] = []
    @Published private(set) var people: [Person] = []
    @Published private(set) var categories: [PhotoCategory] = PhotoCategory.defaults
    private(set) var excludedIDs: Set<String> = []
    private(set) var deletedAt: [String: Date] = [:]

    /// How long a deleted item stays hidden while the phone still lists it. After that the phone
    /// evidently kept it (for example iCloud Photos is off there), so it is shown again.
    static let deletionGrace: TimeInterval = 14 * 24 * 3600

    func isRecentlyDeleted(_ id: String) -> Bool {
        guard let date = deletedAt[id] else { return false }
        return Date().timeIntervalSince(date) < Self.deletionGrace
    }

    /// Lets every file the phone lists back into the index, including recent deletes it still has.
    func clearDeletionMarks() {
        guard !deletedAt.isEmpty else { return }
        deletedAt = [:]
        didChange()
    }

    /// Forgets deletions the phone has caught up with (no longer lists) or that are too old.
    func pruneDeletions(stillListed: Set<String>) {
        let before = deletedAt.count
        deletedAt = deletedAt.filter { stillListed.contains($0.key) && Date().timeIntervalSince($0.value) < Self.deletionGrace }
        if deletedAt.count != before { didChange() }
    }
    /// Bumped on every mutation so views can memoise derived lists.
    @Published private(set) var revision = 0

    let root: URL
    var originalsDir: URL { root.appendingPathComponent("Originals", isDirectory: true) }
    var thumbnailsDir: URL { root.appendingPathComponent("Thumbnails", isDirectory: true) }
    var printsDir: URL { root.appendingPathComponent("FeaturePrints", isDirectory: true) }
    var facesDir: URL { root.appendingPathComponent("Faces", isDirectory: true) }
    let cacheDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FrameFold/Originals", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    /// Most bytes of iPhone originals kept in the cache.
    nonisolated static let cacheLimit: Int64 = 3 << 30
    private var indexURL: URL { root.appendingPathComponent("library.json") }

    private var indexByID: [String: Int] = [:]
    private var saveTask: Task<Void, Never>?

    init(root: URL = LibraryStore.defaultRoot) {
        self.root = root
        let fm = FileManager.default
        for dir in [root, originalsDir, thumbnailsDir, printsDir, facesDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        load()
    }

    nonisolated static var defaultRoot: URL {
        if let override = ProcessInfo.processInfo.environment["FRAMEFOLD_LIBRARY"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!
        return pictures.appendingPathComponent("FrameFold Library", isDirectory: true)
    }

    // MARK: Lookup

    func item(_ id: String) -> PhotoItem? {
        indexByID[id].map { items[$0] }
    }

    func contains(_ id: String) -> Bool { indexByID[id] != nil }

    func originalURL(for item: PhotoItem) -> URL? {
        item.relativePath.map { originalsDir.appendingPathComponent($0) }
    }

    /// Where a cached copy of an iPhone original goes.
    func cachedOriginalURL(for item: PhotoItem) -> URL {
        let ext = (item.fileName as NSString).pathExtension
        return cacheDir.appendingPathComponent(ext.isEmpty ? item.id : "\(item.id).\(ext)")
    }

    /// The original if it is on this Mac, as a library copy or in the cache.
    func localURL(for item: PhotoItem) -> URL? {
        if let url = originalURL(for: item) { return url }
        let cached = cachedOriginalURL(for: item)
        guard FileManager.default.fileExists(atPath: cached.path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: cached.path)
        return cached
    }

    /// The best image to analyse without touching the iPhone: a local original or the thumbnail.
    func analysisURL(for item: PhotoItem) -> URL? {
        if let url = localURL(for: item) { return url }
        return item.hasThumbnail ? thumbnailURL(for: item.id) : nil
    }

    /// Deletes the least recently used cached originals until the cache fits its limit.
    nonisolated func trimCache() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FrameFold/Originals", isDirectory: true)
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return }
        var entries = files.compactMap { url -> (URL, Int64, Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        entries.sort { $0.2 < $1.2 }
        for entry in entries where total > Self.cacheLimit {
            try? FileManager.default.removeItem(at: entry.0)
            total -= entry.1
        }
    }

    func cacheSize() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    func clearCache() {
        let files = (try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)) ?? []
        files.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    func thumbnailURL(for id: String) -> URL {
        thumbnailsDir.appendingPathComponent("\(id).jpg")
    }

    func featurePrintURL(for id: String) -> URL {
        printsDir.appendingPathComponent("\(id).fp")
    }

    func person(_ id: String) -> Person? { people.first { $0.id == id } }

    // MARK: Mutation

    func upsert(_ newItems: [PhotoItem]) {
        guard !newItems.isEmpty else { return }
        for item in newItems {
            if let i = indexByID[item.id] {
                items[i] = item
            } else {
                indexByID[item.id] = items.count
                items.append(item)
            }
        }
        didChange()
    }

    func update(_ id: String, _ body: (inout PhotoItem) -> Void) {
        guard let i = indexByID[id] else { return }
        body(&items[i])
        didChange()
    }

    func updateAll(_ ids: some Sequence<String>, _ body: (inout PhotoItem) -> Void) {
        var changed = false
        for id in ids {
            if let i = indexByID[id] { body(&items[i]); changed = true }
        }
        if changed { didChange() }
    }

    /// Applies `body` to every item; used by matching passes over the whole library.
    func mutateEach(_ body: (inout PhotoItem) -> Void) {
        for i in items.indices { body(&items[i]) }
        didChange()
    }

    /// Removes items from the index and deletes their files on this Mac. With `exclude`, sync will
    /// not copy them again from a device that still has them.
    func remove(_ ids: Set<String>, exclude: Bool = true, deletedFromDevice: Bool = false) {
        guard !ids.isEmpty else { return }
        if exclude { excludedIDs.formUnion(ids) }
        if deletedFromDevice {
            let now = Date()
            for id in ids { deletedAt[id] = now }
        }
        // Collect the files here, delete them off the main thread: thousands of removals would
        // otherwise freeze the window.
        var urls: [URL] = []
        for id in ids {
            guard let item = item(id) else { continue }
            if let url = originalURL(for: item) { urls.append(url) }
            urls.append(cachedOriginalURL(for: item))
            urls.append(thumbnailURL(for: id))
            urls.append(featurePrintURL(for: id))
            for n in 0..<max(item.faceCount, 0) {
                urls.append(facesDir.appendingPathComponent("\(id)_\(n).jpg"))
                urls.append(facesDir.appendingPathComponent("\(id)_\(n).fp"))
                urls.append(facesDir.appendingPathComponent("\(id)_\(n).emb"))
            }
            ThumbnailCache.shared.forget(id)
        }
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            for url in urls { try? fm.removeItem(at: url) }
        }
        items.removeAll { ids.contains($0.id) }
        rebuildIndex()
        // Drop people that no longer appear in any photo.
        let used = Set(items.flatMap(\.personIDs))
        people.removeAll { !used.contains($0.id) }
        didChange()
    }

    /// Deletes everything FrameFold stored (index, thumbnails, analysis, copies, cache) and starts
    /// empty. Nothing on the iPhone or in iCloud is touched.
    func reset() {
        saveTask?.cancel()
        saveTask = nil
        let fm = FileManager.default
        try? fm.removeItem(at: root)
        clearCache()
        for dir in [root, originalsDir, thumbnailsDir, printsDir, facesDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        items = []
        people = []
        categories = PhotoCategory.defaults
        excludedIDs = []
        deletedAt = [:]
        indexByID = [:]
        ThumbnailCache.shared.removeAll()
        revision &+= 1
    }

    /// Copies on this Mac of photos the connected iPhone still has. Copies of photos gone from
    /// the phone are the only copy left, so they never count.
    var redundantCopies: (count: Int, bytes: Int64) {
        let copies = items.filter { $0.isCopied && $0.onDevice }
        return (copies.count, copies.reduce(0) { $0 + $1.fileSize })
    }

    /// Deletes this Mac's copies of iPhone photos, keeping each item as a pointer to the phone
    /// with its thumbnail, category and people. Imported files are left alone.
    func removeRedundantCopies() {
        let fm = FileManager.default
        for i in items.indices where items[i].isCopied && items[i].onDevice {
            if let url = originalURL(for: items[i]) { try? fm.removeItem(at: url) }
            items[i].relativePath = nil
        }
        didChange()
    }

    func setPeople(_ newPeople: [Person]) {
        people = newPeople
        didChange()
    }

    func updatePerson(_ id: String, _ body: (inout Person) -> Void) {
        guard let i = people.firstIndex(where: { $0.id == id }) else { return }
        body(&people[i])
        didChange()
    }

    /// Moves every photo of `source` onto `target` and drops `source`.
    func mergePerson(_ source: String, into target: String) {
        guard source != target, let from = people.first(where: { $0.id == source }),
              let t = people.firstIndex(where: { $0.id == target }) else { return }
        // The faces move too, and the merge is remembered, so regrouping keeps them together.
        people[t].faceKeys += from.faceKeys.filter { !people[t].faceKeys.contains($0) }
        people[t].rejectedPhotoIDs = Array(Set(people[t].rejectedPhotoIDs).union(from.rejectedPhotoIDs))
        people[t].isUserMerged = true
        if !people[t].isNamed, from.isNamed {
            people[t].name = from.name
            people[t].isNamed = true
        }
        for i in items.indices where items[i].personIDs.contains(source) {
            items[i].personIDs.removeAll { $0 == source }
            if !items[i].personIDs.contains(target) { items[i].personIDs.append(target) }
        }
        people.removeAll { $0.id == source }
        didChange()
    }

    func setCategories(_ list: [PhotoCategory]) {
        categories = list
        didChange()
    }

    func addCategory(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !categories.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        categories.append(PhotoCategory(name: trimmed, detail: trimmed, symbol: "folder"))
        didChange()
    }

    func renameCategory(_ old: String, to new: String) {
        let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = categories.firstIndex(where: { $0.name == old }) else { return }
        categories[i].name = trimmed
        for j in items.indices where items[j].category == old { items[j].category = trimmed }
        didChange()
    }

    func deleteCategory(_ name: String) {
        categories.removeAll { $0.name == name }
        for i in items.indices where items[i].category == name {
            items[i].category = nil
            items[i].categorySource = nil
            items[i].categoryConfidence = nil
        }
        didChange()
    }

    // MARK: Paths for new originals

    /// A unique destination folder + file name for a new original, grouped by capture month.
    func destination(for fileName: String, date: Date) -> (dir: URL, name: String, relative: String) {
        let comps = Calendar.current.dateComponents([.year, .month], from: date)
        let sub = String(format: "%04d/%02d", comps.year ?? 1970, comps.month ?? 1)
        let dir = originalsDir.appendingPathComponent(sub, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var name = fileName
        let stem = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var n = 1
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
            n += 1
            name = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
        }
        return (dir, name, "\(sub)/\(name)")
    }

    // MARK: Persistence

    private func didChange() {
        revision &+= 1
        scheduleSave()
    }

    private func rebuildIndex() {
        indexByID = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let index = try? decoder.decode(LibraryIndex.self, from: data) else { return }
        items = index.items
        people = index.people
        categories = index.categories.isEmpty ? PhotoCategory.defaults : index.categories
        excludedIDs = index.excludedIDs
        deletedAt = index.deletedAt
        // Nothing is on a device until one connects and reports its catalogue. A thumbnail on
        // disk counts even if the index was saved before it was recorded (crash, force quit).
        let thumbnails = Set((try? FileManager.default.contentsOfDirectory(atPath: thumbnailsDir.path)) ?? [])
        #if DEBUG
        let keepDeviceFlags = DebugSnapshot.isDemo
        #else
        let keepDeviceFlags = false
        #endif
        for i in items.indices {
            if !keepDeviceFlags { items[i].onDevice = false }
            if !items[i].hasThumbnail, thumbnails.contains("\(items[i].id).jpg") { items[i].hasThumbnail = true }
        }
        rebuildIndex()
    }

    /// Saves within two seconds of a change. A throttle, not a debounce: during long runs such
    /// as indexing, changes never pause, and progress must still reach disk.
    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.saveTask = nil
            self.saveNow()
        }
    }

    func saveNow(synchronously: Bool = false) {
        saveTask?.cancel()
        saveTask = nil
        let index = LibraryIndex(items: items, people: people, categories: categories, excludedIDs: excludedIDs, deletedAt: deletedAt)
        let url = indexURL
        let write = {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            guard let data = try? encoder.encode(index) else { return }
            try? data.write(to: url, options: .atomic)
        }
        if synchronously {
            write()
        } else {
            Task.detached(priority: .utility) { write() }
        }
    }
}
