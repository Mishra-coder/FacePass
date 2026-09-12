import AppKit
import Combine
import Foundation

/// The heart of FacePass once it is set up: watches for the screen locking, then
/// scans for the owner's face and, on a confident live match, types the password so
/// the Mac unlocks. Runs only while the session is armed. Reuses the same face
/// pipeline, unlock policy, vault and typer proven in the Lab windows.
@MainActor
final class UnlockController: ObservableObject {
    enum Phase: Equatable {
        case idle            // unlocked screen, nothing to do
        case scanning        // locked, looking for the owner
        case matched         // face accepted, typing
        case rejected(String) // couldn't recognise; reason
    }

    @Published private(set) var isEnabled = false
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastMatch: Float?
    @Published private(set) var lastReal: Float?

    private let vault = PasswordVault.shared
    private let templates = FaceTemplateStore.shared
    private let settings = FacePassSettings.shared
    private let policy = UnlockPolicy()
    private let overlay = ScanOverlayController()

    private var template: [Float]?
    // Loaded once when enabled and reused for every lock, so scanning starts instantly.
    private var models: FaceModels?
    private var camera: CameraService?
    private var pipeline: FacePipeline?
    private var scanning = false
    private var passScore = 0.0   // leaky accumulator of fully-passing frames
    private var didTypeThisLock = false
    private var typeAttempts = 0
    private var retryTask: Task<Void, Never>?
    private var watchdog: Timer?
    private let spaceKey = SpaceKeyMonitor()
    /// When the current scan runs out of time, per the detection-duration setting.
    private var scanDeadline: Date?
    /// Set once a scan has failed, so "retry on hover" and the space bar have something
    /// to un-stick without them also firing during a scan that is still running.
    private var awaitingRetry = false
    private var observers: [NSObjectProtocol] = []

    /// Ready to unlock automatically: enrolled, password sealed, armed, and permitted.
    var isReady: Bool {
        templates.isEnrolled && vault.isSetUp && vault.isArmed && PasswordTyper.hasAccessibilityPermission
    }

