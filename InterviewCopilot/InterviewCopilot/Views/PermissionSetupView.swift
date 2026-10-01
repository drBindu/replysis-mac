import SwiftUI
import AppKit

// ══════════════════════════════════════════════════════════════════════════
// Enterprise-style permission onboarding: explain WHY before asking, and let
// the user's own click fire each native macOS dialog — never a system popup
// appearing out of nowhere with no context. Shown once, only for whatever is
// still undecided (MainViewModel.checkAndRequestPermissions decides when).
//
// All three permissions the app actually uses — Microphone, Accessibility,
// Screen Recording — are requested from THIS one screen so there's a single,
// complete, one-time setup. Each is only ever asked again if it's still
// undecided on a later launch; once granted, this screen doesn't reappear
// for it.
// ══════════════════════════════════════════════════════════════════════════

struct PermissionSetupView: View {
    @Environment(MainViewModel.self) var vm

    // IMPORTANT: read permission state through the @Observable ViewModel's tracked
    // properties (permMicrophone / micDenied), NOT by calling AVCaptureDevice.
    // authorizationStatus directly in the view body. A raw OS API call is invisible to
    // SwiftUI's diffing — the card would keep showing "Allow microphone" even after the
    // OS actually granted it, because nothing told SwiftUI to re-render. vm's properties
    // ARE tracked, so referencing them here re-renders the instant requestMicrophonePermission()'s
    // completion handler updates them. (Caught this exact bug live before shipping it.)
    private var micDecided: Bool { vm.permMicrophone || vm.micDenied }

    var body: some View {
        ZStack {
            Color(hex: "#0d1117").ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Header ───────────────────────────────────────────
                VStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(LinearGradient(
                                colors: [Color(hex: "#1d3a5f"), Color(hex: "#0a2236")],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 52, height: 52)
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(Color(hex: "#38bdf8"))
                    }
                    Text("Set up permissions")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundColor(.white)
                    Text("Grant these once so nothing interrupts your interview.")
                        .font(.system(size: 12))
                        .foregroundColor(Color.white.opacity(0.4))
                }
                .padding(.top, 34)
                .padding(.bottom, 24)

                // ── Cards ────────────────────────────────────────────
                // SCROLLS. This was a fixed-height sheet with a fixed-height stack inside,
                // so adding one explanatory line pushed Continue past the bottom edge and
                // out of reach — the sheet is modal, so a clipped Continue is a trapped
                // user. Content that can grow now scrolls; the button below never moves.
                ScrollView {
                VStack(spacing: 10) {
                    PermCard(
                        icon: "mic.fill",
                        iconColor: Color(hex: "#4ade80"),
                        title: "Microphone",
                        reason: "So Space can pick up your voice during the interview.",
                        state: vm.permMicrophone ? .granted
                             : vm.micDenied      ? .denied
                             : .pending,
                        primaryLabel: vm.micDenied ? "Open Settings" : "Allow microphone",
                        action: micAction
                    )

                    PermCard(
                        icon: "keyboard",
                        iconColor: Color(hex: "#a78bfa"),
                        title: "Accessibility",
                        reason: "So Space works from any app, not just this window.",
                        state: vm.permAccessibility ? .granted : .pending,
                        primaryLabel: "Allow accessibility",
                        action: { vm.requestAccessibilityPrompt() }
                    )

                    PermCard(
                        icon: "rectangle.dashed",
                        iconColor: Color(hex: "#f59e0b"),
                        title: "Screen recording",
                        reason: "So Analyze can read code or questions on your screen.",
                        state: vm.permScreenRecording ? .granted : .pending,
                        primaryLabel: "Allow screen recording",
                        action: { vm.requestScreenRecordingPermission() }
                    )
                    // Says the thing the user cannot see: the entry in Settings that looks
                    // correct belongs to a different build. Only shown once a grant has been
                    // asked for and has not landed, so it never appears speculatively.
                    if vm.accessibilityLooksStuck || vm.screenRecordingLooksStuck {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "info.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(Color(hex: "#f59e0b"))
                            Text(vm.permissionStaleEntryHint)
                                .font(.system(size: 11))
                                .foregroundColor(Color(hex: "#8b9bb0"))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 4)

                        // The action the hint asks for, rather than leaving the user to find
                        // Quit and reopen themselves while a modal sheet is up.
                        if vm.screenRecordingLooksStuck {
                            Button(action: { MainViewModel.relaunchApp() }) {
                                Text("Quit & Reopen")
                                    .font(.system(size: 12, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 9)
                                    .background(Color(hex: "#1d4ed8"))
                                    .foregroundColor(.white)
                                    .cornerRadius(9)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 6)
                        }
                    }
                }
                .padding(.horizontal, 28)
                }
                .frame(maxHeight: .infinity)

                Spacer(minLength: 8)

                // ── Continue ─────────────────────────────────────────
                // Only the microphone gates Continue — it's the one the app's core function
                // (transcription) cannot work at all without. Accessibility and Screen
                // Recording are asked here too, but skipping them for now still leaves the
                // app usable (local key monitor, and Analyze prompts again on first use).
                VStack(spacing: 8) {
                    Button(action: { vm.needsPermissionSetup = false }) {
                        Text("Continue")
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(micDecided ? Color(hex: "#1d4ed8") : Color.white.opacity(0.05))
                            .foregroundColor(micDecided ? .white : Color.white.opacity(0.3))
                            .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                    .disabled(!micDecided)

                    if !micDecided {
                        Text("Respond to the microphone prompt above to continue.")
                            .font(.system(size: 11))
                            .foregroundColor(Color.white.opacity(0.35))
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
        }
        // Taller as well as scrollable: the scroll view stops it clipping, and the extra
        // height stops it needing to scroll in the ordinary case.
        .frame(width: 480, height: 560)
        .animation(.easeInOut(duration: 0.2), value: vm.permAccessibility)
        .animation(.easeInOut(duration: 0.2), value: vm.permMicrophone)
        .animation(.easeInOut(duration: 0.2), value: vm.micDenied)
        .animation(.easeInOut(duration: 0.2), value: vm.permScreenRecording)
    }

    private func micAction() {
        if vm.micDenied {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        } else {
            vm.requestMicrophonePermission()
        }
    }
}

// MARK: - PermCard

private enum PermState { case pending, granted, denied }

private struct PermCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let reason: String
    let state: PermState
    let primaryLabel: String?
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(iconColor.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(iconColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundColor(Color.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)

                switch state {
                case .granted:
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(.green)
                        Text("Granted")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.green)
                    }
                case .pending, .denied:
                    Button(primaryLabel ?? "Allow", action: action)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(state == .denied ? Color.white.opacity(0.09) : Color(hex: "#1d4ed8"))
                        .cornerRadius(7)
                        .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(state == .granted ? Color.green.opacity(0.04) : Color.white.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(state == .granted ? Color.green.opacity(0.18) : Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }
}
