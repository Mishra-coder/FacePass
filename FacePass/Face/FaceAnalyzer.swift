import CoreGraphics
import CoreVideo
import Vision

/// Five alignment landmarks in image pixels, bottom-left origin (Vision and
/// CGContext convention). "Left" means the left side of the image.
struct FivePoints {
    var leftEye: CGPoint
    var rightEye: CGPoint
    var nose: CGPoint
    var mouthLeft: CGPoint
    var mouthRight: CGPoint

    var all: [CGPoint] { [leftEye, rightEye, nose, mouthLeft, mouthRight] }
}

struct DetectedFace {
    /// Face box in image pixels, bottom-left origin.
    let boundingBox: CGRect
    let landmarks: FivePoints
    let captureQuality: Float
    let yaw: Double
    let pitch: Double
    let roll: Double
}

enum FaceAnalyzer {
    /// Finds the largest face and its landmarks. Returns nil unless all five
    /// alignment points are present; there is no lower-quality fallback.
    static func largestFace(in pixelBuffer: CVPixelBuffer) throws -> DetectedFace? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)

        let rectangles = VNDetectFaceRectanglesRequest()
        try handler.perform([rectangles])
        guard let face = rectangles.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }) else {
            return nil
        }

        let landmarksRequest = VNDetectFaceLandmarksRequest()
        landmarksRequest.inputFaceObservations = [face]
        let qualityRequest = VNDetectFaceCaptureQualityRequest()
        qualityRequest.inputFaceObservations = [face]
        try handler.perform([landmarksRequest, qualityRequest])

        let size = CGSize(width: width, height: height)
        guard let landmarks = landmarksRequest.results?.first?.landmarks,
              let points = fivePoints(from: landmarks, imageSize: size) else {
            return nil
        }

        return DetectedFace(
            boundingBox: VNImageRectForNormalizedRect(face.boundingBox, width, height),
            landmarks: points,
            captureQuality: qualityRequest.results?.first?.faceCaptureQuality ?? 0,
            yaw: face.yaw?.doubleValue ?? 0,
            pitch: face.pitch?.doubleValue ?? 0,
            roll: face.roll?.doubleValue ?? 0
        )
    }

    private static func fivePoints(from landmarks: VNFaceLandmarks2D, imageSize: CGSize) -> FivePoints? {
        guard let eyeA = landmarks.leftPupil ?? landmarks.leftEye,
              let eyeB = landmarks.rightPupil ?? landmarks.rightEye,
              let lips = landmarks.outerLips,
              let nose = landmarks.noseCrest ?? landmarks.nose else {
            return nil
        }

        let a = centroid(eyeA.pointsInImage(imageSize: imageSize))
        let b = centroid(eyeB.pointsInImage(imageSize: imageSize))
        let lipPoints = lips.pointsInImage(imageSize: imageSize)
        // The nose crest runs from the bridge down to the tip; the tip is its lowest point.
        guard let a, let b,
              let mouthLeft = lipPoints.min(by: { $0.x < $1.x }),
              let mouthRight = lipPoints.max(by: { $0.x < $1.x }),
              let noseTip = nose.pointsInImage(imageSize: imageSize).min(by: { $0.y < $1.y }) else {
            return nil
        }

        let (leftEye, rightEye) = a.x < b.x ? (a, b) : (b, a)
        return FivePoints(leftEye: leftEye, rightEye: rightEye, nose: noseTip,
                          mouthLeft: mouthLeft, mouthRight: mouthRight)
    }

    private static func centroid(_ points: [CGPoint]) -> CGPoint? {
        guard !points.isEmpty else { return nil }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }
}
