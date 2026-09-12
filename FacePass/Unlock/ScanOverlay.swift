import AppKit
import SwiftUI

/// FacePass's lock-screen indicator: a panel that hangs off the notch (or, on a Mac
/// without one, a floating pill just below the menu bar) showing a Face ID–style scan
/// mark. Lifted over the lock screen via SkyLight.
///
/// Deliberately silent — no title, no buttons, nothing to read. It appears while we're
/// looking for you and disappears the instant the Mac unlocks. Anything clickable
/// sitting over a lock screen would be a liability, so it never takes mouse events.
@MainActor
final class ScanOverlayController {
    enum State: Equatable {
        case scanning
        case matched
        case rejected
    }

    private var panel: NSPanel?
    private let model = ScanOverlayModel()
    private let skyLight = SkyLightOverlay()
    private var liftedAboveLockScreen = false
    private let settings = FacePassSettings.shared

    func show(_ state: State) {
        model.state = state
        model.metrics = NotchMetrics.current(style: settings.animationStyle)
        if panel == nil { makePanel() }
        panel?.ignoresMouseEvents = true
        positionPanel()
        panel?.orderFrontRegardless()

        if let panel, ScreenLockState.isLocked, !liftedAboveLockScreen {
            skyLight?.present(panel)
            liftedAboveLockScreen = true
        }
    }

    func hide() {
        if liftedAboveLockScreen {
            skyLight?.dismiss()
            liftedAboveLockScreen = false
        }
        panel?.orderOut(nil)
    }

