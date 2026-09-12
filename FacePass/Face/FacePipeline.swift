import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

struct FrameResult {
    let preview: CGImage
    /// Face box normalised to 0…1 with a top-left origin, for drawing.
    let faceRect: CGRect?
    let aligned: CGImage?
    let captureQuality: Float
    let embedding: [Float]?
    let realProbability: Float?
    let yawDegrees: Double
}

/// Camera frame → face detection → alignment → embedding + liveness.
/// Called only on the camera queue.
final class FacePipeline {
    private let models: FaceModels
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var lastRun: TimeInterval = 0
    private let minimumInterval: TimeInterval = 1.0 / 30

    init(models: FaceModels) {
        self.models = models
    }

    /// Clears the frame-rate throttle so the next attempt processes its first frame at once.
    func resetThrottle() {
        lastRun = 0
    }

    func process(_ pixelBuffer: CVPixelBuffer) -> FrameResult? {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastRun >= minimumInterval else { return nil }
        lastRun = now

        // Detect on the pixel buffer first; render a full CGImage only once a face is
        // found, so empty frames stay cheap and detection is faster.
        let detected = try? FaceAnalyzer.largestFace(in: pixelBuffer)
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let frame = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        guard let face = detected else {
            return FrameResult(preview: frame, faceRect: nil, aligned: nil, captureQuality: 0,
                               embedding: nil, realProbability: nil, yawDegrees: 0)
        }

        let width = CGFloat(frame.width)
        let height = CGFloat(frame.height)
        let box = face.boundingBox
        let normalisedRect = CGRect(x: box.minX / width, y: (height - box.maxY) / height,
                                    width: box.width / width, height: box.height / height)

        let aligned = FaceCropper.aligned(frame, points: face.landmarks)
        let embedding = aligned.flatMap { try? models.embedding(forAligned: $0) }

        var realProbability: Float?
        if let v2 = FaceCropper.livenessCrop(frame, faceBox: box, scale: FaceModels.livenessV2Scale),
           let v1se = FaceCropper.livenessCrop(frame, faceBox: box, scale: FaceModels.livenessV1SEScale) {
            realProbability = try? models.realProbability(v2Crop: v2, v1seCrop: v1se)
        }

        return FrameResult(preview: frame, faceRect: normalisedRect, aligned: aligned,
                           captureQuality: face.captureQuality, embedding: embedding,
                           realProbability: realProbability, yawDegrees: face.yaw * 180 / .pi)
    }
}
