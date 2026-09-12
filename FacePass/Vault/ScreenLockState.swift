import CoreGraphics

/// Reads the window server's session state. Unlike lock/unlock notifications,
/// other processes can't fake this, so it is the only lock check used as a gate.
enum ScreenLockState {
    static var isLocked: Bool {
        (session?["CGSSessionScreenIsLocked"] as? Bool) == true
    }

    /// False when another user is active through fast user switching.
    static var isOnConsole: Bool {
        (session?[kCGSessionOnConsoleKey] as? Bool) == true
    }

    private static var session: [String: Any]? {
        CGSessionCopyCurrentDictionary() as? [String: Any]
    }
}
