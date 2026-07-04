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

                        // AI Model
                        settingsSection("AI MODEL") {
                            VStack(spacing: 8) {
                                modelRow("Groq (Llama — Fast & Free)", selected: vm.useGroq) {
                                    vm.useGroq = true; vm.saveSettings()
                                }
                                modelRow("OpenAI (GPT-4o — More Accurate)", selected: !vm.useGroq) {
                                    vm.useGroq = false; vm.saveSettings()
                                }
                            }
                        }

                        // Window opacity is controlled live from the profile menu
                        // (avatar → Window opacity slider), so it's not duplicated here.

                        // About
                        settingsSection("ABOUT") {
                            VStack(alignment: .leading, spacing: 6) {
                                infoRow("Version", Self.appVersion)
                                infoRow("Backend", AppConfig.backendUrl)
                                if UserSession.shared.isLoggedIn {
                                    infoRow("Account", UserSession.shared.email)
                                    infoRow("Plan", "\(UserSession.shared.plan) / \(UserSession.shared.credits) credits")
                                }
                            }
                        }

                        Spacer(minLength: 20)
                    }
                    .padding(20)
                }
            }
        }
        .frame(width: 420, height: 480)
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
