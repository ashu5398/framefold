import AppKit
import Photos

/// Reads the Mac's Photos library. With iCloud Photos turned on, that library mirrors iCloud, so an
/// item found there is in iCloud, and deleting it there deletes it from iCloud and every device.
@MainActor
final class PhotosBridge: ObservableObject {
    @Published private(set) var authorization: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published private(set) var isMatching = false
    /// Whether this Mac's Photos library looks like a mirror of iCloud Photos (iCloud Photos on).
    @Published var mirrorsICloud = true

    var isAuthorized: Bool {
        #if DEBUG
        if DebugSnapshot.isDemo { return true }
        #endif
        return authorization == .authorized || authorization == .limited
    }

    func requestAccess() async {
        authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    /// Picks up changes made in System Settings while the app was running.
    func refreshStatus() {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current != authorization { authorization = current }
    }

    /// Opens the Photos pane of Privacy & Security, or asks if macOS hasn't asked yet.
    func openSettings() async {
        if authorization == .notDetermined {
            await requestAccess()
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
        }
    }

    struct Match: Sendable {
        var assetID: String
        var albums: [String]
    }

    struct Candidate: Sendable {
        var id: String
        var fileName: String
        var date: Date
        var width: Int
        var height: Int
    }

    /// Matches library items to Photos assets by capture time, then file name or pixel size.
    /// Returns the matches and how many assets the Mac's library has.
    func match(_ candidates: [Candidate]) async -> (matches: [String: Match], assetCount: Int) {
        guard isAuthorized, !candidates.isEmpty else { return ([:], 0) }
        isMatching = true
        defer { isMatching = false }
        return await Task.detached(priority: .utility) {
            Self.matchSync(candidates)
        }.value
    }

    nonisolated private static func matchSync(_ candidates: [Candidate]) -> (matches: [String: Match], assetCount: Int) {
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        let assets = PHAsset.fetchAssets(with: options)

        // Bucket assets by capture second so each candidate looks at a handful of assets.
        var bySecond: [Int: [PHAsset]] = [:]
        assets.enumerateObjects { asset, _, _ in
            guard let date = asset.creationDate else { return }
            bySecond[Int(date.timeIntervalSince1970), default: []].append(asset)
        }

        let albumsByAsset = albumMemberships()
        var result: [String: Match] = [:]
        #if DEBUG
        defer { writeMatchReport(assets: assets, bySecond: bySecond, candidates: candidates, result: result) }
        #endif
        for candidate in candidates {
            let second = Int(candidate.date.timeIntervalSince1970)
            let nearby = (second - 2...second + 2).flatMap { bySecond[$0] ?? [] }
            guard !nearby.isEmpty else { continue }
            let stem = (candidate.fileName as NSString).deletingPathExtension.uppercased()
            let found = nearby.first { asset in
                let sameSize = (asset.pixelWidth == candidate.width && asset.pixelHeight == candidate.height)
                    || (asset.pixelWidth == candidate.height && asset.pixelHeight == candidate.width)
                if sameSize && candidate.width > 0 { return true }
                return PHAssetResource.assetResources(for: asset).contains {
                    ($0.originalFilename as NSString).deletingPathExtension.uppercased() == stem
                }
            } ?? (nearby.count == 1 && candidate.width == 0 ? nearby[0] : nil)
            if let found {
                result[candidate.id] = Match(assetID: found.localIdentifier, albums: albumsByAsset[found.localIdentifier] ?? [])
            }
        }
        return (result, assets.count)
    }

    #if DEBUG
    /// Scripted test runs: explain how matching went, to tune it against a real library.
    nonisolated private static func writeMatchReport(assets: PHFetchResult<PHAsset>, bySecond: [Int: [PHAsset]],
                                                     candidates: [Candidate], result: [String: Match]) {
        guard let prefix = ProcessInfo.processInfo.environment["FRAMEFOLD_SNAPSHOT"] else { return }
        let seconds = bySecond.keys.sorted()
        var lines = ["assets \(assets.count) candidates \(candidates.count) matched \(result.count)"]
        var cloud = 0, local = 0
        assets.enumerateObjects { asset, _, _ in
            if asset.sourceType.contains(.typeCloudShared) { cloud += 1 } else { local += 1 }
        }
        lines.append("sourceType cloudShared \(cloud) other \(local)")
        if let first = seconds.first, let last = seconds.last {
            lines.append("asset dates \(Date(timeIntervalSince1970: TimeInterval(first))) … \(Date(timeIntervalSince1970: TimeInterval(last)))")
        }
        for candidate in candidates.filter({ result[$0.id] == nil }).prefix(12) {
            let t = Int(candidate.date.timeIntervalSince1970)
            // Nearest asset by time, to spot time-zone offsets.
            var lo = 0, hi = seconds.count
            while lo < hi { let mid = (lo + hi) / 2; if seconds[mid] < t { lo = mid + 1 } else { hi = mid } }
            var near: Int?
            for index in [lo - 1, lo] where seconds.indices.contains(index) {
                if near == nil || abs(seconds[index] - t) < abs(near! - t) { near = seconds[index] }
            }
            var detail = "none"
            if let near, let asset = bySecond[near]?.first {
                let name = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "-"
                detail = "Δ\(near - t)s \(name) \(asset.pixelWidth)x\(asset.pixelHeight)"
            }
            lines.append("\(candidate.fileName) \(candidate.width)x\(candidate.height) \(candidate.date) nearest \(detail)")
        }
        try? lines.joined(separator: "\n").write(toFile: prefix + "-photos.txt", atomically: true, encoding: .utf8)
    }
    #endif

    /// Album names from the Photos app (user albums and the useful smart albums), keyed by asset id.
    nonisolated private static func albumMemberships() -> [String: [String]] {
        var map: [String: [String]] = [:]
        func collect(_ collections: PHFetchResult<PHAssetCollection>) {
            collections.enumerateObjects { collection, _, _ in
                guard let title = collection.localizedTitle, !title.isEmpty else { return }
                let assets = PHAsset.fetchAssets(in: collection, options: nil)
                guard assets.count > 0 else { return }
                assets.enumerateObjects { asset, _, _ in
                    map[asset.localIdentifier, default: []].append(title)
                }
            }
        }
        collect(PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil))
        let smart: [PHAssetCollectionSubtype] = [
            .smartAlbumFavorites, .smartAlbumSelfPortraits, .smartAlbumScreenshots, .smartAlbumPanoramas,
            .smartAlbumLivePhotos, .smartAlbumDepthEffect, .smartAlbumBursts, .smartAlbumSlomoVideos,
            .smartAlbumTimelapses, .smartAlbumLongExposures, .smartAlbumAnimated,
        ]
        for subtype in smart {
            collect(PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil))
        }
        return map
    }

    /// Deletes assets from the Photos library, and so from iCloud Photos. macOS asks the user to
    /// confirm. Returns the ids that were deleted.
    func deleteAssets(_ ids: [String]) async throws -> Set<String> {
        guard isAuthorized, !ids.isEmpty else { return [] }
        #if DEBUG
        if DebugSnapshot.blocksDestructiveActions { return [] }
        #endif
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        guard assets.count > 0 else { return [] }
        var found: Set<String> = []
        assets.enumerateObjects { asset, _, _ in found.insert(asset.localIdentifier) }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        }
        return found
    }
}
