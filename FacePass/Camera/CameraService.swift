import AVFoundation
import CoreVideo
import OSLog

enum CameraError: LocalizedError {
    case accessDenied
    case noBuiltInCamera
    case configurationFailed

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Camera access is off. Turn it on in System Settings → Privacy & Security → Camera."
        case .noBuiltInCamera:
            return "No built-in Apple camera found. FacePass refuses external, Continuity and virtual cameras."
        case .configurationFailed:
            return "The camera could not be configured."
        }
    }
}

/// Captures frames from the Mac's built-in camera only. External, Continuity and
/// virtual (CMIO extension) cameras are refused so recorded video can't be fed in.
///
/// Configure once with `prepare`, then `resume`/`pause` per lock — this keeps the
/// heavy session setup out of the unlock path so scanning starts fast.
final class CameraService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// Every power-on and power-off is logged with the owner's name, so a camera light
    /// that will not go out can be traced to whoever actually asked for it.
    static let log = Logger(subsystem: "com.devendramishra.facepass", category: "camera")

    /// Names this camera in the log — "unlock" or "facelab".
    private let label: String
    private let session = AVCaptureSession()
    /// Control only — start, stop, configure, tear down.
    ///
    /// Frame delivery MUST NOT share this queue. `stopRunning()` blocks until any
    /// in-flight delivery finishes, so if deliveries are serialised behind it on the
    /// same queue the two wait on each other for ever: the camera never stops, and
    /// every later control call is stuck behind the jam. That deadlock is what kept the
    /// green light burning.
    private let queue = DispatchQueue(label: "com.devendramishra.facepass.camera.control", qos: .userInitiated)
    /// Frame delivery only, so a busy or slow frame can never block a stop.
    private let frameQueue = DispatchQueue(label: "com.devendramishra.facepass.camera.frames", qos: .userInitiated)
    private var onFrame: ((CVPixelBuffer) -> Void)?
    private var configured = false

    /// Whether the camera is actually powered on (the green in-use indicator is lit).
    var isRunning: Bool { session.isRunning }

    /// When the current permission to stay powered on runs out.
    ///
    /// The camera is leased, never simply switched on: whoever wants it must keep
    /// saying so. Miss a renewal and `CameraLeaseReaper` shuts the camera down within
    /// a second. That way no bug, closed window or forgotten `stop()` can leave the
    /// green light burning — the failure mode is the camera going off, not staying on.
    @MainActor private var leaseExpiry: Date?

    @MainActor
    func renewLease(_ seconds: TimeInterval = 4) {
        leaseExpiry = Date().addingTimeInterval(seconds)
    }

    @MainActor
    var leaseHasExpired: Bool {
        guard let leaseExpiry else { return true }
        return leaseExpiry < Date()
    }

    init(label: String) {
        self.label = label
        super.init()
        CameraLeaseReaper.register(self)
        Self.log.info("[\(label, privacy: .public)] created")
    }

    static func builtInCamera() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.first(where: isTrustedBuiltIn)
    }

    static func isTrustedBuiltIn(_ device: AVCaptureDevice) -> Bool {
        let builtInTransport: Int32 = 0x626C_746E // 'bltn'
        return device.deviceType == .builtInWideAngleCamera
            && device.manufacturer == "Apple Inc."
            && device.transportType == builtInTransport
            && !device.isContinuityCamera
    }

    /// Sets the frame callback without touching the camera device.
    func setFrameHandler(_ onFrame: @escaping (CVPixelBuffer) -> Void) {
        self.onFrame = onFrame
    }

    /// Configures the session once. Safe to call again; it's a no-op.
    func prepare(onFrame: @escaping (CVPixelBuffer) -> Void) async throws {
        self.onFrame = onFrame
        guard await AVCaptureDevice.requestAccess(for: .video) else { throw CameraError.accessDenied }
        guard let device = Self.builtInCamera() else { throw CameraError.noBuiltInCamera }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                // Checked on the session queue so a teardown enqueued just before us
                // has already run — otherwise we could skip the reconfigure it needs.
                guard !self.configured else { continuation.resume(); return }
                do { try self.configure(device: device); self.configured = true; continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Powers the camera on and starts delivering frames. Reconfigures first if the
    /// session was torn down, so callers can release the device aggressively (to clear
    /// the in-use indicator) without ever ending up with a dead session.
    func resume() {
        Task { @MainActor in self.renewLease() }
        Self.log.info("[\(self.label, privacy: .public)] resume requested")
        queue.async {
            if !self.configured {
                guard let device = Self.builtInCamera(),
                      (try? self.configure(device: device)) != nil else { return }
                self.configured = true
            }
            if !self.session.isRunning {
                self.session.startRunning()
                Self.log.info("[\(self.label, privacy: .public)] CAMERA ON")
            }
        }
    }

    /// Fully releases the camera device so the in-use indicator clears promptly.
    /// A later `prepare` reconfigures it.
    func teardown() {
        Task { @MainActor in self.leaseExpiry = nil }
        queue.async {
            let wasRunning = self.session.isRunning
            if wasRunning { self.session.stopRunning() }
            self.session.inputs.forEach(self.session.removeInput)
            Self.log.info("[\(self.label, privacy: .public)] teardown (was running: \(wasRunning, privacy: .public))")
            self.session.outputs.forEach(self.session.removeOutput)
            self.configured = false
        }
    }

    /// One-shot start used by the enrollment preview.
    func start(onFrame: @escaping (CVPixelBuffer) -> Void) async throws {
        try await prepare(onFrame: onFrame)
        resume()
    }

    func stop() {
        Task { @MainActor in self.leaseExpiry = nil }
        teardown()
        onFrame = nil
    }

    private func configure(device: AVCaptureDevice) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        // 640×480 powers up and auto-exposes faster; SFace only needs a 112×112 crop.
        for preset in [AVCaptureSession.Preset.vga640x480, .medium, .hd1280x720] where session.canSetSessionPreset(preset) {
            session.sessionPreset = preset
            break
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraError.configurationFailed }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: frameQueue)
        guard session.canAddOutput(output) else { throw CameraError.configurationFailed }
        session.addOutput(output)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixelBuffer)
    }
}


/// Shuts down any camera whose lease has lapsed.
///
/// One timer for the whole app, holding every `CameraService` weakly. This is the
/// backstop that makes the green in-use light impossible to leak: a camera stays on
/// only while something keeps actively renewing its lease, so a closed window, a
/// dropped callback or a plain bug all end the same way — the camera goes off.
@MainActor
enum CameraLeaseReaper {
    private static var services: [ObjectIdentifier: WeakService] = [:]
    private static var timer: Timer?

    private struct WeakService {
        weak var service: CameraService?
    }

    nonisolated static func register(_ service: CameraService) {
        Task { @MainActor in
            services[ObjectIdentifier(service)] = WeakService(service: service)
            startIfNeeded()
        }
    }

    private static func startIfNeeded() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in sweep() }
        }
    }

    private static func sweep() {
        for (key, box) in services {
            guard let service = box.service else { services[key] = nil; continue }
            if service.isRunning, service.leaseHasExpired {
                CameraService.log.info("lease expired — reaping a running camera")
                service.teardown()
            }
        }
    }
}
