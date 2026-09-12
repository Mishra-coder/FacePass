import CoreGraphics
import CoreML

enum FaceModelError: LocalizedError {
    case missing(String)
    case badOutput(String)

    var errorDescription: String? {
        switch self {
        case .missing(let name): return "Model \(name) is missing from the app bundle."
        case .badOutput(let name): return "Model \(name) returned an unexpected output."
        }
    }
}

/// On-device Core ML models: SFace identity embedding and the two MiniFASNet
/// anti-spoofing models. All inference runs locally.
final class FaceModels {
    private let sface: MLModel
    private let livenessV2: MLModel
    private let livenessV1SE: MLModel

    /// Crop scales each liveness model was trained with.
    static let livenessV2Scale: CGFloat = 2.7
    static let livenessV1SEScale: CGFloat = 4.0

    /// Loads compiled models from the app bundle, or from `modelDirectory` (used by tools/tests).
    init(modelDirectory: URL? = nil) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        sface = try Self.load("SFace", from: modelDirectory, configuration)
        livenessV2 = try Self.load("LivenessV2", from: modelDirectory, configuration)
        livenessV1SE = try Self.load("LivenessV1SE", from: modelDirectory, configuration)
    }

    /// Runs each model once on a blank image so the Neural Engine compiles/loads now,
    /// not during the first real unlock.
    func warmUp() {
        guard let blank = Self.blankImage(112), let blank80 = Self.blankImage(80) else { return }
        _ = try? embedding(forAligned: blank)
        _ = try? realProbability(v2Crop: blank80, v1seCrop: blank80)
    }

    private static func blankImage(_ side: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()
    }

    /// L2-normalised 128-d identity embedding for a 112×112 aligned face.
    func embedding(forAligned face: CGImage) throws -> [Float] {
        let output = try predict(sface, image: face)
        guard let array = output.featureValue(for: "embedding")?.multiArrayValue else {
            throw FaceModelError.badOutput("SFace")
        }
        return FaceMath.normalized((0..<array.count).map { array[$0].floatValue })
    }

    /// Average "real face" probability from both anti-spoofing models (0…1).
    func realProbability(v2Crop: CGImage, v1seCrop: CGImage) throws -> Float {
        let v2 = try realClassProbability(livenessV2, crop: v2Crop, name: "LivenessV2")
        let v1se = try realClassProbability(livenessV1SE, crop: v1seCrop, name: "LivenessV1SE")
        return (v2 + v1se) / 2
    }

    private func realClassProbability(_ model: MLModel, crop: CGImage, name: String) throws -> Float {
        let output = try predict(model, image: crop)
        guard let probs = output.featureValue(for: "probs")?.multiArrayValue, probs.count == 3 else {
            throw FaceModelError.badOutput(name)
        }
        return probs[1].floatValue // class 1 = real
    }

    private func predict(_ model: MLModel, image: CGImage) throws -> MLFeatureProvider {
        guard let constraint = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint else {
            throw FaceModelError.badOutput("image input")
        }
        let value = try MLFeatureValue(cgImage: image, constraint: constraint, options: nil)
        return try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": value]))
    }

    private static func load(_ name: String, from directory: URL?, _ configuration: MLModelConfiguration) throws -> MLModel {
        let url = directory.map { $0.appendingPathComponent("\(name).mlmodelc") }
            ?? Bundle.main.url(forResource: name, withExtension: "mlmodelc")
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            throw FaceModelError.missing(name)
        }
        return try MLModel(contentsOf: url, configuration: configuration)
    }
}

enum FaceMath {
    static func normalized(_ vector: [Float]) -> [Float] {
        let length = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard length > 0 else { return vector }
        return vector.map { $0 / length }
    }

    /// Cosine similarity of two L2-normalised vectors.
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    static func meanTemplate(_ samples: [[Float]]) -> [Float]? {
        guard let first = samples.first else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        for sample in samples {
            for index in sum.indices { sum[index] += sample[index] }
        }
        return normalized(sum)
    }
}
