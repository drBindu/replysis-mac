import SwiftUI
import AppKit
import AVFoundation

struct PermissionSetupView: View {
    @Environment(MainViewModel.self) var vm

    var body: some View {
        ZStack {
            Color(red: 9/255, green: 13/255, blue: 21/255).ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // ── Logo + headline ──────────────────────────────────────────
                VStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(LinearGradient(colors: [Color(hex: "#0e3a5a"), Color(hex: "#0a2236")],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 56, height: 56)
                        Image(systemName: "brain.head.profile")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundColor(Color(hex: "#38bdf8"))
                    }
                    Text("Setup Required")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(.white)
                    Text("Grant these permissions once — they persist forever.")
                        .font(.system(size: 13))
                        .foregroundColor(Color.white.opacity(0.45))
                }
                .padding(.bottom, 32)

                // ── Permission cards ────────────────────────────────────────
                VStack(spacing: 10) {
                    PermCard(
                        icon: "keyboard",
                        iconColor: Color(hex: "#38bdf8"),
                        title: "Input Monitoring",
                        badge: "REQUIRED",
                        detail: "Lets the Space bar and F8/F9 keys work as hotkeys while Zoom or your browser is in front. This is what makes the Space bar start listening.",
                        isGranted: vm.permInputMonitoring,
                        buttonLabel: "Open Settings",
                        action: openInputMonitoringSettings
                    )

                    PermCard(
                        icon: "figure.wave",
                        iconColor: Color(hex: "#a78bfa"),
                        title: "Accessibility",
                        badge: "REQUIRED",
                        detail: "Works together with Input Monitoring so the global hotkeys register reliably.",
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
                        detail: "Needed only for F9 screen analysis — solve coding problems from your screen.",
                        isGranted: vm.permScreenRecording,
                        buttonLabel: "Open Settings",
                        action: openScreenSettings
                    )
                }
                .padding(.horizontal, 44)

                Spacer()

                // ── Bottom action area ───────────────────────────────────────
                if vm.permInputMonitoring && vm.permAccessibility {
                    // Both hotkey permissions granted — enter (this relaunches so the tap
                    // registers in a freshly-authorized process).
                    Button(action: { vm.permissionGrantedContinue() }) {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                            Text("Activate & Start").fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(LinearGradient(colors: [Color(hex: "#1d4ed8"), Color(hex: "#1e40af")],
                                                   startPoint: .top, endPoint: .bottom))
                        .cornerRadius(11)
                        .foregroundColor(.white)
                    }
                    .padding(.horizontal, 44)
                    .padding(.bottom, 36)
                    .transition(.opacity)
                } else {
                    // Still waiting on a required permission — name exactly which one.
                    VStack(spacing: 10) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 11))
                                .foregroundColor(Color.white.opacity(0.3))
                            Text("Grant the REQUIRED permissions above — this updates automatically.")
                                .font(.system(size: 11))
                                .foregroundColor(Color.white.opacity(0.3))
                        }
                        Button(action: {}) {
                            HStack(spacing: 8) {
                                Image(systemName: "lock.fill")
                                Text(waitingLabel).fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(11)
                            .foregroundColor(Color.white.opacity(0.3))
                        }
                        .disabled(true)
                    }
                    .padding(.horizontal, 44)
                    .padding(.bottom, 36)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: vm.permInputMonitoring)
        .animation(.easeInOut(duration: 0.25), value: vm.permAccessibility)
    }

    private var waitingLabel: String {
        if !vm.permInputMonitoring { return "Waiting for Input Monitoring…" }
        if !vm.permAccessibility  { return "Waiting for Accessibility…" }
        return "Waiting…"
    }

    // MARK: - Actions

    private func openInputMonitoringSettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    private func relaunchApp() {
        // Reopen the app bundle and quit this process — clean relaunch.
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApplication.shared.terminate(nil)
        }
    }

    private func openAccessibilitySettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func openScreenSettings() {
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
