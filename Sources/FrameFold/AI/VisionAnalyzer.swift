import CoreGraphics
import Foundation
import Vision

/// On-device image understanding with Apple's Vision framework. The results feed the local model (labels
/// and text), duplicate detection (feature prints) and people grouping (face prints).
enum VisionAnalyzer {
    struct Face: Sendable {
        /// The face aligned to the 112×112 ArcFace pose; also used as the person's avatar.
        var crop: CGImage
        /// AuraFace identity embedding (512 floats).
        var embedding: Data
    }

    struct Result: Sendable {
        var labels: [(String, Float)]
        var text: String?
        var featurePrint: Data?
        var faces: [Face]
    }

    static func analyze(url: URL) async -> Result? {
        guard let image = await MediaTools.cgImage(for: url, maxPixel: 1024) else { return nil }
        return analyze(image: image)
    }

    static func analyze(image: CGImage) -> Result? {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let classify = VNClassifyImageRequest()
        let print = VNGenerateImageFeaturePrintRequest()
        let faces = VNDetectFaceLandmarksRequest()
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .fast
        text.usesLanguageCorrection = false
        do {
            try handler.perform([classify, print, faces, text])
        } catch {
            return nil
        }

        let labels = (classify.results ?? [])
            .filter { $0.confidence > 0.12 }
            .prefix(12)
            .map { ($0.identifier.replacingOccurrences(of: "_", with: " "), $0.confidence) }

        let lines = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let joined = lines.joined(separator: " ")
        let recognized = joined.count >= 3 ? String(joined.prefix(400)) : nil

        let featurePrint = print.results?.first.flatMap(archive)

        let faceResults = Self.faces(from: faces.results ?? [], in: image)

        return Result(labels: Array(labels), text: recognized, featurePrint: featurePrint, faces: faceResults)
    }

    /// Faces only, for photos analysed before the current face pipeline.
    static func faces(url: URL) async -> [Face]? {
        guard let image = await MediaTools.cgImage(for: url, maxPixel: 1024) else { return nil }
        let request = VNDetectFaceLandmarksRequest()
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil else { return nil }
        return faces(from: request.results ?? [], in: image)
    }

    /// Aligns and embeds detected faces. Faces too small to identify reliably are skipped.
    private static func faces(from observations: [VNFaceObservation], in image: CGImage) -> [Face] {
        let recognizer = FaceRecognizer.shared
        let size = CGSize(width: image.width, height: image.height)
        var result: [Face] = []
        for observation in observations.prefix(12) where observation.confidence > 0.5 {
            let side = min(observation.boundingBox.width * size.width, observation.boundingBox.height * size.height)
            guard side >= 32,
                  let points = FaceRecognizer.keyPoints(of: observation, imageSize: size),
                  let aligned = FaceRecognizer.align(image, keyPoints: points),
                  let embedding = recognizer.embedding(of: aligned) else { continue }
            result.append(Face(crop: aligned, embedding: FaceRecognizer.encode(embedding)))
        }
        return result
    }

    /// Distance between two archived feature prints; smaller is more alike.
    static func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Float? {
        var d: Float = 0
        guard (try? a.computeDistance(&d, to: b)) != nil else { return nil }
        return d
    }

    static func unarchive(_ data: Data) -> VNFeaturePrintObservation? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
    }

    private static func archive(_ observation: VNFeaturePrintObservation) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
    }
}
