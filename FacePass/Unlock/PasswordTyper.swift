import ApplicationServices
import CoreGraphics
import Foundation

enum TypeError: LocalizedError {
    case notPermitted
    case notLocked
    case interrupted

    var errorDescription: String? {
        switch self {
        case .notPermitted: return "Accessibility permission is off. Turn it on in System Settings → Privacy & Security → Accessibility."
        case .notLocked: return "The lock screen isn't showing, so nothing was typed."
        case .interrupted: return "The Mac unlocked while typing; stopped so the password can't leak."
        }
    }
}

/// Types the password into the lock-screen field via HID-level key events, the only
/// way a third-party app can fill it. Safety-first: re-checks the lock state before
/// every keystroke and stops the instant the Mac is no longer locked-on-console,
/// so characters can never spill into a desktop app.
struct PasswordTyper {
    /// A no-op sink for a dry run: verifies gating and timing without posting keys.
    var post: (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }
    var perKeyDelay: useconds_t = 12_000

    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Types each character then Return. `bytes` is UTF-8 and is never copied into a String.
    /// `clearFirst` erases the field before typing — used only on a retry, never on the
    /// first attempt (the fresh field is empty and Cmd-based clearing can disturb the
    /// login window).
    func typeAndReturn(_ bytes: UnsafeRawBufferPointer, clearFirst: Bool = false) throws {
        guard PasswordTyper.hasAccessibilityPermission else { throw TypeError.notPermitted }
        guard confirmedLockedOnConsole() else { throw TypeError.notLocked }
        guard let source = CGEventSource(stateID: .hidSystemState) else { throw TypeError.notPermitted }

        if clearFirst { clearField(source: source) }

        for scalar in String(decoding: bytes, as: UTF8.self).unicodeScalars where scalar.value <= 0xFFFF {
            // A single stray "not locked" reading during the login transition is ignored;
            // we only abort if it stays not-locked, so typing isn't cut off half-way.
            guard confirmedLockedOnConsole() else { throw TypeError.interrupted }
            var unit = UInt16(scalar.value)
            try postKey(source: source) { $0.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit) }
        }
        guard confirmedLockedOnConsole() else { throw TypeError.interrupted }
        try postKey(source: source, virtualKey: 0x24) // Return
    }

    private var isLockedOnConsole: Bool {
        ScreenLockState.isLocked && ScreenLockState.isOnConsole
    }

    /// Debounced check: a momentary false reading is re-checked before we believe it.
    private func confirmedLockedOnConsole() -> Bool {
        if isLockedOnConsole { return true }
        usleep(6_000)
        return isLockedOnConsole
    }

    /// Clears leftover text with plain backspaces (no modifier keys, which can stick on
    /// the login window). Enough presses to empty a long password.
    private func clearField(source: CGEventSource) {
        for _ in 0..<64 { try? postKey(source: source, virtualKey: 0x33) } // Delete (backspace)
    }

    private func postKey(source: CGEventSource, virtualKey: CGKeyCode = 0,
                         flags: CGEventFlags = [], configure: (CGEvent) -> Void = { _ in }) throws {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false) else {
            throw TypeError.notPermitted
        }
        if !flags.isEmpty { down.flags = flags; up.flags = flags }
        configure(down)
        configure(up)
        post(down)
        usleep(perKeyDelay)
        post(up)
        usleep(perKeyDelay)
    }
}