    private func makePanel() {
        let hosting = NSHostingView(rootView: ScanOverlayView(model: model))
        hosting.frame = NSRect(origin: .zero, size: model.metrics.panelSize)
        let panel = NSPanel(contentRect: hosting.frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // The notch style has to read as part of the hardware, so it must not cast the
        // shadow a floating window would. The detached pill still does.
        panel.hasShadow = !model.metrics.hasNotch
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = hosting
        self.panel = panel
    }

    /// The screen the user pinned the overlay to, or whichever is main.
    private var targetScreen: NSScreen? {
        guard let id = settings.preferredDisplayID else { return NSScreen.main }
        let match = NSScreen.screens.first {
            ($0.deviceDescription[.init("NSScreenNumber")] as? NSNumber)?.stringValue == id
        }
        return match ?? NSScreen.main
    }

    private func positionPanel() {
        guard let panel, let screen = targetScreen else { return }
        let metrics = model.metrics
        panel.setContentSize(metrics.panelSize)
        let size = metrics.panelSize
        let x = screen.frame.midX - size.width / 2
        // The notch style starts flush with the physical top edge so the drawn body
        // continues the cutout; the pill hangs below the menu bar instead.
        let y = metrics.hasNotch
            ? screen.frame.maxY - size.height
            : screen.frame.maxY - size.height - NotchMetrics.pillTopGap
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// Where the panel sits and how wide the hardware cutout is.
struct NotchMetrics: Equatable {
    var style: FacePassSettings.AnimationStyle = .badge
    var hasNotch: Bool
    /// Width of the physical cutout, so the drawn body lines up with it exactly.
    var notchWidth: CGFloat
    /// Height of the cutout; our drawing must clear it before showing anything.
    var notchHeight: CGFloat

    static let pillTopGap: CGFloat = 6
    static let bodyHeight: CGFloat = 86
    /// Sideways room for the flare curving out of the cutout's lower corners.
    static let flare: CGFloat = 14
    static let pillWidth: CGFloat = 126

    /// Minimal style: the notch itself grows sideways, Dynamic Island–style. Content
    /// sits in these side panels; the middle is the physical cutout, where nothing may
    /// be drawn because the hardware covers it.
    static let minimalSideWidth: CGFloat = 74
    /// How much taller than the cutout the grown bar is, so the growth is visible.
    static let minimalGrow: CGFloat = 6
    /// Fallback bar for Macs with no notch — a free-floating capsule.
    static let minimalPillSize = CGSize(width: 168, height: 34)

    var minimalSize: CGSize {
        hasNotch
            ? CGSize(width: notchWidth + NotchMetrics.minimalSideWidth * 2,
                     height: notchHeight + NotchMetrics.minimalGrow)
            : NotchMetrics.minimalPillSize
    }

    var panelSize: CGSize {
        if style == .minimal { return minimalSize }
        return hasNotch
            ? CGSize(width: notchWidth + NotchMetrics.flare * 2, height: notchHeight + NotchMetrics.bodyHeight)
            : CGSize(width: NotchMetrics.pillWidth, height: NotchMetrics.bodyHeight)
    }

    static func current(style: FacePassSettings.AnimationStyle = .badge) -> NotchMetrics {
        let none = NotchMetrics(style: style, hasNotch: false, notchWidth: 0, notchHeight: 0)
        guard let screen = NSScreen.main else { return none }
        // A notched Mac reports a top safe-area inset and splits the menu bar into a
        // left and a right area; the gap between them is the cutout.
        let inset = screen.safeAreaInsets.top
        guard inset > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea,
              right.minX > left.maxX else { return none }
        return NotchMetrics(style: style, hasNotch: true,
                            notchWidth: right.minX - left.maxX, notchHeight: inset)
    }
}

@MainActor
final class ScanOverlayModel: ObservableObject {
    @Published var state: ScanOverlayController.State = .scanning
    @Published var metrics = NotchMetrics(hasNotch: false, notchWidth: 0, notchHeight: 0)
}

/// A drawn padlock whose shackle actually swings open, rather than one symbol being
/// swapped for another. While we're looking it breathes gently; on a match the shackle
/// lifts and tilts on its right leg with a spring, the way a real one would fall open.
private struct LockGlyph: View {
    let state: ScanOverlayController.State

    @State private var breathe = false
    @State private var open = false

    private var isOpen: Bool { state == .matched }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let bodyH = h * 0.52
            let shackleH = h * 0.46
            let shackleW = w * 0.62
            let line = w * 0.13

            ZStack(alignment: .bottom) {
                // Shackle. Its anchor is the bottom-RIGHT leg, so opening swings the
                // left leg up and out — the same motion as a padlock falling open.
                Shackle()
                    .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .frame(width: shackleW, height: shackleH)
                    .offset(y: -(bodyH - line * 0.5))
                    .rotationEffect(.degrees(open ? -26 : 0),
                                    anchor: UnitPoint(x: 0.92, y: 1))
                    .offset(y: open ? -h * 0.10 : 0)

                RoundedRectangle(cornerRadius: w * 0.22, style: .continuous)
                    .fill(tint)
                    .frame(width: w * 0.86, height: bodyH)
            }
            .frame(width: w, height: h, alignment: .bottom)
            // Only the body pulses while scanning; a shackle that breathes looks loose.
            .scaleEffect(breathe && !isOpen ? 1.05 : 1, anchor: .bottom)
            .shadow(color: tint.opacity(isOpen ? 0.5 : 0), radius: 5)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { breathe = true }
        }
        .onChange(of: isOpen) { _, nowOpen in
            withAnimation(.spring(response: 0.36, dampingFraction: 0.55)) { open = nowOpen }
        }
    }

    private var tint: Color {
        switch state {
        case .scanning: return .white
        case .matched: return Color(red: 0.20, green: 0.84, blue: 0.46)
        case .rejected: return Color(red: 1.0, green: 0.40, blue: 0.40)
        }
    }
}

/// The padlock's shackle: an upside-down U, open at the bottom.
private struct Shackle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = rect.width / 2
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addArc(center: CGPoint(x: rect.midX, y: rect.minY + radius),
                    radius: radius,
                    startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }
}

