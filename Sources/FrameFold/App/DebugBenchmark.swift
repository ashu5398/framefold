#if DEBUG
import Foundation
import ImageCaptureCore
import ImageIO

extension DebugSnapshot {
    /// `FRAMEFOLD_BENCH=1`: times ways of getting thumbnails from the phone. Read-only.
    @MainActor static func benchmark(files: [ICCameraFile]) async {
        let photos = files.filter { !MediaTools.isVideo(fileName: $0.name ?? "") }
        guard photos.count > 300 else { log("bench: too few photos \(photos.count)"); return }
        log("bench: \(photos.count) photos")
        var round = 0
        // A fresh, evenly spread sample per method, so the phone can't answer from a cache.
        func sample(_ n: Int) -> [ICCameraFile] {
            round += 1
            let step = photos.count / n
            return (0..<n).map { photos[min(photos.count - 1, $0 * step + round * 7)] }
        }
        func thumb(_ file: ICCameraFile, _ maxPixel: Int?) async -> Data? {
            await withCheckedContinuation { cont in
                let options: [ICCameraItemThumbnailOption: Any]? = maxPixel.map { [.imageSourceThumbnailMaxPixelSize: $0] }
                file.requestThumbnailData(options: options) { data, _ in cont.resume(returning: data) }
            }
        }
        func prefix(_ file: ICCameraFile, _ length: off_t) async -> Data? {
            let data: Data? = await withCheckedContinuation { cont in
                file.requestReadData(atOffset: 0, length: min(length, file.fileSize)) { data, _ in cont.resume(returning: data) }
            }
            // Only the thumbnail embedded in the file; never decode the full image.
            guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
            else { return nil }
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, image, nil)
            return CGImageDestinationFinalize(dest) ? out as Data : nil
        }
        func size(_ data: Data) -> Int {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return 0 }
            return max(props[kCGImagePropertyPixelWidth] as? Int ?? 0, props[kCGImagePropertyPixelHeight] as? Int ?? 0)
        }
        func run(_ label: String, concurrency: Int, _ fetch: @escaping @MainActor (ICCameraFile) async -> Data?) async {
            let files = sample(30)
            let start = Date()
            var results: [Data?] = []
            for chunk in stride(from: 0, to: files.count, by: concurrency).map({ Array(files[$0..<min($0 + concurrency, files.count)]) }) {
                let got = await withTaskGroup(of: Data?.self) { group in
                    for f in chunk { group.addTask { await fetch(f) } }
                    var out: [Data?] = []
                    for await d in group { out.append(d) }
                    return out
                }
                results += got
            }
            let seconds = Date().timeIntervalSince(start)
            let ok = results.compactMap { $0 }
            let avgKB = ok.isEmpty ? 0 : ok.reduce(0) { $0 + $1.count } / ok.count / 1024
            let avgPx = ok.isEmpty ? 0 : ok.reduce(0) { $0 + size($1) } / ok.count
            log(String(format: "bench %@ x%d: %d/%d ok, %.1fs, %.1f/s, avg %dKB, %dpx",
                       label, concurrency, ok.count, files.count, seconds, Double(files.count) / seconds, avgKB, avgPx))
        }
        await run("default", concurrency: 1) { await thumb($0, nil) }
        await run("px160", concurrency: 1) { await thumb($0, 160) }
        await run("px400", concurrency: 1) { await thumb($0, 400) }
        await run("px400", concurrency: 6) { await thumb($0, 400) }
        await run("px768", concurrency: 1) { await thumb($0, 768) }
        await run("prefix128k", concurrency: 1) { await prefix($0, 128 << 10) }
        await run("prefix512k", concurrency: 1) { await prefix($0, 512 << 10) }
        await run("prefix512k", concurrency: 6) { await prefix($0, 512 << 10) }
        await run("default", concurrency: 6) { await thumb($0, nil) }
        log("bench: done")
    }
}
#endif
