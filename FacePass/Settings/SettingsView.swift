import SwiftUI

struct SettingsView: View {
    static let windowID = "settings"

    @ObservedObject var app: AppController
    @ObservedObject var settings: FacePassSettings
    @ObservedObject var face: FaceLabModel
    @ObservedObject var vault: VaultLabModel

    enum Pane: String, CaseIterable, Identifiable {
        case general = "General"
        case yourFace = "Your Face"
        case password = "Password"
        case recognition = "Recognition"
        case about = "About"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .yourFace: return "face.smiling"
            case .password: return "key.fill"
            case .recognition: return "sparkles"
            case .about: return "info.circle"
            }
        }
    }

    @State private var pane: Pane = .general

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { item in
                Label(item.rawValue, systemImage: item.icon).tag(item)
            }
            .navigationSplitViewColumnWidth(200)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    Circle().fill(app.automaticUnlockOn ? .green : .secondary).frame(width: 9, height: 9)
                    Text(app.automaticUnlockOn ? "Face unlock is on" : "Face unlock is off")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(12)
            }
        } detail: {
            ScrollView {
                Group {
                    switch pane {
                    case .general: GeneralPane(app: app, settings: settings)
                    case .yourFace: YourFacePane(app: app, face: face)
                    case .password: PasswordPane(app: app, vault: vault)
                    case .recognition: RecognitionPane()
                    case .about: AboutPane()
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(pane.rawValue)
        }
        .frame(width: 720, height: 560)
        .onAppear { app.refresh() }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var app: AppController
    @ObservedObject var settings: FacePassSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            card {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                Divider()
                Toggle("Enable face unlock", isOn: Binding(
                    get: { app.automaticUnlockOn },
                    set: { on in if on { Task { await app.armAndEnable() } } else { app.turnOff() } }
                ))
                .disabled(!(app.isEnrolled && app.isPasswordSet && app.hasAccessibility))
                Text(app.statusLine).font(.caption).foregroundStyle(.secondary)

                Divider()
                HStack(spacing: 12) {
                    TriggerTile(icon: "zzz", title: "On wake", isOn: $settings.triggerOnWake)
                    TriggerTile(icon: "lock.display", title: "On lock", isOn: $settings.triggerOnLock)
                    TriggerTile(icon: "space", title: "On space", isOn: $settings.triggerOnSpace)
                }
                .padding(.vertical, 2)

                Divider()
                HStack {
                    Text("Display on")
                    Spacer()
                    Picker("", selection: $settings.preferredDisplayID) {
                        Text("Main display").tag(String?.none)
                        ForEach(DisplayChoice.all, id: \.id) { choice in
                            Text(choice.name).tag(String?.some(choice.id))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            sectionTitle("Behaviour")
            card {
                Toggle("Retry on hover", isOn: $settings.retryOnHover)
                Text("Move the pointer to the top of the screen to ask for another scan.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Toggle("Auto retry once", isOn: $settings.autoRetryOnce)
                Divider()
                Toggle("Haptic feedback", isOn: $settings.hapticFeedback)
                Divider()
                HStack {
                    Text("Face detection duration")
                    Spacer()
                    Text("\(Int(settings.detectionDuration))s").foregroundStyle(.secondary)
                }
                Slider(value: $settings.detectionDuration, in: 3...10, step: 1)
            }

            sectionTitle("Animation")
            card {
                Toggle("Show animation", isOn: $settings.showAnimation)
                if settings.showAnimation {
                    HStack(spacing: 12) {
                        ForEach(FacePassSettings.AnimationStyle.allCases) { style in
                            AnimationStyleTile(style: style, selected: settings.animationStyle == style) {
                                settings.animationStyle = style
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }
}

/// One of the "when to scan" tiles: a big square that reads as selected or not.
private struct TriggerTile: View {
    let icon: String
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        VStack(spacing: 6) {
            Button { isOn.toggle() } label: {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(isOn ? Color.accentColor : .clear, lineWidth: 2)
                    )
            }
            .buttonStyle(.plain)
            Text(title).font(.caption).foregroundStyle(isOn ? .primary : .secondary)
        }
    }
}

/// A live miniature of each overlay look, so the choice is made by sight not by name.
private struct AnimationStyleTile: View {
    let style: FacePassSettings.AnimationStyle
    let selected: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Button(action: action) {
                ZStack {
                    switch style {
                    case .minimal:
                        Capsule().fill(.black)
                            .frame(height: 26)
                            .overlay(
                                HStack {
                                    Image(systemName: "lock.fill")
                                    Spacer()
                                    Image(systemName: "faceid")
                                }
                                .font(.caption2)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                            )
                            .padding(.horizontal, 18)
                    case .badge:
                        RoundedRectangle(cornerRadius: 12).fill(.black)
                            .frame(width: 52, height: 52)
                            .overlay(
                                Image(systemName: "faceid")
                                    .font(.title2)
                                    .foregroundStyle(Color(red: 0.30, green: 0.68, blue: 1.0))
                            )
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 86)
                .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2)
                )
            }
            .buttonStyle(.plain)
            Text(style.title).font(.caption).foregroundStyle(selected ? .primary : .secondary)
        }
    }
}

/// The screens the overlay can be pinned to.
private struct DisplayChoice {
    let id: String
    let name: String

    static var all: [DisplayChoice] {
        NSScreen.screens.enumerated().compactMap { index, screen in
            guard let number = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber else { return nil }
            return DisplayChoice(id: number.stringValue,
                                 name: screen.localizedName.isEmpty ? "Display \(index + 1)" : screen.localizedName)
        }
    }
}

// MARK: - Your Face

private struct YourFacePane: View {
    @ObservedObject var app: AppController
    @ObservedObject var face: FaceLabModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            card {
                HStack(spacing: 14) {
                    Image(systemName: app.isEnrolled ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.title)
                        .foregroundStyle(app.isEnrolled ? .green : .orange)
                    VStack(alignment: .leading) {
                        Text(app.isEnrolled ? "Your face is enrolled" : "No face enrolled yet")
                            .fontWeight(.medium)
                        Text("Only 128 numbers are stored — never a photo. Saved encrypted on this Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }

            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(.black)
                if let preview = face.preview {
                    Image(decorative: preview, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        .scaleEffect(x: -1, y: 1)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(height: 260)

            if face.isEnrolling {
                ProgressView(value: Double(face.enrolledSampleCount), total: Double(FaceLabModel.enrollmentTarget))
                Text(face.enrollmentHint).font(.callout).foregroundStyle(.secondary)
            } else {
                HStack {
                    Button(app.isEnrolled ? "Re-enrol my face" : "Enrol my face") { face.beginEnrollment() }
                        .buttonStyle(.borderedProminent)
                    if app.isEnrolled {
                        Button("Forget face", role: .destructive) { face.forgetSavedFace() }
                    }
                    Spacer()
                    Text("Turn your head slowly while it captures.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task { await face.start() }
        .onDisappear { face.stop() }
        // The camera stays on only while this view is here to keep asking for it.
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            face.renewCameraLease()
        }
    }
}

// MARK: - Password

private struct PasswordPane: View {
    @ObservedObject var app: AppController
    @ObservedObject var vault: VaultLabModel
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            card {
                HStack(spacing: 14) {
                    Image(systemName: app.isPasswordSet ? "lock.shield.fill" : "lock.open")
                        .font(.title).foregroundStyle(app.isPasswordSet ? .green : .orange)
                    VStack(alignment: .leading) {
                        Text(app.isPasswordSet ? "Password sealed to the Secure Enclave" : "No password saved yet")
                            .fontWeight(.medium)
                        Text("Sealed behind Touch ID. FacePass never shows it and it never leaves this Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }

            if app.isPasswordSet {
                Button("Delete saved password", role: .destructive) { vault.deleteVault() }
            } else {
                card {
                    Text("Enter your Mac login password. macOS checks it before it's saved.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        SecureField("Mac password", text: $password)
                            .textFieldStyle(.roundedBorder).frame(width: 260)
                            .onSubmit(save)
                        Button("Save", action: save).buttonStyle(.borderedProminent)
                            .disabled(password.isEmpty)
                    }
                }
            }

            if let last = vault.log.first {
                Label(last.message, systemImage: last.succeeded ? "checkmark.circle" : "xmark.octagon")
                    .font(.caption).foregroundStyle(last.succeeded ? .green : .red)
            }
        }
    }

    private func save() {
        guard !password.isEmpty else { return }
        vault.setUp(password: password)
        password = ""
    }
}

// MARK: - Recognition & About

private struct RecognitionPane: View {
    private let policy = UnlockPolicy()
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("These security limits are fixed in the app so no other program can weaken them.")
                .foregroundStyle(.secondary)
            card {
                row("Face match threshold", String(format: "%.2f cosine", policy.minimumSimilarity))
                Divider(); row("Live-face confidence", String(format: "%.0f%%", policy.minimumRealProbability * 100))
                Divider(); row("Max head turn", "±\(Int(policy.maximumYawDegrees))°")
                Divider(); row("Frames to confirm", "\(policy.requiredConsecutiveFrames)")
                Divider(); row("Anti-spoofing", "MiniFASNet ×2 + pose check")
            }
            Text("Camera: built-in only. External, Continuity and virtual cameras are refused.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack { Text(title); Spacer(); Text(value).foregroundStyle(.secondary).monospacedDigit() }
    }
}

private struct AboutPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("FacePass").font(.largeTitle.bold())
            Text("Version 0.1.0").foregroundStyle(.secondary)
            Text("Your face unlocks your Mac. Everything runs on this device — no internet, no servers. Face data and your password never leave this Mac.")
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("Not as strong as Apple Face ID: MacBook cameras have no depth sensor. Use it as a convenience; your password still works and is always required after a restart.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Shared bits

private func sectionTitle(_ text: String) -> some View {
    Text(text.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
}

@ViewBuilder
private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 10) { content() }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
}