/// Widens out of the cutout on appear and shrinks back into it on the way out, so the
/// bar reads as the notch itself stretching rather than as a panel fading in.
private struct GrowFromNotch: ViewModifier {
    let metrics: NotchMetrics
    @State private var grown = false

    func body(content: Content) -> some View {
        let collapsed = metrics.hasNotch
            ? metrics.notchWidth / max(metrics.minimalSize.width, 1)
            : 0.35
        return content
            .scaleEffect(x: grown ? 1 : collapsed, y: 1, anchor: .center)
            .opacity(grown ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { grown = true }
            }
    }
}

/// The grown notch: a bar hanging from the top edge whose bottom corners are fully
/// rounded and whose top corners flare outward, so it reads as the hardware cutout
/// stretching sideways rather than as a window sitting on top of it.
private struct MinimalBarShape: Shape {
    let metrics: NotchMetrics

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard metrics.hasNotch else {
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: rect.height / 2, height: rect.height / 2),
                                style: .continuous)
            return path
        }

        let bottomRadius = min(rect.height / 2, 18)

        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: rect.height - bottomRadius))
        path.addQuadCurve(to: CGPoint(x: bottomRadius, y: rect.height),
                          control: CGPoint(x: 0, y: rect.height))
        path.addLine(to: CGPoint(x: rect.width - bottomRadius, y: rect.height))
        path.addQuadCurve(to: CGPoint(x: rect.width, y: rect.height - bottomRadius),
                          control: CGPoint(x: rect.width, y: rect.height))
        path.addLine(to: CGPoint(x: rect.width, y: 0))
        path.closeSubpath()
        return path
    }
}

/// The silhouette: a body hanging below the notch whose top corners curve outward into
/// the cutout, so hardware notch and drawn panel read as a single shape.
private struct NotchSilhouette: Shape {
    let metrics: NotchMetrics

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard metrics.hasNotch else {
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: 24, height: 24), style: .continuous)
            return path
        }

        let flare = NotchMetrics.flare
        let top = metrics.notchHeight
        let bottomRadius: CGFloat = 22
        let bodyMinX = flare
        let bodyMaxX = rect.width - flare

        // Left flare: down the screen edge, then curving in to meet the body.
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: top - flare))
        path.addQuadCurve(to: CGPoint(x: bodyMinX, y: top),
                          control: CGPoint(x: flare * 0.15, y: top))

        // Down the body's left side and around its generously rounded bottom.
        path.addLine(to: CGPoint(x: bodyMinX, y: rect.height - bottomRadius))
        path.addQuadCurve(to: CGPoint(x: bodyMinX + bottomRadius, y: rect.height),
                          control: CGPoint(x: bodyMinX, y: rect.height))
        path.addLine(to: CGPoint(x: bodyMaxX - bottomRadius, y: rect.height))
        path.addQuadCurve(to: CGPoint(x: bodyMaxX, y: rect.height - bottomRadius),
                          control: CGPoint(x: bodyMaxX, y: rect.height))

        // Back up the right side and out through the mirrored flare.
        path.addLine(to: CGPoint(x: bodyMaxX, y: top))
        path.addQuadCurve(to: CGPoint(x: rect.width, y: top - flare),
                          control: CGPoint(x: rect.width - flare * 0.15, y: top))
        path.addLine(to: CGPoint(x: rect.width, y: 0))
        path.closeSubpath()
        return path
    }
}

private struct ScanOverlayView: View {
    @ObservedObject var model: ScanOverlayModel

    var body: some View {
        let metrics = model.metrics
        if metrics.style == .minimal {
            minimal
        } else {
            badge(metrics)
        }
    }

    /// The notch grows sideways, the way the Dynamic Island does: a lock appears to the
    /// LEFT of the cutout and the scan mark to its RIGHT. Nothing is ever drawn in the
    /// middle — that is the physical camera housing, and anything there is simply hidden
    /// behind it.
    private var minimal: some View {
        minimalBar.modifier(GrowFromNotch(metrics: model.metrics))
    }

