import Foundation
import IOKit.hid

/// Watches for the space bar at the lock screen, so a scan can be asked for on purpose
/// instead of only happening by itself.
///
/// It has to read the keyboard through IOKit HID: Secure Event Input is active at the
/// lock screen, which suppresses every ordinary event tap. FacePass doesn't appear
/// under Input Monitoring because TCC satisfies that gate from Accessibility, which we
/// already require in order to type the password.
///
/// This is not a keylogger: it runs only while the screen is locked and only while the
/// user has opted into "On space", and the callback looks at nothing except whether the
/// key that went down was the space bar. Nothing is recorded or stored.
///
/// Approach adapted from Glance (MIT, © Jonathan Zhou).
@MainActor
final class SpaceKeyMonitor {
    /// Fires on key-down only — not release, not auto-repeat.
    var onSpaceKeyDown: (() -> Void)?

    private var manager: IOHIDManager?

    /// True whenever the HID read is permitted. Never prompts; in practice this tracks
    /// Accessibility, which FacePass already needs.
    static var hasAccess: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Idempotent. Fails closed — if HID can't be opened, the space trigger simply
    /// doesn't work rather than taking the rest of the unlock path down with it.
    func start() {
        guard manager == nil else { return }

        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Physical keyboards only, not every HID device on the machine.
        let match: [String: Int] = [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard,
        ]
        IOHIDManagerSetDeviceMatching(mgr, match as CFDictionary)

        // The callback can't capture, so `self` rides through the context pointer.
        // Unretained is safe because `stop()` always runs before this object goes away.
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(mgr, { context, _, _, value in
            guard let context else { return }
            let element = IOHIDValueGetElement(value)
            guard IOHIDElementGetUsagePage(element) == UInt32(kHIDPage_KeyboardOrKeypad),
                  IOHIDElementGetUsage(element) == UInt32(kHIDUsage_KeyboardSpacebar),
                  IOHIDValueGetIntegerValue(value) == 1
            else { return }
            let monitor = Unmanaged<SpaceKeyMonitor>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in monitor.onSpaceKeyDown?() }
        }, context)

        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        guard IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            return
        }
        manager = mgr
    }

    /// Stops listening. Idempotent, and always called on unlock so we hold no keyboard
    /// access at all while the Mac is in use.
    func stop() {
        guard let mgr = manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = nil
    }
}
