import Combine
import Foundation
import LocalAuthentication

/// Ties the whole app together for the menu bar: setup state, the one Touch ID
/// "arm", and the automatic unlocker. This is the real product path; the Lab
/// windows remain for testing individual pieces.
@MainActor
final class AppController: ObservableObject {
    let unlocker = UnlockController()

    @Published private(set) var isEnrolled = false
    @Published private(set) var isPasswordSet = false
    @Published private(set) var isArmed = false
    @Published private(set) var hasAccessibility = false
    @Published private(set) var automaticUnlockOn = false
    @Published private(set) var busy = false
    @Published private(set) var lastError: String?

    private let vault = PasswordVault.shared
    private let templates = FaceTemplateStore.shared
    private var cancellable: AnyCancellable?
    private var pollTimer: Timer?

    init() {
        refresh()
        cancellable = unlocker.$isEnabled.sink { [weak self] on in self?.automaticUnlockOn = on }
        // The vault and face can be set up from the Lab windows, so keep the menu in sync.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var isFullyReady: Bool {
        isEnrolled && isPasswordSet && isArmed && hasAccessibility
    }

    /// One-line status for the menu bar.
    var statusLine: String {
        if !isEnrolled { return "Set up needed — enrol your face" }
        if !isPasswordSet { return "Set up needed — save your password" }
        if !hasAccessibility { return "Turn on Accessibility permission" }
        if !isArmed { return "Locked — arm with Touch ID" }
        return automaticUnlockOn ? "On — your face unlocks this Mac" : "Ready — turn on automatic unlock"
    }

    func refresh() {
        isEnrolled = templates.isEnrolled
        isPasswordSet = vault.isSetUp
        isArmed = vault.isArmed
        hasAccessibility = PasswordTyper.hasAccessibilityPermission
    }

    /// The single Touch ID step that turns FacePass on for this login session.
    func armAndEnable() async {
        busy = true
        lastError = nil
        defer { busy = false; refresh() }
        do {
            if !vault.isArmed {
                try await vault.arm(reason: "turn on FacePass face unlock")
            }
            unlocker.enable()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func turnOff() {
        unlocker.disable()
        vault.disarm()
        refresh()
    }

    func requestAccessibility() {
        AccessibilityPermission.prompt()
    }
}