    func enable() {
        guard !isEnabled else { return }
        isEnabled = true
        let center = DistributedNotificationCenter.default()
        observers = [
            center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.screenLocked() }
            },
            center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.screenUnlocked() }
            },
        ]
        // Waking to a locked screen is its own trigger: the lock notification fired
        // when the Mac went to sleep, not now, so without this nothing would start.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.settings.triggerOnWake else { return }
                self.screenWoke()
            }
        })
        startWatchdog()
        prewarm()
        // If we are enabled while already locked (e.g. armed from the lock screen), begin.
        if ScreenLockState.isLocked { screenLocked() }
    }

    /// Woken to a locked screen. `screenLocked` is gated on the "On lock" setting, so
    /// this deliberately starts the attempt itself rather than routing through it.
    private func screenWoke() {
        guard isEnabled, ScreenLockState.isLocked else { return }
        didTypeThisLock = false
        typeAttempts = 0
        passScore = 0
        startAttempt()
    }

    func disable() {
        guard isEnabled else { return }
        isEnabled = false
        retryTask?.cancel()
        retryTask = nil
        watchdog?.invalidate()
        watchdog = nil
        spaceKey.stop()
        observers.forEach(DistributedNotificationCenter.default().removeObserver)
        observers.removeAll()
        stopScanning()
        camera?.teardown()
        camera = nil
        pipeline = nil
        models = nil
        phase = .idle
    }

    /// Load the models now (while unlocked) so the first lock doesn't pay for the
    /// CoreML compile. The camera is deliberately NOT opened here: creating an
    /// `AVCaptureDeviceInput` opens the device, which lights the green in-use
    /// indicator even before the session runs. So we only touch the camera while the
    /// screen is actually locked, and `resume` configures it on demand.
    private func prewarm() {
        if models == nil, let loaded = try? FaceModels() {
            models = loaded
            pipeline = FacePipeline(models: loaded)
            loaded.warmUp()
        }
        if camera == nil { camera = CameraService(label: "unlock") }
        camera?.setFrameHandler { [weak self] buffer in
            guard let self, let pipeline = self.pipeline, let result = pipeline.process(buffer) else { return }
            Task { @MainActor in self.handle(result) }
        }
    }

    private func screenLocked() {
        guard isEnabled, ScreenLockState.isLocked, settings.triggerOnLock else { return }
        if settings.triggerOnSpace {
            spaceKey.onSpaceKeyDown = { [weak self] in self?.retry() }
            spaceKey.start()
        }
        didTypeThisLock = false
        typeAttempts = 0
        passScore = 0
        startAttempt()
    }

    private func screenUnlocked() {
        // Kill any pending re-scan first: if it fired after the unlock it would power
        // the camera back on with nothing to turn it off, leaving the green light lit.
        retryTask?.cancel()
        retryTask = nil
        typeAttempts = 0
        awaitingRetry = false
        // Hold no keyboard access at all while the Mac is actually in use.
        spaceKey.stop()
        stopScanning()
        phase = .idle
        // stopScanning released the device. We do NOT re-open it here — the camera
        // stays untouched until the screen locks again, so the indicator stays dark.
    }

    /// Scan continuously while the screen is locked until the owner is recognised.
    /// There is no "give up" — it keeps looking (the leaky score tolerates bad frames),
    /// so a face that isn't recognised for a moment is simply picked up when it is.
    private func startAttempt() {
        // Never power the camera on unless the screen really is locked in this session.
        guard ScreenLockState.isLocked, ScreenLockState.isOnConsole else {
            stopScanning()
            phase = .idle
            return
        }
        guard isReady, !didTypeThisLock else {
            if !isReady { phase = .rejected("FacePass isn't armed") }
            return
        }
        if template == nil { template = try? templates.load()?.template }
        guard template != nil else { phase = .rejected("No face enrolled"); return }

        passScore = 0
        pipeline?.resetThrottle()
        phase = .scanning
        scanning = true
        scanDeadline = Date().addingTimeInterval(settings.detectionDuration)
        if settings.showAnimation { overlay.show(.scanning) }

        // Models are already loaded; `resume` opens and configures the camera itself.
        if camera == nil { prewarm() }
        camera?.resume()
    }

    private func handle(_ frame: FrameResult) {
        // Safety net: if a frame ever arrives while the screen is unlocked, the camera
        // should not be on at all — shut it down rather than just dropping the frame.
        guard ScreenLockState.isLocked, ScreenLockState.isOnConsole else {
            if scanning { stopScanning(); phase = .idle }
            return
        }
        guard scanning, phase == .scanning else { return }
        lastMatch = frame.embedding.flatMap { e in template.map { FaceMath.cosine($0, e) } }
        lastReal = frame.realProbability

        let needed = Double(policy.requiredConsecutiveFrames)
        switch policy.evaluate(frame, template: template) {
        case .pass:
            // Each fully-passing frame (match + liveness + quality + pose) adds 1.
            passScore = min(needed, passScore + 1)
            if passScore >= needed { succeed() }
        case .fail:
            // A stray bad frame only nudges the score down, so brief blinks/blur or an
            // auto-exposure dip don't restart from zero. We keep scanning — no giving up.
            passScore = max(0, passScore - 0.5)
        }
    }

    private func succeed() {
        phase = .matched
        scanning = false
        passScore = 0
        // Release the device outright, not just pause: we are done looking, and the
        // green in-use indicator only clears once the camera is fully let go. `resume`
        // reconfigures by itself if we need it again for a retry.
        camera?.teardown()
        typeAttempts += 1
        let isRetry = typeAttempts > 1
        if settings.showAnimation { overlay.show(.matched) }
        if settings.hapticFeedback {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        }

        var typed = false
        do {
            let typer = PasswordTyper()
            try vault.withPassword { secret in
                // Clear the field only on a retry; the first attempt types into a fresh field.
                try secret.withUnsafeBytes { try typer.typeAndReturn($0, clearFirst: isRetry) }
            }
            typed = true
            didTypeThisLock = true
        } catch {
            didTypeThisLock = false
        }

        // Give the login a moment to accept the password. Only if it's STILL locked
        // afterwards do we try once more (with a field-clear) — never type twice in a
        // row into a working login, which would corrupt a correct password.
        let wait = typed ? 3000 : 900
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(wait))
            guard !Task.isCancelled, let self, self.isEnabled else { return }
            self.retryTask = nil
            if !ScreenLockState.isLocked {
                self.stopScanning()
                self.phase = .idle
                return
            }
            self.didTypeThisLock = false
            // One safety retry always; a second only if the user asked for auto retry.
            if self.typeAttempts < (self.settings.autoRetryOnce ? 3 : 2) {
                self.startAttempt()
            } else {
                self.awaitingRetry = true
                if self.settings.showAnimation { self.overlay.show(.rejected) }
            }
        }
    }

    /// Manual retry from the pop-up (shown on the desktop; on the real lock screen the
    /// automatic re-scan above does the same job, since no window can draw over it).
    func retry() {
        guard isEnabled, ScreenLockState.isLocked, !didTypeThisLock else { return }
        awaitingRetry = false
        typeAttempts = 0
        startAttempt()
    }

    /// Last line of defence for the camera light. Whatever path leaves the camera on,
    /// this notices within a second or two and shuts it down — the camera has no reason
    /// to be powered while the screen is unlocked or while we aren't scanning.
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.checkHoverRetry()
                guard let camera = self.camera, camera.isRunning else { return }
                let shouldBeOn = self.isEnabled && self.scanning
                    && ScreenLockState.isLocked && ScreenLockState.isOnConsole
                // Out of time: give up this attempt so the camera goes off rather than
                // staying on indefinitely. Hover or the space bar can ask for another.
                if self.scanning, let deadline = self.scanDeadline, deadline < Date() {
                    self.scanDeadline = nil
                    self.awaitingRetry = true
                    self.stopScanning()
                    if self.settings.showAnimation { self.overlay.show(.rejected) }
                    return
                }
                if shouldBeOn {
                    // Say "still needed" — stop saying it and the reaper takes the
                    // camera down on its own within a second.
                    camera.renewLease()
                } else {
                    self.scanning = false
                    camera.teardown()
                    self.overlay.hide()
                    if self.phase != .idle, !ScreenLockState.isLocked { self.phase = .idle }
                }
            }
        }
    }

    /// "Retry on hover": once a scan has given up, moving the pointer up to where the
    /// overlay sits asks for another one. Read by polling the cursor rather than with an
    /// event monitor, since the lock screen delivers us no mouse events.
    private func checkHoverRetry() {
        guard settings.retryOnHover, awaitingRetry, isEnabled,
              ScreenLockState.isLocked, ScreenLockState.isOnConsole,
              let screen = NSScreen.main else { return }
        let point = NSEvent.mouseLocation
        let hotspot = NSRect(x: screen.frame.midX - 140, y: screen.frame.maxY - 120,
                             width: 280, height: 120)
        if hotspot.contains(point) { retry() }
    }

    private func stopScanning() {
        scanning = false
        scanDeadline = nil
        camera?.teardown() // full release so the in-use indicator clears at once
        overlay.hide()
    }
}
