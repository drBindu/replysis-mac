import SwiftUI

struct SettingsView: View {
    @Environment(MainViewModel.self) var vm
    @Environment(\.dismiss) var dismiss

    // Real app version from the bundle (was hardcoded "1.0.0", so it always showed the
    // wrong number — the CI stamps 1.0.<build> into MARKETING_VERSION).
    static var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return b.isEmpty ? v : "\(v) (\(b))"
    }

    var body: some View {
        ZStack {
            Color(hex: "#0d1117").ignoresSafeArea()
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Settings")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                    Button("Done") { vm.saveSettings(); dismiss() }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(hex: "#38bdf8"))
                        .buttonStyle(.plain)
                }
                .padding(.horizontal, 20).padding(.vertical, 14)
                Divider().background(Color(hex: "#1e2a3a"))

                ScrollView {
                    VStack(spacing: 20) {

                        // One mode, so one line and one switch. The microphone is a preference,
                        // not a mode: off still works for real interviews, and practising alone
                        // does not, which is what the switch says.
                        settingsSection("LISTENING") {
                            VStack(alignment: .leading, spacing: 10) {
                                // Live tip, as on Windows 1.0.20: amber while the mic is on, green
                                // once it is off. Follows the switch below as it is flipped.
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: vm.micCaptureEnabled ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                                        .foregroundColor(Color(hex: vm.micCaptureEnabled ? "#fbbf24" : "#34d399"))
                                    Text(vm.micCaptureEnabled
                                         ? "Real interview: switch the toolbar to Interview, so only the interviewer is heard."
                                         : "Ready for a real interview. Interview mode hears only the interviewer's audio.")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(Color(hex: vm.micCaptureEnabled ? "#fbbf24" : "#34d399"))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(hex: vm.micCaptureEnabled ? "#2A1F0D" : "#0D2A1F")))
                                Text("For a live interview in Zoom, Google Meet or Teams, choose Interview in the toolbar. Replysis still hears the interviewer through your computer sound, without mistaking your spoken answer for a new question. Keep your microphone on in the meeting app so the interviewer can hear you.")
                                    .font(.system(size: 11))
                                    .foregroundColor(Color(hex: "#8b9bb0"))
                                    .fixedSize(horizontal: false, vertical: true)
                                Toggle(isOn: Binding(get: { vm.micCaptureEnabled },
                                                     set: { vm.setMicCaptureEnabled($0) })) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Practice mode: use my microphone")
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundColor(.white)
                                        Text("Same switch as Interview / Practice in the toolbar. Off (Interview) hears the meeting only, so your own answers are never taken as questions. On (Practice) also hears you, for practising alone. Replysis follows your Mac’s default input and reconnects when it changes.")
                                            .font(.system(size: 11))
                                            .foregroundColor(Color(hex: "#8b9bb0"))
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .toggleStyle(.switch)
                            }
                        }

                        // The engine hears ONLY this language, so it has to match the
                        // interview. Same list and codes as Windows.
                        settingsSection("INTERVIEW LANGUAGE") {
                            VStack(alignment: .leading, spacing: 8) {
                                Picker("", selection: Binding(get: { vm.transcriptLanguage },
                                                              set: { vm.setInterviewLanguage($0) })) {
                                    ForEach(MainViewModel.interviewLanguages, id: \.code) { lang in
                                        Text(lang.name).tag(lang.code)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(maxWidth: 260, alignment: .leading)
                                Text("The interviewer is heard in this language only. Speech in another language comes back as garbled words in this one. Changing it restarts listening, and waits if a question is in progress.")
                                    .font(.system(size: 11))
                                    .foregroundColor(Color(hex: "#8b9bb0"))
                                    .fixedSize(horizontal: false, vertical: true)

                                // Only the languages that need it, and only when one is chosen.
                                if MainViewModel.sarvamLanguages.contains(vm.transcriptLanguage) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Sarvam AI API key")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundColor(.white)
                                        SecureField("Required for this language", text: Binding(
                                            get: { vm.sarvamApiKey },
                                            set: { vm.setSarvamApiKey($0) }))
                                            .textFieldStyle(.roundedBorder)
                                            .frame(maxWidth: 260)
                                        Text(vm.sarvamApiKey.isEmpty
                                             ? "This language is heard through Sarvam AI. Without its key, nothing is heard."
                                             : "Stored on this Mac only, and sent to the engine by environment, never on a command line.")
                                            .font(.system(size: 11))
                                            .foregroundColor(Color(hex: vm.sarvamApiKey.isEmpty ? "#fbbf24" : "#8b9bb0"))
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }

                        settingsSection("PRIVACY") {
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle(isOn: Binding(get: { vm.cloudSyncEnabled },
                                                     set: { vm.setCloudSyncEnabled($0) })) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Back up session history")
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundColor(.white)
                                        Text("Syncs questions, answers and a short part of your resume to your other signed-in devices.")
                                            .font(.system(size: 11))
                                            .foregroundColor(Color(hex: "#8b9bb0"))
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .toggleStyle(.switch)
                                Text("Settings are saved on this Mac. Replysis never saves the audio it hears.")
                                    .font(.system(size: 11))
                                    .foregroundColor(Color(hex: "#8b9bb0"))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        // Screen answers — the standing preference the toolbar used to hold.
                        settingsSection("SCREEN ANSWERS") {
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle(isOn: Binding(get: { vm.screenKeysEverywhere },
                                                     set: { vm.setScreenKeysEverywhere($0) })) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Screen keys work in every app")
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundColor(.white)
                                        Text("F8 and F9 read the screen from any app. Turn off if another app needs them, such as an IDE; ⌃⌥F8 and ⌃⌥F9 always work.")
                                            .font(.system(size: 11))
                                            .foregroundColor(Color(hex: "#8b9bb0"))
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .toggleStyle(.switch)
                                audioModeRow(
                                    title: "Answer from the screen (Recommended)",
                                    detail: "When a question is about what's on screen, such as a coding problem, an error or a diagram, read the screen and answer from it. Questions about you are still answered from your resume.",
                                    selected: vm.isWatchMode
                                ) { vm.setScreenAnswers(true) }
                                audioModeRow(
                                    title: "Answer from speech only",
                                    detail: "Never read the screen automatically. The READ SCREEN button and F8 still work whenever you press them.",
                                    selected: !vm.isWatchMode
                                ) { vm.setScreenAnswers(false) }

                                if vm.isWatchMode && !vm.permScreenRecording {
                                    HStack(alignment: .top, spacing: 7) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .font(.system(size: 11))
                                            .foregroundColor(Color(hex: "#f59e0b"))
                                        Text("Screen Recording isn't granted yet, so questions are being answered from speech alone. Enable it in System Settings → Privacy & Security → Screen & System Audio Recording, then reopen the app.")
                                            .font(.system(size: 11))
                                            .foregroundColor(Color(hex: "#8b9bb0"))
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .padding(.top, 2)
                                }
                            }
                        }

                        // Stealth Mode — hides the window from screen sharing & recording
                        // (Zoom/Meet/Teams, QuickTime). Default ON. Moved here (off the main
                        // header) so the toolbar stays clean; this is a set-once preference,
                        // not something toggled mid-interview.
                        settingsSection("STEALTH MODE") {
                            VStack(alignment: .leading, spacing: 8) {
                                audioModeRow(
                                    title: "Stealth ON (Recommended)",
                                    detail: "Requests exclusion from screen capture. Support depends on macOS and the meeting app; verify with a test share before relying on it.",
                                    selected: vm.stealthModeEnabled
                                ) { vm.setStealthModeEnabled(true) }
                                audioModeRow(
                                    title: "Stealth OFF",
                                    detail: "Window is visible in screen shares and recordings, like any normal app.",
                                    selected: !vm.stealthModeEnabled
                                ) { vm.setStealthModeEnabled(false) }
                            }
                        }

                        // Window opacity is controlled live from the profile menu
                        // (avatar → Window opacity slider), so it's not duplicated here.

                        // About
                        settingsSection("ABOUT") {
                            VStack(alignment: .leading, spacing: 6) {
                                infoRow("Version", Self.appVersion)
                                infoRow("Backend", AppConfig.backendUrl)
                                if UserSession.shared.isGuestSession {
                                    infoRow("Account", "Free trial (not signed in)")
                                    infoRow("Answers", "\(PlanFacts.answersLabel(UserSession.shared.credits)) left, not refreshed")
                                    Button("Sign in to save your sessions") {
                                        NotificationCenter.default.post(name: .showLogin, object: nil)
                                    }
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(Color(hex: "#38bdf8"))
                                    .buttonStyle(.plain)
                                } else if UserSession.shared.isLoggedIn {
                                    infoRow("Account", UserSession.shared.email)
                                    infoRow("Plan", "\(UserSession.shared.plan.capitalized), \(PlanFacts.answersLabel(UserSession.shared.credits)) left")
                                }
                                Button("Check for Updates…") { AppUpdater.shared.checkForUpdates() }
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(Color(hex: "#38bdf8"))
                                    .buttonStyle(.plain)
                                    .padding(.top, 4)
                            }
                        }

                        Spacer(minLength: 20)
                    }
                    .padding(20)
                }
            }
        }
        .frame(width: 420, height: 560)
    }

    func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(Color(hex: "#6b7280"))
                .tracking(1.5)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func modelRow(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(selected ? Color(hex: "#38bdf8") : Color(hex: "#4b5563"))
                    .font(.system(size: 14))
                Text(label)
                    .font(.system(size: 12))
                    .foregroundColor(selected ? .white : Color(hex: "#9ca3af"))
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color(hex: selected ? "#0c2a40" : "#111827"))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    func audioModeRow(title: String, detail: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(selected ? Color(hex: "#38bdf8") : Color(hex: "#4b5563"))
                    .font(.system(size: 14))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(selected ? .white : Color(hex: "#9ca3af"))
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#6b7280"))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Color(hex: selected ? "#0c2a40" : "#111827"))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#6b7280"))
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#9ca3af"))
        }
    }
}
