import CoreGraphics
import Foundation

/// Drives the Face Lab window. Nothing here is persisted: enrolled samples live
/// in memory only and vanish when the window closes or the app quits.
@MainActor
final class FaceLabModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running
        case failed(String)
    }

    static let enrollmentTarget = 15
    static let enrollmentMinimumQuality: Float = 0.25

    let policy = UnlockPolicy()

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var preview: CGImage?
    @Published private(set) var aligned: CGImage?
    @Published private(set) var faceRect: CGRect?
    @Published private(set) var captureQuality: Float = 0
    @Published private(set) var realProbability: Float?
    @Published private(set) var yawDegrees: Double = 0
    @Published private(set) var similarity: Float?
    @Published private(set) var enrolledSampleCount = 0
    @Published private(set) var isEnrolling = false
    @Published private(set) var enrollmentHint = ""
    @Published private(set) var hasTemplate = false
    @Published private(set) var verdict: UnlockPolicy.Verdict = .fail(.noFace)
    @Published private(set) var passStreak = 0

    var wouldUnlock: Bool { passStreak >= policy.requiredConsecutiveFrames }

    private let camera = CameraService(label: "facelab")
    private var samples: [[Float]] = []
    private var template: [Float]?

    func start() async {
        guard phase != .running else { return }
        loadSavedFace()
        do {
            let pipeline = FacePipeline(models: try FaceModels())
            try await camera.start { [weak self] pixelBuffer in
                guard let result = pipeline.process(pixelBuffer) else { return }
                Task { @MainActor in self?.apply(result) }
            }
            phase = .running
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Called on a timer by the view that shows the preview. When that view goes away —
    /// pane switched, window closed, app hidden — the renewals simply stop arriving and
    /// the camera shuts itself down. Nothing has to remember to turn it off.
    func renewCameraLease() {
        camera.renewLease()
    }

    func stop() {
        camera.stop()
        phase = .idle
        preview = nil
        faceRect = nil
        passStreak = 0
    }

    func beginEnrollment() {
        samples.removeAll()
        enrolledSampleCount = 0
        enrollmentHint = "Look at the camera…"
        isEnrolling = true
    }

    func forgetFace() {
        samples.removeAll()
        template = nil
        hasTemplate = false
        isEnrolling = false
        enrolledSampleCount = 0
        similarity = nil
        passStreak = 0
    }

    private func apply(_ result: FrameResult) {
        preview = result.preview
        aligned = result.aligned
        faceRect = result.faceRect
        captureQuality = result.captureQuality
        realProbability = result.realProbability
        yawDegrees = result.yawDegrees

        if isEnrolling {
            enroll(result)
        }

        similarity = zip(template, result.embedding).map { FaceMath.cosine($0, $1) }
        verdict = policy.evaluate(result, template: template)
        passStreak = verdict == .pass ? passStreak + 1 : 0
    }

    /// Liveness is shown but doesn't block Face Lab enrollment; head pose and sharpness do,
    /// so the template is built only from frames the unlock policy could also accept.
    private func enroll(_ result: FrameResult) {
        guard let embedding = result.embedding else {
            enrollmentHint = result.faceRect == nil
                ? "No face found — sit in front of the camera"
                : "Face found but landmarks unclear — face the camera"
            return
        }
        guard result.captureQuality >= Self.enrollmentMinimumQuality else {
            enrollmentHint = String(format: "Skipping blurry/dark frame (quality %.2f, need %.2f) — add light, hold still",
                                    result.captureQuality, Self.enrollmentMinimumQuality)
            return
        }
        guard abs(result.yawDegrees) <= policy.maximumYawDegrees else {
            enrollmentHint = String(format: "Head turned %+.0f° — look straight at the camera", result.yawDegrees)
            return
        }

        samples.append(embedding)
        enrolledSampleCount = samples.count
        enrollmentHint = "Capturing \(samples.count)/\(Self.enrollmentTarget)…"
        if samples.count >= Self.enrollmentTarget {
            if let built = FaceMath.meanTemplate(samples) {
                template = built
                hasTemplate = true
                persist(template: built, samples: samples)
            }
            isEnrolling = false
            samples.removeAll()
        }
    }

    /// Saves the enrolled face encrypted so it survives quitting the app.
    private func persist(template: [Float], samples: [[Float]]) {
        let enrollment = FaceEnrollment(template: template, samples: samples,
                                        createdAt: Date(), modelVersion: "sface-2021dec-1")
        do {
            try FaceTemplateStore.shared.save(enrollment)
            enrollmentHint = "Face saved"
        } catch {
            enrollmentHint = "Saved for this session only — couldn't write to keychain"
        }
    }

    /// Reloads a face saved in a previous run, so enrollment isn't needed every launch.
    func loadSavedFace() {
        guard template == nil, let saved = try? FaceTemplateStore.shared.load() else { return }
        template = saved.template
        hasTemplate = true
    }

    func forgetSavedFace() {
        try? FaceTemplateStore.shared.delete()
        forgetFace()
    }
}

private func zip(_ a: [Float]?, _ b: [Float]?) -> ([Float], [Float])? {
    guard let a, let b else { return nil }
    return (a, b)
}
