import Foundation
import os

/// App log at `~/Library/Logs/FrameFold/FrameFold.log` (also in Console under the app's
/// subsystem), for diagnosing device operations on real hardware.
enum AppLog {
    private static let logger = Logger(subsystem: "io.github.ashu5398.framefold", category: "app")
    private static let queue = DispatchQueue(label: "framefold.log")
    private static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/FrameFold", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("FrameFold.log")
    }()
    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static var directory: URL { url.deletingLastPathComponent() }

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        let line = "\(stamp.string(from: Date())) \(message)\n"
        queue.async {
            // Keep the file small: start over past 5 MB.
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 5 << 20 {
                try? FileManager.default.removeItem(at: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
