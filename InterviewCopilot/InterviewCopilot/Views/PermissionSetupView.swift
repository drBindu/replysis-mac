import SwiftUI
import AppKit
import AVFoundation

struct PermissionSetupView: View {
    @Environment(MainViewModel.self) var vm

    var body: some View {
        ZStack {
            Color(red: 9/255, green: 13/255, blue: 21/255).ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Top bar with close (×) — optional upgrade, always dismissible ──
                HStack {
                    Spacer()
                    Button(action: { vm.closeHotkeySetup() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(Color.white.opacity(0.25))
                    }
                    .buttonStyle(.plain)
                    .help("Close — the app still works without the Space bar")
                }
                .padding([.top, .trailing], 16)

                // ── Logo + headline ──────────────────────────────────────────
                VStack(spacing: 9) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(LinearGradient(colors: [Color(hex: "#0e3a5a"), Color(hex: "#0a2236")],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 54, height: 54)
                        Image(systemName: "keyboard")
                            .font(.system(size: 25, weight: .semibold))
                            .foregroundColor(Color(hex: "#38bdf8"))
                    }
                    Text("Enable the Space Bar")
                        .font(.system(size: 23, weight: .bold))
                        .foregroundColor(.white)
                    Text("Grant the two permissions below, then press Relaunch. After it\nreopens, Space starts listening hands-free — even while Zoom is in front.")
                        .font(.system(size: 12))
                        .foregroundColor(Color.white.opacity(0.45))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
                .padding(.bottom, 22)

                // ── Permission cards ────────────────────────────────────────
                VStack(spacing: 9) {
                    PermCard(
                        icon: "figure.wave",
                        iconColor: Color(hex: "#a78bfa"),
                        title: "Accessibility",
                        badge: "REQUIRED",
                        detail: "This is what lets the Space bar and F8/F9 keys work as global hotkeys while Zoom or your browser is in front.",
                        isGranted: vm.permAccessibility,
                        buttonLabel: "Open Settings",
                        action: openAccessibilitySettings
                    )

                    PermCard(
                        icon: "mic.fill",
                        iconColor: Color(hex: "#4ade80"),
                        title: "Microphone",
                        badge: "REQUIRED",
                        detail: "Captures the interviewer's voice for real-time speech-to-text transcription.",
                        isGranted: vm.permMicrophone,
                        buttonLabel: micButtonLabel,
                        action: micAction
                    )

                    PermCard(
                        icon: "rectangle.dashed",
                        iconColor: Color(hex: "#f59e0b"),
                        title: "Screen Recording",
                        badge: "OPTIONAL",
                        detail: "Only for F9 screen analysis — solve coding problems shown on your screen.",
                        isGranted: vm.permScreenRecording,
                        buttonLabel: "Open Settings",
                        action: openScreenSettings
                    )
                }
                .padding(.horizontal, 40)

                Spacer(minLength: 18)

                // ── Bottom action area ───────────────────────────────────────
                // The button is DISABLED until BOTH required permissions are granted —
                // exactly the requested flow: grant everything first, then Relaunch.
                VStack(spacing: 10) {
                    Text(vm.hotkeyReadyToActivate
                         ? "All set. Relaunch to activate the Space bar."
                         : "Turn ON the switches above in System Settings — this button activates once both are green.")
                        .font(.system(size: 11))
                        .foregroundColor(vm.hotkeyReadyToActivate ? Color(hex: "#4ade80") : Color.white.opacity(0.4))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20)

                    Button(action: { vm.permissionGrantedContinue() }) {
                        HStack(spacing: 8) {
                            Image(systemName: vm.hotkeyReadyToActivate ? "arrow.clockwise" : "lock.fill")
                                .font(.system(size: 13, weight: .semibold))
                            Text(vm.hotkeyReadyToActivate ? "I've granted them — Relaunch" : "Waiting for permissions…")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(
                            vm.hotkeyReadyToActivate
                            ? AnyView(LinearGradient(colors: [Color(hex: "#1d4ed8"), Color(hex: "#1e40af")],
                                                     startPoint: .top, endPoint: .bottom))
                            : AnyView(Color.white.opacity(0.06))
                        )
                        .cornerRadius(11)
                        .foregroundColor(vm.hotkeyReadyToActivate ? .white : Color.white.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                    .disabled(!vm.hotkeyReadyToActivate)
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 26)
            }
        }
        .frame(width: 560, height: 600)
        .animation(.easeInOut(duration: 0.25), value: vm.permAccessibility)
        .animation(.easeInOut(duration: 0.25), value: vm.permMicrophone)
        .animation(.easeInOut(duration: 0.25), value: vm.permScreenRecording)
    }

    // MARK: - Actions

    private func openAccessibilitySettings() {
        // Fire the prompt first so the app is REGISTERED in the Accessibility list (without
        // this it never appears there to toggle), then open the pane.
        vm.requestAccessibilityPrompt()
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func openScreenSettings() {
        // Registers the app in the Screen Recording list, then opens the pane.
        CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    private var micButtonLabel: String {
        AVCaptureDevice.authorizationStatus(for: .audio) == .denied ? "Open Settings" : "Allow Access"
    }

    private func micAction() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .denied {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        } else {
            vm.requestMicrophonePermission()
        }
    }
}

// MARK: - PermCard

private struct PermCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let badge: String
    let detail: String
    let isGranted: Bool
    let buttonLabel: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            // Icon circle
            ZStack {
                Circle()
                    .fill(iconColor.opacity(isGranted ? 0.18 : 0.10))
                    .frame(width: 44, height: 44)
                Image(systemName: isGranted ? "checkmark" : icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(isGranted ? .green : iconColor)
            }

            // Text
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    Text(badge)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(badge == "REQUIRED" ? .orange : Color.white.opacity(0.4))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background((badge == "REQUIRED" ? Color.orange : Color.white).opacity(0.1))
                        .cornerRadius(4)
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(Color.white.opacity(0.38))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 6)

            // Action / checkmark
            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.green)
            } else {
                Button(buttonLabel, action: action)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.white.opacity(0.10))
                    .cornerRadius(7)
                    .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isGranted ? Color.green.opacity(0.05) : Color.white.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isGranted ? Color.green.opacity(0.2) : Color.white.opacity(0.07), lineWidth: 1)
                )
        )
        .animation(.easeInOut(duration: 0.25), value: isGranted)
    }
}
