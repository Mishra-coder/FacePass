import AppKit

/// Places a window ABOVE the macOS lock screen. This is the only way to show a
/// pop-up over the login window, and it needs Apple's private SkyLight framework —
/// the same approach Glance uses. It is loaded dynamically and every symbol is
/// optional, so if a future macOS removes or changes it, FacePass keeps working
/// (the automatic unlock doesn't depend on this — only the on-lock-screen visual does).
@MainActor
final class SkyLightOverlay {
    private typealias MainConnFn = @convention(c) () -> Int32
    private typealias SpaceCreateFn = @convention(c) (Int32, Int32, Int32) -> UInt64
    private typealias SetLevelFn = @convention(c) (Int32, UInt64, Int32) -> Void
    private typealias SpacesFn = @convention(c) (Int32, CFArray) -> Void
    private typealias AddWindowsFn = @convention(c) (Int32, UInt64, CFArray, Int32) -> Void
    private typealias DestroyFn = @convention(c) (Int32, UInt64) -> Void

    private let cid: Int32
    private let spaceCreate: SpaceCreateFn
    private let setLevel: SetLevelFn
    private let showSpaces: SpacesFn
    private let hideSpaces: SpacesFn
    private let addWindows: AddWindowsFn
    private let destroySpace: DestroyFn

    private var space: UInt64 = 0

    /// The lock screen (the login window's shield) sits high; this level places our
    /// window just above it. Matches the value Glance uses.
    private let aboveLockScreenLevel: Int32 = 400

    init?() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW) else {
            return nil
        }
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }
        guard let mainConn = symbol("SLSMainConnectionID", MainConnFn.self),
              let create = symbol("SLSSpaceCreate", SpaceCreateFn.self),
              let level = symbol("SLSSpaceSetAbsoluteLevel", SetLevelFn.self),
              let show = symbol("SLSShowSpaces", SpacesFn.self),
              let hide = symbol("SLSHideSpaces", SpacesFn.self),
              let add = symbol("SLSSpaceAddWindowsAndRemoveFromSpaces", AddWindowsFn.self),
              let destroy = symbol("SLSSpaceDestroy", DestroyFn.self) else {
            return nil
        }
        cid = mainConn()
        spaceCreate = create
        setLevel = level
        showSpaces = show
        hideSpaces = hide
        addWindows = add
        destroySpace = destroy
    }

    /// Lifts `window` into a private space rendered above the lock screen.
    func present(_ window: NSWindow) {
        let windowID = UInt32(max(window.windowNumber, 0))
        guard windowID != 0 else { return }
        if space == 0 { space = spaceCreate(cid, 1, 0) }
        setLevel(cid, space, aboveLockScreenLevel)
        let windows = [NSNumber(value: windowID)] as CFArray
        addWindows(cid, space, windows, 7) // 7 = move, removing from other spaces
        showSpaces(cid, [NSNumber(value: space)] as CFArray)
    }

    func dismiss() {
        guard space != 0 else { return }
        hideSpaces(cid, [NSNumber(value: space)] as CFArray)
        destroySpace(cid, space)
        space = 0
    }
}
