import AppKit

/// In-memory cache of decoded thumbnails, filled from the library's Thumbnails folder.
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, CGImage>()
    private let queue = DispatchQueue(label: "framefold.thumbnails", qos: .userInitiated, attributes: .concurrent)

    private init() {
        cache.countLimit = 3000
    }

    func cached(_ id: String) -> CGImage? {
        cache.object(forKey: id as NSString)
    }

    /// Drops the cached image and tells visible cells to reload it.
    func invalidate(_ id: String) {
        cache.removeObject(forKey: id as NSString)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .thumbnailUpdated, object: nil, userInfo: ["id": id])
        }
    }

    /// Drops the cached image without asking cells to reload.
    func forget(_ id: String) {
        cache.removeObject(forKey: id as NSString)
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    /// Loads the thumbnail at `url` and calls `completion` on the main queue.
    func load(_ id: String, url: URL, completion: @escaping (CGImage?) -> Void) {
        if let image = cached(id) {
            completion(image)
            return
        }
        queue.async { [cache] in
            var image: CGImage?
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
                image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            }
            if let image { cache.setObject(image, forKey: id as NSString) }
            DispatchQueue.main.async { completion(image) }
        }
    }
}

extension Notification.Name {
    static let thumbnailUpdated = Notification.Name("FrameFoldThumbnailUpdated")
}
