import Accelerate
import CoreGraphics
import CoreML
import Foundation
import Vision

/// Face identity embeddings from AuraFace-v1 (fal.ai, Apache-2.0; ResNet-100 trained with an
/// ArcFace margin loss), converted to Core ML by `scripts/make-face-model.sh` and bundled as
/// `AuraFace.mlpackage`. Faces are aligned to the standard 112×112 ArcFace pose first.
final class FaceRecognizer: @unchecked Sendable {
    static let shared = FaceRecognizer()

    /// Bump when the face pipeline changes, so existing photos get their faces redone.
    static let pipelineVersion = 2
    static let embeddingLength = 512

    private let lock = NSLock()
    private var model: MLModel?
    private var loadFailed = false

    var isAvailable: Bool { Bundle.main.url(forResource: "AuraFace", withExtension: "mlpackage") != nil }

    /// Compiles the bundled model once into Application Support and loads it.
    private func loadedModel() -> MLModel? {
        lock.lock()
        defer { lock.unlock() }
        if let model { return model }
        guard !loadFailed, let source = Bundle.main.url(forResource: "AuraFace", withExtension: "mlpackage") else { return nil }
        do {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("FrameFold/Models", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Recompile when the bundled model changes (a new app build).
            let stamp = (try? FileManager.default.attributesOfItem(atPath: source.appendingPathComponent("Manifest.json").path)[.modificationDate] as? Date)?
                .timeIntervalSince1970 ?? 0
            let compiled = dir.appendingPathComponent("AuraFace-\(Int(stamp)).mlmodelc")
            if !FileManager.default.fileExists(atPath: compiled.path) {
                let temp = try MLModel.compileModel(at: source)
                try? FileManager.default.removeItem(at: compiled)
                try FileManager.default.moveItem(at: temp, to: compiled)
            }
            let config = MLModelConfiguration()
            config.computeUnits = .all
            model = try MLModel(contentsOf: compiled, configuration: config)
            return model
        } catch {
            loadFailed = true
            return nil
        }
    }

    /// L2-normalised identity embedding of an aligned 112×112 face.
    func embedding(of alignedFace: CGImage) -> [Float]? {
        guard let model = loadedModel(),
              let constraint = model.modelDescription.inputDescriptionsByName["face"]?.imageConstraint,
              let value = try? MLFeatureValue(cgImage: alignedFace, constraint: constraint, options: nil),
              let input = try? MLDictionaryFeatureProvider(dictionary: ["face": value]),
              let output = try? model.prediction(from: input),
              let array = output.featureValue(for: "embedding")?.multiArrayValue else { return nil }
        var vector = [Float](repeating: 0, count: array.count)
        for i in 0..<array.count { vector[i] = array[i].floatValue }
        var norm: Float = 0
        vDSP_svesq(vector, 1, &norm, vDSP_Length(vector.count))
        norm = sqrt(norm)
        guard norm > 0 else { return nil }
        vDSP_vsdiv(vector, 1, &norm, &vector, 1, vDSP_Length(vector.count))
        return vector
    }

    // MARK: Alignment

    /// The five-point ArcFace template in a 112×112 crop: eyes, nose tip, mouth corners.
    private static let template: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963), CGPoint(x: 73.5318, y: 51.5014), CGPoint(x: 56.0252, y: 71.7366),
        CGPoint(x: 41.5493, y: 92.3655), CGPoint(x: 70.7299, y: 92.2041),
    ]

    /// Five landmark points of a face in top-left image coordinates, in template order.
    static func keyPoints(of face: VNFaceObservation, imageSize: CGSize) -> [CGPoint]? {
        guard let landmarks = face.landmarks,
              let leftEye = landmarks.leftEye, let rightEye = landmarks.rightEye,
              let nose = landmarks.nose ?? landmarks.noseCrest, let lips = landmarks.outerLips else { return nil }
        func points(_ region: VNFaceLandmarkRegion2D) -> [CGPoint] {
            region.pointsInImage(imageSize: imageSize).map { CGPoint(x: $0.x, y: imageSize.height - $0.y) }
        }
        func centre(_ ps: [CGPoint]) -> CGPoint {
            CGPoint(x: ps.map(\.x).reduce(0, +) / CGFloat(ps.count), y: ps.map(\.y).reduce(0, +) / CGFloat(ps.count))
        }
        let eyes = [centre(points(leftEye)), centre(points(rightEye))].sorted { $0.x < $1.x }
        let nosePoints = points(nose)
        // The nose tip is the lowest point of the nose outline.
        guard let noseTip = nosePoints.max(by: { $0.y < $1.y }) else { return nil }
        let lipPoints = points(lips)
        guard let mouthLeft = lipPoints.min(by: { $0.x < $1.x }), let mouthRight = lipPoints.max(by: { $0.x < $1.x }) else { return nil }
        return [eyes[0], eyes[1], noseTip, mouthLeft, mouthRight]
    }

    /// Least-squares similarity transform (rotation, uniform scale, translation) from `src` to `dst`.
    static func similarity(from src: [CGPoint], to dst: [CGPoint]) -> CGAffineTransform? {
        let n = CGFloat(src.count)
        let sx = src.map(\.x).reduce(0, +) / n, sy = src.map(\.y).reduce(0, +) / n
        let dx = dst.map(\.x).reduce(0, +) / n, dy = dst.map(\.y).reduce(0, +) / n
        var a: CGFloat = 0, b: CGFloat = 0, variance: CGFloat = 0
        for (p, q) in zip(src, dst) {
            let px = p.x - sx, py = p.y - sy, qx = q.x - dx, qy = q.y - dy
            a += px * qx + py * qy
            b += px * qy - py * qx
            variance += px * px + py * py
        }
        guard variance > 0 else { return nil }
        a /= variance
        b /= variance
        // [a -b; b a] rotates and scales; the translation maps the source centre onto the target's.
        return CGAffineTransform(a: a, b: b, c: -b, d: a, tx: dx - (a * sx - b * sy), ty: dy - (b * sx + a * sy))
    }

    /// The face warped into the 112×112 ArcFace pose.
    static func align(_ image: CGImage, keyPoints: [CGPoint]) -> CGImage? {
        guard let transform = similarity(from: keyPoints, to: template),
              let context = CGContext(data: nil, width: 112, height: 112, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        // Work in top-left coordinates for the output, then for the source image.
        context.translateBy(x: 0, y: 112)
        context.scaleBy(x: 1, y: -1)
        context.concatenate(transform)
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(min(a.count, b.count)))
        return dot
    }

    static func encode(_ vector: [Float]) -> Data { vector.withUnsafeBufferPointer { Data(buffer: $0) } }

    static func decode(_ data: Data) -> [Float]? {
        guard data.count == embeddingLength * MemoryLayout<Float>.size else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
