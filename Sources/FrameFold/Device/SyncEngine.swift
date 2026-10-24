import Foundation
import ImageCaptureCore

/// Keeps the library's pointers to iPhone files current.
///
/// In browse-only mode (the default) a sync indexes the phone: every file gets a stable id and a
/// thumbnail, and nothing else is copied. Originals are read from the phone on demand into a
/// capped cache. In copy mode the originals are also copied into the library.
///
/// On every connection the index is reconciled with the phone: new files are added, files gone
/// from the phone are dropped, and edited photos (new file, same name and time) keep their
/// category.
@MainActor
final class SyncEngine: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparing
        case indexing(done: Int, total: Int)
        case copying(done: Int, total: Int)
        case matchingCloud
        case finished(added: Int)
        case failed(String)
    }

    enum SyncError: LocalizedError {
        case notConnected
        var errorDescription: String? { "Connect the iPhone to open the original." }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var currentFileName: String?
    @Published var autoSync = UserDefaults.standard.object(forKey: "autoSync") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoSync, forKey: "autoSync") }
    }
    @Published var storageMode = StorageMode.current {
        didSet { StorageMode.current = storageMode }
    }

    /// The connected phone's files by item id.
    private(set) var deviceFiles: [String: ICCameraFile] = [:]
    /// Items on screen; indexing fetches their thumbnails first.
    var visibleIDs: [String] = []

    var onSyncFinished: (() -> Void)?
    /// Items queued for deletion that the phone still has, now that it is connected.
    var onPendingDeletes: (([String]) -> Void)?
    var onMessage: ((String) -> Void)?

    private let library: LibraryStore
    private let device: DeviceManager
    private let photos: PhotosBridge
    private var task: Task<Void, Never>?
    private var addedThisConnection = 0

    var isRunning: Bool {
        switch phase {
        case .preparing, .indexing, .copying, .matchingCloud: return true
        default: return false
        }
    }

    init(library: LibraryStore, device: DeviceManager, photos: PhotosBridge) {
        self.library = library
        self.device = device
        self.photos = photos
    }

    // MARK: Reconcile

    /// The phone finished listing its files: reconcile the index with it.
    func catalogDidLoad() {
        guard let deviceID = device.deviceID else { return }
        let deviceName = device.deviceName
        let files = device.files

        var map: [String: ICCameraFile] = [:]
        var fresh: [PhotoItem] = []
        var listed = Set<String>()
        var idOf: [ObjectIdentifier: String] = [:]
        for file in files {
            let name = Self.name(of: file)
            let date = file.exifCreationDate ?? file.fileCreationDate ?? file.creationDate ?? Date()
            let id = MediaTools.stableID(name: name, size: file.fileSize, date: date)
            if library.excludedIDs.contains(id) { continue }
            listed.insert(id)
            // Deleted through FrameFold, but the phone hasn't caught up yet.
            if library.isRecentlyDeleted(id) { continue }
            map[id] = file
            idOf[ObjectIdentifier(file)] = id
            guard !library.contains(id) else { continue }
            let isVideo = MediaTools.isVideo(fileName: name)
            var item = PhotoItem(id: id, fileName: Self.displayName(of: file), captureDate: date, fileSize: file.fileSize,
                                 pixelWidth: file.width, pixelHeight: file.height,
                                 kind: isVideo ? .video : .photo, duration: isVideo ? file.duration : nil)
            item.deviceID = deviceID
            item.deviceName = deviceName
            fresh.append(item)
        }
        let groups = Self.companionGroups(files, idOf: idOf)

        // Items of this phone that it no longer has: deleted or edited on the phone. An empty
        // listing is more likely a locked or confused phone than an emptied camera roll, so it
        // never prunes the index.
        var vanished = files.isEmpty ? [] : library.items.filter { $0.deviceID == deviceID && map[$0.id] == nil && !library.isRecentlyDeleted($0.id) }
        // A listing missing a large share of known photos is a bad read, not mass deletion on
        // the phone. Keep everything (with its categories and people) rather than prune.
        let known = library.items.filter { $0.deviceID == deviceID }.count
        if known > 50, Double(vanished.count) > Double(known) * 0.1 {
            onMessage?("\(vanished.count) photos weren't listed by the iPhone this time; kept them. Reindex to try again.")
            vanished = []
        }
        var unclaimed = Dictionary(grouping: vanished.filter { !$0.isCopied }, by: \.fileStem)
        for i in fresh.indices {
            guard var candidates = unclaimed[fresh[i].fileStem],
                  let j = candidates.firstIndex(where: { abs($0.captureDate.timeIntervalSince(fresh[i].captureDate)) < 2 })
            else { continue }
            let old = candidates.remove(at: j)
            unclaimed[fresh[i].fileStem] = candidates
            fresh[i].category = old.category
            fresh[i].categorySource = old.categorySource
            fresh[i].categoryConfidence = old.categoryConfidence
        }
        // Pointers to files that are gone go too; items with a copy on this Mac stay.
        let gone = Set(vanished.filter { !$0.isCopied }.map(\.id))
        library.remove(gone, exclude: false)
        library.upsert(fresh)
        library.mutateEach { item in
            if map[item.id] != nil {
                // Whatever the phone lists belongs to it, including items indexed before
                // FrameFold recorded which phone an item came from.
                item.deviceID = deviceID
                item.deviceName = deviceName
                item.onDevice = true
                // Show what the Photos app shows: one item per edited photo, burst or Live Photo.
                item.isCompanion = groups.companions.contains(item.id)
                item.companionIDs = groups.companionsOf[item.id] ?? []
                item.burstCount = groups.burstCount[item.id]
                item.editedOnPhoneOnly = groups.editedOnPhoneOnly.contains(item.id)
            } else if item.deviceID == deviceID {
                item.onDevice = false
            }
        }
        deviceFiles = map
        addedThisConnection = fresh.count
        if !files.isEmpty { library.pruneDeletions(stillListed: listed) }

        if !gone.isEmpty {
            onMessage?("\(gone.count) item\(gone.count == 1 ? " was" : "s were") deleted on the iPhone since the last connection")
        }
        let pending = library.items.filter { $0.pendingDeviceDelete && map[$0.id] != nil }.map(\.id)
        if !pending.isEmpty { onPendingDeletes?(pending) }

        if autoSync { start() }
    }

    func deviceDidDisconnect() {
        deviceFiles = [:]
        if isRunning { cancel() }
        library.mutateEach { $0.onDevice = false }
    }

    func start() {
        guard !isRunning, device.isReady else { return }
        task = Task { await run() }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
        currentFileName = nil
    }

    // MARK: Originals on demand

    /// The original on this Mac, fetching it from the phone into the cache if needed.
    func fetchOriginal(_ id: String) async throws -> URL {
        guard let item = library.item(id) else { throw SyncError.notConnected }
        if let url = library.localURL(for: item) { return url }
        guard let file = deviceFiles[id] else { throw SyncError.notConnected }
        let target = library.cachedOriginalURL(for: item)
        let url = try await device.download(file, to: library.cacheDir, as: target.lastPathComponent)
        let library = library
        let thumbnail = library.thumbnailURL(for: id)
        Task.detached(priority: .utility) {
            // Indexing keeps thumbnails small for speed; now that the original is here, sharpen it.
            if let image = await MediaTools.cgImage(for: url, maxPixel: 768), MediaTools.writeJPEG(image, to: thumbnail) {
                ThumbnailCache.shared.invalidate(id)
            }
            library.trimCache()
        }
        return url
    }

    /// Local URLs for the items, fetching what's needed. Items that can't be reached are skipped.
    func fetchOriginals(_ ids: [String]) async -> (urls: [URL], missing: Int) {
        var urls: [URL] = []
        var missing = 0
        for id in ids {
            if let url = try? await fetchOriginal(id) { urls.append(url) } else { missing += 1 }
        }
        return (urls, missing)
    }

    // MARK: iCloud

    /// Re-checks iCloud status and Photos albums for the whole library.
    func refreshCloudState() async {
        guard photos.isAuthorized else {
            // Without Photos access nothing is known about iCloud; don't show stale badges.
            if library.items.contains(where: { $0.cloud != .unknown }) {
                library.mutateEach { item in
                    item.cloud = .unknown
                    item.photosAssetID = nil
                    item.albums = []
                }
            }
            return
        }
        let candidates = library.items.filter { !$0.isCompanion }.map {
            PhotosBridge.Candidate(id: $0.id, fileName: $0.fileName, date: $0.captureDate, width: $0.pixelWidth, height: $0.pixelHeight)
        }
        let (matches, assetCount) = await photos.match(candidates)

        // The Mac's Photos library only says anything about iCloud when iCloud Photos is on there,
        // making it a mirror of iCloud. A library far smaller than the phone's camera roll, that
        // matches little of it, isn't one: then iCloud status is unknown, not "not in iCloud".
        let deviceCount = library.items.filter { $0.isFromDevice && !$0.isCompanion }.count
        let mirrors = deviceCount < 20 || assetCount * 2 >= deviceCount || matches.count * 2 >= deviceCount
        photos.mirrorsICloud = mirrors

        library.mutateEach { item in
            guard !item.isCompanion else { return }
            guard mirrors else {
                item.cloud = .unknown
                // Deleting these from the Mac's library wouldn't reach iCloud, so don't offer it.
                item.photosAssetID = nil
                item.albums = matches[item.id]?.albums ?? []
                return
            }
            if let match = matches[item.id] {
                item.cloud = .inCloud
                item.photosAssetID = match.assetID
                item.albums = match.albums
            } else {
                item.cloud = .notInCloud
                item.photosAssetID = nil
                item.albums = []
            }
        }
    }

    // MARK: Run

    private func run() async {
        phase = .preparing

        // 1. Thumbnails: all browsing, analysis and categorising works from these.
        let queue = library.items
            .filter { deviceFiles[$0.id] != nil && !$0.hasThumbnail && !$0.isCompanion }
            .sorted { $0.captureDate > $1.captureDate }
            .map(\.id)
        var pending = Set(queue)
        let total = queue.count
        var cursor = 0
        var done = 0
        while !pending.isEmpty {
            if Task.isCancelled { return }
            // What's on screen goes first, then the rest newest first. A few requests in flight
            // keep the phone busy; one at a time is several times slower.
            var batch = visibleIDs.filter { pending.contains($0) }.prefix(6).map { $0 }
            while batch.count < 6, cursor < queue.count {
                let id = queue[cursor]
                cursor += 1
                if pending.contains(id), !batch.contains(id) { batch.append(id) }
            }
            if batch.isEmpty { break }
            pending.subtract(batch)
            phase = .indexing(done: done, total: total)
            let items = batch.compactMap(library.item)
            let ready = await withTaskGroup(of: String?.self) { group in
                for item in items {
                    group.addTask { await self.makeThumbnail(for: item) ? item.id : nil }
                }
                var ids: [String] = []
                for await id in group { if let id { ids.append(id) } }
                return ids
            }
            done += batch.count
            // Publish per batch so the grid fills in as thumbnails arrive.
            library.updateAll(ready) { $0.hasThumbnail = true; $0.syncedAt = Date() }
            ready.forEach(ThumbnailCache.shared.invalidate)
        }

        // 2. Copy mode only: full originals into the library.
        if storageMode == .copyToMac {
            let pending = library.items
                .filter { !$0.isCopied && deviceFiles[$0.id] != nil }
                .sorted { $0.captureDate > $1.captureDate }
            for (n, item) in pending.enumerated() {
                if Task.isCancelled { return }
                phase = .copying(done: n, total: pending.count)
                await copyOriginal(item)
            }
        }

        currentFileName = nil
        phase = .matchingCloud
        await refreshCloudState()
        phase = .finished(added: addedThisConnection)
        addedThisConnection = 0
        library.saveNow()
        onSyncFinished?()
    }

    private func makeThumbnail(for item: PhotoItem) async -> Bool {
        guard let file = deviceFiles[item.id] else { return false }
        let url = library.thumbnailURL(for: item.id)
        if let data = await device.thumbnailData(for: file) {
            let written = await Task.detached(priority: .utility) {
                MediaTools.writeNormalizedThumbnail(data, to: url, maxPixel: 400)
            }.value
            if written { return true }
            #if DEBUG
            DebugSnapshot.log("decode failed \(item.fileName) bytes=\(data.count) head=\(data.prefix(12).map { String(format: "%02x", $0) }.joined())")
            #endif
        }
        // The phone had no thumbnail: read the original once and render one.
        guard let original = try? await fetchOriginal(item.id),
              let image = await MediaTools.cgImage(for: original, maxPixel: 768) else { return false }
        return MediaTools.writeJPEG(image, to: url)
    }

    private func copyOriginal(_ item: PhotoItem) async {
        guard let file = deviceFiles[item.id] else { return }
        currentFileName = item.fileName
        let dest = library.destination(for: item.fileName, date: item.captureDate)
        do {
            let url: URL
            let cached = library.cachedOriginalURL(for: item)
            if FileManager.default.fileExists(atPath: cached.path) {
                url = dest.dir.appendingPathComponent(dest.name)
                try FileManager.default.moveItem(at: cached, to: url)
            } else {
                url = try await device.download(file, to: dest.dir, as: dest.name)
            }
            let processed = await Self.process(url: url)
            library.update(item.id) { stored in
                stored.relativePath = dest.relative
                stored.contentHash = processed.hash
                if processed.meta.pixelWidth > 0 {
                    stored.pixelWidth = processed.meta.pixelWidth
                    stored.pixelHeight = processed.meta.pixelHeight
                }
                if let duration = processed.meta.duration { stored.duration = duration }
            }
        } catch {
            // Stays a pointer; retried on the next sync.
        }
    }

    private struct Processed: Sendable {
        var meta: MediaTools.Metadata
        var hash: String?
    }

    private nonisolated static func process(url: URL) async -> Processed {
        let meta = await MediaTools.metadata(for: url)
        let hash = await Task.detached(priority: .utility) { MediaTools.sha256(of: url) }.value
        return Processed(meta: meta, hash: hash)
    }

    /// The name ids are derived from; must not change, or every item would be indexed anew.
    private static func name(of file: ICCameraFile) -> String {
        file.originalFilename ?? file.name ?? "IMG"
    }

    /// The name as the phone lists it, e.g. `IMG_E4843.JPG` for an edited photo.
    private static func displayName(of file: ICCameraFile) -> String {
        file.name ?? name(of: file)
    }

    struct CompanionGroups {
        var companionsOf: [String: [String]] = [:]
        var burstCount: [String: Int] = [:]
        var companions: Set<String> = []
        var editedOnPhoneOnly: Set<String> = []

        mutating func fold(_ companion: String, into main: String) {
            guard companion != main, !companions.contains(main) else { return }
            companions.insert(companion)
            companionsOf[main, default: []].append(companion)
        }
    }

    /// Files the Photos app shows as one item, from the ids the phone attaches to them.
    static func companionGroups(_ files: [ICCameraFile], idOf: [ObjectIdentifier: String]) -> CompanionGroups {
        var result = CompanionGroups()
        func id(_ file: ICCameraFile) -> String? { idOf[ObjectIdentifier(file)] }

        // Bursts: the frame picked on the phone stands for the burst, else the first one.
        let bursts = Dictionary(grouping: files.filter { ($0.burstUUID ?? "").isEmpty == false }, by: { $0.burstUUID! })
        for frames in bursts.values where frames.count > 1 {
            let ordered = frames.sorted { ($0.name ?? "") < ($1.name ?? "") }
            let cover = ordered.first { $0.burstPicked || $0.firstPicked } ?? ordered[0]
            guard let main = id(cover) else { continue }
            result.burstCount[main] = frames.count
            for frame in frames where frame !== cover { if let other = id(frame) { result.fold(other, into: main) } }
        }

        // Edited photos and videos: the phone lists the edit (IMG_E…) and the original together.
        let related = Dictionary(grouping: files.filter { ($0.relatedUUID ?? "").isEmpty == false }, by: { $0.relatedUUID! })
        for pair in related.values where pair.count == 2 {
            guard let edit = pair.first(where: { ($0.name ?? "").uppercased().hasPrefix("IMG_E") }),
                  let original = pair.first(where: { $0 !== edit }),
                  let main = id(edit), let other = id(original) else { continue }
            result.fold(other, into: main)
        }

        // Edited, but only the original is exposed: an edit sidecar and no rendered partner.
        for file in files {
            let edited = (file.sidecarFiles ?? []).contains { ($0.name ?? "").uppercased().hasSuffix(".AAE") }
            let partners = related[file.relatedUUID ?? ""]?.count ?? 1
            if edited, partners < 2, let id = id(file) { result.editedOnPhoneOnly.insert(id) }
        }

        // Live Photos listed as two files: a photo and a short video in the same group.
        let grouped = Dictionary(grouping: files.filter { ($0.groupUUID ?? "").isEmpty == false }, by: { $0.groupUUID! })
        for members in grouped.values where members.count == 2 {
            let videos = members.filter { MediaTools.isVideo(fileName: $0.name ?? "") }
            guard videos.count == 1, let photo = members.first(where: { $0 !== videos[0] }),
                  let main = id(photo), let other = id(videos[0]) else { continue }
            result.fold(other, into: main)
        }
        return result
    }

    // MARK: Import

    /// Copies image and video files from Finder into the library. Returns how many were added.
    @discardableResult
    func importFiles(_ urls: [URL]) async -> Int {
        let fm = FileManager.default
        var files: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue, let walker = fm.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                files += walker.compactMap { $0 as? URL }
            } else {
                files.append(url)
            }
        }
        files = files.filter { MediaTools.isMedia(fileName: $0.lastPathComponent) }
        guard !files.isEmpty else { return 0 }

        let knownHashes = Set(library.items.compactMap(\.contentHash))
        var added: [PhotoItem] = []
        for (n, url) in files.enumerated() {
            phase = .copying(done: n, total: files.count)
            currentFileName = url.lastPathComponent
            let hash = await Task.detached(priority: .utility) { MediaTools.sha256(of: url) }.value
            if let hash, knownHashes.contains(hash) { continue }
            let meta = await MediaTools.metadata(for: url)
            let attributes = try? fm.attributesOfItem(atPath: url.path)
            let date = meta.captureDate ?? (attributes?[.creationDate] as? Date) ?? Date()
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            let id = MediaTools.stableID(name: url.lastPathComponent, size: size, date: date)
            guard !library.contains(id) else { continue }
            let dest = library.destination(for: url.lastPathComponent, date: date)
            do {
                try fm.copyItem(at: url, to: dest.dir.appendingPathComponent(dest.name))
            } catch {
                continue
            }
            var item = PhotoItem(id: id, fileName: url.lastPathComponent, captureDate: date, fileSize: size,
                                 pixelWidth: meta.pixelWidth, pixelHeight: meta.pixelHeight,
                                 kind: MediaTools.isVideo(fileName: url.lastPathComponent) ? .video : .photo,
                                 duration: meta.duration)
            if let image = await MediaTools.cgImage(for: url, maxPixel: 768) {
                item.hasThumbnail = MediaTools.writeJPEG(image, to: library.thumbnailURL(for: id))
            }
            item.relativePath = dest.relative
            item.syncedAt = Date()
            item.contentHash = hash
            added.append(item)
        }
        currentFileName = nil
        library.upsert(added)
        phase = .matchingCloud
        await refreshCloudState()
        phase = .finished(added: added.count)
        library.saveNow()
        return added.count
    }
}
