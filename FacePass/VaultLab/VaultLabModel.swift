import Foundation

/// Drives the Vault Lab window, which proves on real hardware that the password
/// vault works — including while the screen is locked. The password is never shown.
@MainActor
final class VaultLabModel: ObservableObject {
    struct LogEntry: Identifiable {
        let id = UUID()
        let date: Date
        let message: String
        let succeeded: Bool
    }

    @Published private(set) var isSetUp = false
    @Published private(set) var isArmed = false
    @Published private(set) var armedAt: Date?
    @Published private(set) var isBusy = false
    @Published private(set) var isLockTestRunning = false
    @Published private(set) var log: [LogEntry] = []

    private let vault = PasswordVault.shared
    private var lockTestTask: Task<Void, Never>?

    init() {
        refresh()
    }

    func setUp(password: String) {
        isBusy = true
        defer { isBusy = false; refresh() }
        do {
            try vault.setUp(password: password)
            record("Password checked with macOS and sealed to the Secure Enclave", succeeded: true)
        } catch {
            record("Setup failed — \(describe(error))", succeeded: false)
        }
    }

    func arm() async {
        isBusy = true
        defer { isBusy = false; refresh() }
        do {
            try await vault.arm(reason: "turn on FacePass face unlock")
            record("Armed with Touch ID", succeeded: true)
        } catch {
            record("Arming failed — \(describe(error))", succeeded: false)
        }
    }

    func disarm() {
        vault.disarm()
        record("Disarmed", succeeded: true)
        refresh()
    }

    func deleteVault() {
        lockTestTask?.cancel()
        do {
            try vault.delete()
            record("Vault deleted from the keychain", succeeded: true)
        } catch {
            record("Delete failed — \(describe(error))", succeeded: false)
        }
        refresh()
    }

    func testDecryptNow() {
        record(decryptCheck(label: "Unlocked screen"))
    }

    /// Waits for the screen to lock, then decrypts while locked and logs the result.
    func startLockTest() {
        lockTestTask?.cancel()
        isLockTestRunning = true
        record("Lock test started — press Control-Command-Q to lock, wait 10 seconds, then log back in", succeeded: true)

        lockTestTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(120)
            while !ScreenLockState.isLocked {
                if Task.isCancelled || Date() > deadline {
                    self?.finishLockTest(LogEntry(date: Date(), message: "Lock test stopped — the screen never locked", succeeded: false))
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled else { return }
            let locked = ScreenLockState.isLocked
            self.finishLockTest(self.decryptCheck(label: locked ? "Locked screen" : "Screen already unlocked (test inconclusive)"))
        }
    }

    private func finishLockTest(_ entry: LogEntry) {
        isLockTestRunning = false
        record(entry)
    }

    /// Decrypts with the armed context and confirms the result still matches the account password.
    /// Lab-only: the comparison briefly creates a String copy of the password.
    private func decryptCheck(label: String) -> LogEntry {
        do {
            let matches = try vault.withPassword { secret in
                secret.withUnsafeBytes { AccountPassword.isCorrect(String(decoding: $0, as: UTF8.self)) }
            }
            let message = matches
                ? "\(label): decrypted with no prompt and it matches your Mac password (\(elapsedSinceArming))"
                : "\(label): decrypted, but it no longer matches your Mac password — set up again"
            return LogEntry(date: Date(), message: message, succeeded: matches)
        } catch {
            return LogEntry(date: Date(), message: "\(label): decrypt failed — \(describe(error))", succeeded: false)
        }
    }

    private var elapsedSinceArming: String {
        guard let armedAt else { return "not armed" }
        let minutes = Int(Date().timeIntervalSince(armedAt) / 60)
        return minutes < 1 ? "armed under a minute ago" : "armed \(minutes) min ago"
    }

    private func refresh() {
        isSetUp = vault.isSetUp
        isArmed = vault.isArmed
        armedAt = vault.armedAt
    }

    private func record(_ message: String, succeeded: Bool) {
        record(LogEntry(date: Date(), message: message, succeeded: succeeded))
    }

    private func record(_ entry: LogEntry) {
        log.insert(entry, at: 0)
    }

    private func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(error.localizedDescription) [\(nsError.domain) \(nsError.code)]"
    }
}