    private var minimalBar: some View {
        let metrics = model.metrics
        let size = metrics.minimalSize
        let side = metrics.hasNotch ? NotchMetrics.minimalSideWidth : size.width / 2

        return HStack(spacing: 0) {
            LockGlyph(state: model.state)
                .frame(width: 18, height: 22)
                .frame(width: side)

            // The cutout. Empty by necessity on a notched Mac; zero-width elsewhere.
            if metrics.hasNotch { Color.clear.frame(width: metrics.notchWidth) }

            FaceScanMark(state: model.state, compact: true)
                .frame(width: 23, height: 23)
                .frame(width: side)
        }
        .frame(width: size.width, height: size.height)
        .background(MinimalBarShape(metrics: metrics).fill(Color.black))
        .animation(.smooth(duration: 0.3), value: model.state)
    }

    private func badge(_ metrics: NotchMetrics) -> some View {
        ZStack(alignment: .bottom) {
            NotchSilhouette(metrics: metrics)
                .fill(metrics.hasNotch ? AnyShapeStyle(Color.black) : AnyShapeStyle(.ultraThinMaterial))

            FaceScanMark(state: model.state)
                .frame(width: 44, height: 44)
                .padding(.bottom, 20)
        }
        .frame(width: metrics.panelSize.width, height: metrics.panelSize.height)
    }
}

/// A Face ID–style mark. While scanning: corner brackets around a face with a sweeping
/// scan line. On a result the brackets contract away and the tick (or cross) *draws
/// itself* stroke-by-stroke inside a ring that springs open — the same beat as Face ID
/// on iPhone, rather than a symbol appearing all at once.
private struct FaceScanMark: View {
    let state: ScanOverlayController.State
    /// Set on the slim bar. At ~23pt a sweeping band is just a smudge, so the compact
    /// mark breathes as a whole instead of animating a line across itself.
    var compact = false

    @State private var sweep: CGFloat = 0
    @State private var resultProgress: CGFloat = 0
    @State private var ringScale: CGFloat = 0.55
    @State private var ringOpacity: Double = 0
    @State private var shake: CGFloat = 0
    @State private var breathe = false

    private var isResult: Bool { state != .scanning }

