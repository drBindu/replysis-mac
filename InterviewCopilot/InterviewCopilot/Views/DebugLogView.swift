import SwiftUI

struct DebugLogView: View {
    @Environment(\.dismiss) var dismiss
    @State private var logText = ""
    @State private var refreshTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Label("Debug Log", systemImage: "terminal")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Button("Clear") {
                    Task { @MainActor in
                        DebugLog.shared.clear()
                        logText = ""
                    }
                }
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#f59e0b"))
                .buttonStyle(.plain)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(logText, forType: .string)
                }
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#38bdf8"))
                .buttonStyle(.plain)
                // Reveal the full persistent log file (has the whole session, beyond the
                // 500-line in-memory cap) so it can be shared for support.
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([DebugLog.logFileURL])
                }
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#38bdf8"))
                .buttonStyle(.plain)
                Button("Close") { dismiss() }
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#6b7280"))
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Color(hex: "#0d1117"))

            Divider().background(Color(hex: "#1e2a3a"))

            ScrollViewReader { proxy in
                ScrollView {
                    Text(logText.isEmpty ? "No log entries yet.\n\nTry pressing SPACE, signing in, or using screen capture." : logText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(logText.isEmpty ? Color(hex: "#374151") : Color(hex: "#d1d5db"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .id("logBottom")
                }
                .onChange(of: logText) {
                    withAnimation { proxy.scrollTo("logBottom", anchor: .bottom) }
                }
            }
            .background(Color(hex: "#070b12"))
        }
        .frame(width: 720, height: 500)
        .background(Color(hex: "#0d1117"))
        .onAppear {
            refreshLog()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                Task { @MainActor in self.refreshLog() }
            }
        }
        .onDisappear { refreshTimer?.invalidate() }
    }

    private func refreshLog() {
        logText = DebugLog.shared.text
    }
}
