import SwiftUI
import AppKit
import AVFoundation

struct PermissionSetupView: View {
    @Environment(MainViewModel.self) var vm

    var body: some View {
        ZStack {
            Color(red: 9/255, green: 13/255, blue: 21/255).ignoresSafeArea()

            VStack(spacing: 0) {

                // ── Close button ─────────────────────────────────────
                HStack {
                    Spacer()
                    Button(action: { vm.closeHotkeySetup() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(Color.white.opacity(0.18))
                    }
                    .buttonStyle(.plain)
                    .help("Close — the app still works without global Space bar")
                }
                .padding([.top, .trailing], 16)

                // ── Header ───────────────────────────────────────────
                VStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(LinearGradient(
                                colors: [Color(hex: "#1d3a5f"), Color(hex: "#0a2236")],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 52, height: 52)
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 23, weight: .semibold))
                            .foregroundColor(Color(hex: "#38bdf8"))
                    }
                    Text("Set Up Permissions")
                        .font(.system(size: 21, weight: .bold))
                        .foregroundColor(.white)
                    Text("One-time setup — takes about 30 seconds.")
                        .font(.system(size: 12))
                        .foregroundColor(Color.white.opacity(0.38))
                }
                .padding(.top, 2)
                .padding(.bottom, 22)

                // ── Step cards ───────────────────────────────────────
                VStack(spacing: 10) {

                    // Step 1 — Microphone
                    StepCard(
                        step: 1,
                        icon: "mic.fill",
                        iconColor: Color(hex: "#4ade80"),
                        title: "Microphone",
                        badge: "REQUIRED",
                        description: "Captures your voice for real-time speech-to-text transcription.",
                        isGranted: vm.permMicrophone,
                        buttonLabel: micButtonLabel,
                        extraInfo: nil,
                        action: micAction
                    )

                    // Step 2 — Accessibility
                    StepCard(
                        step: 2,
                        icon: "figure.wave",
                        iconColor: Color(hex: "#a78bfa"),
                        title: "Accessibility",
                        badge: "REQUIRED",
                        description: "Lets the Space bar work while Zoom or your browser is in front.",
                        isGranted: vm.permAccessibility,
                        buttonLabel: "Open Settings",
                        extraInfo: vm.permAccessibility ? nil :
                            "① Click Open Settings  ② Find InterviewCopilot → toggle ON  ③ Click Relaunch below",
                        action: openAccessibilitySettings
                    )

                    // Step 3 — Screen Recording
                    StepCard(
                        step: 3,
                        icon: "rectangle.dashed",
                        iconColor: Color(hex: "#f59e0b"),
                        title: "Screen Recording",
                        badge: "OPTIONAL",
                        description: "Analyze code or questions shown on your screen with F9.",
                        isGranted: vm.permScreenRecording,
                        buttonLabel: "Open Settings",
                        extraInfo: nil,
                        action: openScreenSettings
                    )
                }
                .padding(.horizontal, 32)

                Spacer(minLength: 16)

                // ── Bottom action ─────────────────────────────────────
                VStack(spacing: 10) {
                    Text(vm.hotkeyReadyToActivate
                         ? "All set — click Relaunch to activate the global Space bar."
                         : "Grant Microphone and Accessibility above to continue.")
                        .font(.system(size: 11))
                        .foregroundColor(vm.hotkeyReadyToActivate
                                         ? Color(hex: "#4ade80")
                                         : Color.white.opacity(0.35))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)

                    Button(action: { vm.permissionGrantedContinue() }) {
                        HStack(spacing: 8) {
                            Image(systemName: vm.hotkeyReadyToActivate
                                  ? "arrow.clockwise" : "lock.fill")
                                .font(.system(size: 13, weight: .semibold))
                            Text(vm.hotkeyReadyToActivate
                                 ? "Relaunch & Start Session"
                                 : "Waiting for permissions…")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(
                            vm.hotkeyReadyToActivate
                            ? AnyView(LinearGradient(
                                colors: [Color(hex: "#1d4ed8"), Color(hex: "#1e40af")],
                                startPoint: .top, endPoint: .bottom))
                            : AnyView(Color.white.opacity(0.05))
                        )
                        .cornerRadius(11)
                        .foregroundColor(vm.hotkeyReadyToActivate
                                         ? .white : Color.white.opacity(0.28))
                    }
                    .buttonStyle(.plain)
                    .disabled(!vm.hotkeyReadyToActivate)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
            }
        }
        .frame(width: 520, height: 570)
        .animation(.easeInOut(duration: 0.22), value: vm.permMicrophone)
        .animation(.easeInOut(duration: 0.22), value: vm.permAccessibility)
        .animation(.easeInOut(duration: 0.22), value: vm.permScreenRecording)
    }

    // MARK: - Actions

    private func openAccessibilitySettings() {
        vm.requestAccessibilityPrompt()
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func openScreenSettings() {
        vm.registerScreenRecording()
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

// MARK: - StepCard

private struct StepCard: View {
    let step: Int
    let icon: String
    let iconColor: Color
    let title: String
    let badge: String
    let description: String
    let isGranted: Bool
    let buttonLabel: String
    let extraInfo: String?
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {

                // Step number / granted checkmark
                ZStack {
                    Circle()
                        .fill(isGranted
                              ? Color.green.opacity(0.14)
                              : Color.white.opacity(0.05))
                        .frame(width: 38, height: 38)
                    if isGranted {
                        Image(systemName: "checkmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.green)
                    } else {
                        Text("\(step)")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(Color.white.opacity(0.4))
                    }
                }

                // Text
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                        Text(badge)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(badge == "REQUIRED"
                                             ? .orange : Color.white.opacity(0.35))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background((badge == "REQUIRED"
                                         ? Color.orange : Color.white).opacity(0.1))
                            .cornerRadius(4)
                    }
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundColor(Color.white.opacity(0.35))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                // Action / granted badge
                if isGranted {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundColor(.green)
                        Text("Granted")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.green)
                    }
                } else {
                    Button(buttonLabel, action: action)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.white.opacity(0.09))
                        .cornerRadius(7)
                        .buttonStyle(.plain)
                }
            }
            .padding(14)

            // Inline guide for Accessibility (shown only when not granted)
            if !isGranted, let info = extraInfo {
                Text(info)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color(hex: "#38bdf8").opacity(0.65))
                    .padding(.leading, 64)
                    .padding(.trailing, 14)
                    .padding(.bottom, 12)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(isGranted
                      ? Color.green.opacity(0.04)
                      : Color.white.opacity(0.025))
                .overlay(
                    RoundedRectangle(cornerRadius: 11)
                        .stroke(isGranted
                                ? Color.green.opacity(0.18)
                                : Color.white.opacity(0.06), lineWidth: 1)
                )
        )
        .animation(.easeInOut(duration: 0.22), value: isGranted)
    }
}
