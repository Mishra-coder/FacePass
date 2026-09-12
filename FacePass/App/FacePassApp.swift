import SwiftUI

@main
struct FacePassApp: App {
    @StateObject private var app = AppController()
    @StateObject private var settings = FacePassSettings.shared
    @StateObject private var lab = FaceLabModel()
    @StateObject private var vaultLab = VaultLabModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(app: app)
        } label: {
            Image(systemName: app.automaticUnlockOn ? "faceid" : "face.smiling")
        }

        Window("FacePass Settings", id: SettingsView.windowID) {
            SettingsView(app: app, settings: settings, face: lab, vault: vaultLab)
        }
        .windowResizability(.contentSize)
    }
}

private struct MenuContent: View {
    @ObservedObject var app: AppController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("FacePass — \(app.statusLine)")

        Divider()

        if app.isFullyReady {
            if app.automaticUnlockOn {
                Button("Turn off face unlock") { app.turnOff() }
            } else {
                Button("Turn on face unlock") { Task { await app.armAndEnable() } }
            }
        } else {
            Button(app.isArmed ? "Turn on face unlock" : "Arm with Touch ID") { Task { await app.armAndEnable() } }
                .disabled(!(app.isEnrolled && app.isPasswordSet && app.hasAccessibility) || app.busy)
            if !app.hasAccessibility {
                Button("Turn on Accessibility permission…") { app.requestAccessibility() }
            }
        }

        Button("Settings…") {
            openWindow(id: SettingsView.windowID); NSApp.activate()
        }
        .keyboardShortcut(",")

        if let error = app.lastError {
            Text(error).font(.caption)
        }

        Divider()

        Button("Quit FacePass") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
