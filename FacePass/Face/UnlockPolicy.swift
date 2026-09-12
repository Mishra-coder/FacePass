import Foundation

/// The single place that decides whether a camera frame counts toward unlocking.
/// Every check must pass, on several consecutive frames. Thresholds are provisional
/// and come from calibration runs recorded in tools/calibration/.
struct UnlockPolicy {
    /// SFace cosine to the enrolled template. Owner facing the camera scored 0.87–0.96;
    /// a different person's photo scored up to 0.74 (tools/calibration/2026-09-11-first-test.md).
    var minimumSimilarity: Float = 0.82
    /// Live faces scored 97–100%, phone photos and videos 0–2%.
    var minimumRealProbability: Float = 0.80
    var minimumCaptureQuality: Float = 0.32
    /// Identity scores drop sharply for turned heads, narrowing the gap to impostors.
    var maximumYawDegrees: Double = 25
    var requiredConsecutiveFrames = 2

    enum Reason: String {
        case noFace = "No face"
        case notEnrolled = "No face enrolled"
        case lowQuality = "Too blurry or dark"
        case turnedAway = "Look straight at the camera"
        case spoof = "Looks like a photo or screen"
        case notOwner = "Not you"
    }

    enum Verdict: Equatable {
        case pass
        case fail(Reason)
    }

    func evaluate(_ frame: FrameResult, template: [Float]?) -> Verdict {
        guard let embedding = frame.embedding else { return .fail(.noFace) }
        guard let template else { return .fail(.notEnrolled) }
        guard frame.captureQuality >= minimumCaptureQuality else { return .fail(.lowQuality) }
        guard abs(frame.yawDegrees) <= maximumYawDegrees else { return .fail(.turnedAway) }
        guard (frame.realProbability ?? 0) >= minimumRealProbability else { return .fail(.spoof) }
        guard FaceMath.cosine(template, embedding) >= minimumSimilarity else { return .fail(.notOwner) }
        return .pass
    }
}