    var body: some View {
        ZStack {
            scanningLayer
                .opacity(isResult ? 0 : 1)
                .scaleEffect(isResult ? 0.82 : 1)
                .blur(radius: isResult ? 2 : 0)

            resultLayer
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.8), value: isResult)
        .onAppear { startSweep() }
        .onChange(of: state) { _, newValue in
            newValue == .scanning ? startSweep() : playResult(for: newValue)
        }
    }

    // MARK: - Scanning

    private var scanningLayer: some View {
        GeometryReader { geo in
            let unit = geo.size.width / 44
            ZStack {
                Brackets().stroke(tint, style: StrokeStyle(lineWidth: 2.4 * unit, lineCap: .round))
                FaceGlyph()
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.1 * unit,
                                                     lineCap: .round, lineJoin: .round))
                    .padding(9 * unit)
                    .overlay(compact ? nil : AnyView(scanLine.padding(6 * unit)))
            }
            .opacity(compact ? (breathe ? 1 : 0.45) : 1)
            .shadow(color: compact ? tint.opacity(0.45) : .clear, radius: 3)
        }
    }

    /// The sweeping highlight, drawn as a soft band so it reads as a scan, not a wipe.
    private var scanLine: some View {
        GeometryReader { geo in
            LinearGradient(colors: [tint.opacity(0), tint.opacity(0.9), tint.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 9)
                .blur(radius: 2)
                .offset(y: (geo.size.height - 9) * sweep)
        }
        .allowsHitTesting(false)
    }

    private func startSweep() {
        resultProgress = 0
        ringScale = 0.55
        ringOpacity = 0
        sweep = 0
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { sweep = 1 }
        withAnimation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true)) { breathe = true }
    }

    // MARK: - Result

    private var resultLayer: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                // A soft halo behind the ring, so the result reads even on a black bar.
                Circle()
                    .fill(tint.opacity(0.18))
                    .frame(width: side, height: side)

                Circle()
                    .strokeBorder(tint, lineWidth: side * 0.07)
                    .frame(width: side, height: side)

                ResultStroke(isTick: state == .matched)
                    .trim(from: 0, to: resultProgress)
                    .stroke(tint, style: StrokeStyle(lineWidth: side * 0.09,
                                                     lineCap: .round, lineJoin: .round))
                    .frame(width: side * 0.52, height: side * 0.52)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .scaleEffect(ringScale)
            .opacity(ringOpacity)
            .offset(x: shake)
        }
    }

    private func playResult(for state: ScanOverlayController.State) {
        resultProgress = 0
        ringScale = 0.55
        ringOpacity = 0
        // The ring springs open first, then the stroke draws into it — never together,
        // or the two motions read as one blur.
        withAnimation(.spring(response: 0.30, dampingFraction: 0.62)) {
            ringScale = 1
            ringOpacity = 1
        }
        withAnimation(.easeOut(duration: 0.26).delay(0.10)) { resultProgress = 1 }

        guard state != .matched else { return }
        // A short side-to-side nudge for a rejection, the way a wrong passcode shakes.
        for (index, offset) in [-5.0, 5.0, -3.0, 3.0, 0.0].enumerated() {
            withAnimation(.easeInOut(duration: 0.06).delay(0.24 + Double(index) * 0.06)) {
                shake = offset
            }
        }
    }

    private var tint: Color {
        switch state {
        case .scanning: return Color(red: 0.30, green: 0.68, blue: 1.0)
        case .matched: return Color(red: 0.20, green: 0.84, blue: 0.46)
        case .rejected: return Color(red: 1.0, green: 0.40, blue: 0.40)
        }
    }
}

/// The tick or the cross, as a single trimmable path so it can draw itself on.
/// The cross is one continuous stroke (down-right, lift, down-left) for the same reason.
private struct ResultStroke: Shape {
    let isTick: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if isTick {
            path.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.04))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.06))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        return path
    }
}

/// Four corner brackets, like the Face ID frame.
private struct Brackets: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius: CGFloat = 11
        let arm = rect.width * 0.28

        path.move(to: CGPoint(x: rect.minX, y: rect.minY + radius + arm))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY),
                          control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + radius + arm, y: rect.minY))

        path.move(to: CGPoint(x: rect.maxX - radius - arm, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + radius),
                          control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + radius + arm))

        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - radius - arm))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - radius - arm, y: rect.maxY))

        path.move(to: CGPoint(x: rect.minX + radius + arm, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius - arm))
        return path
    }
}

/// Eyes, nose and a mouth — reads as a face at 44pt and keeps FacePass's smiley brand.
private struct FaceGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let eyeY = rect.minY + rect.height * 0.24
        let eyeDrop = rect.height * 0.17
        for x in [rect.minX + rect.width * 0.24, rect.maxX - rect.width * 0.24] {
            path.move(to: CGPoint(x: x, y: eyeY))
            path.addLine(to: CGPoint(x: x, y: eyeY + eyeDrop))
        }
        let noseX = rect.midX
        path.move(to: CGPoint(x: noseX, y: rect.minY + rect.height * 0.34))
        path.addLine(to: CGPoint(x: noseX, y: rect.minY + rect.height * 0.58))
        path.addLine(to: CGPoint(x: noseX + rect.width * 0.11, y: rect.minY + rect.height * 0.58))

        path.move(to: CGPoint(x: rect.minX + rect.width * 0.26, y: rect.maxY - rect.height * 0.20))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - rect.width * 0.26, y: rect.maxY - rect.height * 0.20),
                          control: CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.02))
        return path
    }
}
