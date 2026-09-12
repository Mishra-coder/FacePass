import Combine
import Foundation
import ServiceManagement

/// User preferences that affect behaviour but not security. Security thresholds
/// (match, liveness, yaw) stay compiled in `UnlockPolicy`, never in UserDefaults,
/// so no other process can weaken them.
@MainActor
final class FacePassSettings: ObservableObject {
    static let shared = FacePassSettings()

    enum AnimationStyle: String, CaseIterable, Identifiable {
        case minimal, badge
        var id: String { rawValue }
        var title: String { self == .minimal ? "Minimal" : "Original" }
    }

    @Published var triggerOnLock: Bool { didSet { store.set(triggerOnLock, forKey: "triggerOnLock") } }
    @Published var triggerOnWake: Bool { didSet { store.set(triggerOnWake, forKey: "triggerOnWake") } }
    /// Scan when the space bar is pressed at the lock screen, so a scan can be asked
    /// for deliberately rather than only happening on its own.
    @Published var triggerOnSpace: Bool { didSet { store.set(triggerOnSpace, forKey: "triggerOnSpace") } }
    /// Moving the pointer up to the overlay asks for another scan.
    @Published var retryOnHover: Bool { didSet { store.set(retryOnHover, forKey: "retryOnHover") } }
    /// When off, a failed scan is final until asked again; when on, one automatic retry.
    @Published var autoRetryOnce: Bool { didSet { store.set(autoRetryOnce, forKey: "autoRetryOnce") } }
    /// A tap on the trackpad when the face is accepted.
    @Published var hapticFeedback: Bool { didSet { store.set(hapticFeedback, forKey: "hapticFeedback") } }
    /// Which screen shows the overlay. nil = whichever screen is currently main.
    @Published var preferredDisplayID: String? { didSet { store.set(preferredDisplayID, forKey: "preferredDisplayID") } }
    @Published var showAnimation: Bool { didSet { store.set(showAnimation, forKey: "showAnimation") } }
    @Published var animationStyle: AnimationStyle {
        didSet { store.set(animationStyle.rawValue, forKey: "animationStyle") }
    }
    /// How long to keep trying before giving up an attempt (seconds).
    @Published var detectionDuration: Double { didSet { store.set(detectionDuration, forKey: "detectionDuration") } }
    @Published var launchAtLogin: Bool { didSet { applyLaunchAtLogin() } }

    private let store = UserDefaults.standard

    init() {
        triggerOnLock = store.object(forKey: "triggerOnLock") as? Bool ?? true
        triggerOnWake = store.object(forKey: "triggerOnWake") as? Bool ?? true
        triggerOnSpace = store.object(forKey: "triggerOnSpace") as? Bool ?? true
        retryOnHover = store.object(forKey: "retryOnHover") as? Bool ?? true
        autoRetryOnce = store.object(forKey: "autoRetryOnce") as? Bool ?? false
        hapticFeedback = store.object(forKey: "hapticFeedback") as? Bool ?? true
        preferredDisplayID = store.string(forKey: "preferredDisplayID")
        showAnimation = store.object(forKey: "showAnimation") as? Bool ?? true
        animationStyle = AnimationStyle(rawValue: store.string(forKey: "animationStyle") ?? "") ?? .minimal
        detectionDuration = store.object(forKey: "detectionDuration") as? Double ?? 4
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            // Reflect the real state if the toggle couldn't be applied.
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
