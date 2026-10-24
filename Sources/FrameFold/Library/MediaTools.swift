import AppKit
import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Stateless helpers for reading media files. Safe to call off the main thread.
enum MediaTools {
    struct Metadata {
        var captureDate: Date?
        var pixelWidth: Int
        var pixelHeight: Int
        var duration: Double?
    }

    static func isMedia(fileName: String) -> Bool {
        guard let type = UTType(filenameExtension: (fileName as NSString).pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie)
    }

    static func isVideo(fileName: String) -> Bool {
        guard let type = UTType(filenameExtension: (fileName as NSString).pathExtension) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }

    static func metadata(for url: URL) async -> Metadata {
        if isVideo(fileName: url.lastPathComponent) {
            let asset = AVURLAsset(url: url)
            var meta = Metadata(captureDate: nil, pixelWidth: 0, pixelHeight: 0, duration: nil)
            if let duration = try? await asset.load(.duration) { meta.duration = duration.seconds }
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
                let rect = CGRect(origin: .zero, size: size).applying(transform)
                meta.pixelWidth = Int(abs(rect.width))
                meta.pixelHeight = Int(abs(rect.height))
            }
            if let date = try? await asset.load(.creationDate)?.load(.dateValue) { meta.captureDate = date }
            return meta
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return Metadata(captureDate: nil, pixelWidth: 0, pixelHeight: 0, duration: nil)
        }
        var width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        var height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        if let orientation = props[kCGImagePropertyOrientation] as? Int, orientation >= 5 {
            swap(&width, &height)
        }
        var date: Date?
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            date = exifFormatter.date(from: original)
        }
        return Metadata(captureDate: date, pixelWidth: width, pixelHeight: height, duration: nil)
    }

    private static let exifFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    /// A downscaled, orientation-corrected image. Works for HEIC, JPEG, PNG, RAW and video files.
    static func cgImage(for url: URL, maxPixel: Int) async -> CGImage? {
        if isVideo(fileName: url.lastPathComponent) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
            return try? await generator.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    @discardableResult
    static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.82) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    /// A PNG of the image at `url`, downscaled to `maxPixel`; vision models read PNG.
    static func pngData(contentsOf url: URL, maxPixel: Int) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// Re-encodes a thumbnail from the phone with its orientation applied, at most `maxPixel`.
    static func writeNormalizedThumbnail(_ data: Data, to url: URL, maxPixel: Int) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return false }
        return writeJPEG(image, to: url)
    }

    /// SHA-256 of the file, streamed in 4 MB chunks.
    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Stable id for a file on a device, independent of the order the device lists files in.
    static func stableID(name: String, size: Int64, date: Date?) -> String {
        let seconds = Int((date ?? .distantPast).timeIntervalSince1970)
        let digest = SHA256.hash(data: Data("\(name.uppercased())|\(size)|\(seconds)".utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
