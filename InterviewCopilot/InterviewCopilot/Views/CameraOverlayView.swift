import SwiftUI
import AppKit

// ══════════════════════════════════════════════════════════════
// MARK: — Eye Mode overlay  (Parakeet/Cluely-style compact HUD)
// A small bar pinned near the top of the screen (by the webcam):
//   • idle      → just a status pill ("Ready · press Space")
//   • listening → shows the interviewer transcript
//   • answered  → the box EXPANDS downward to reveal the AI answer
// The window auto-sizes to its content and keeps its TOP edge pinned,
// so it grows downward from near the camera. Non-activating → never
// steals focus. Opacity follows the main Window-opacity slider.
// ══════════════════════════════════════════════════════════════

class AnswerOverlayWindow: NSPanel {
    static var shared: AnswerOverlayWindow?
    var topEdgeY: CGFloat = 0      // screen Y of the top edge we keep pinned
    private var resizeObserver: NSObjectProtocol?   // held so we can remove it in deinit

    deinit {
        if let obs = resizeObserver { NotificationCenter.default.removeObserver(obs) }
    }

    static func show(vm: MainViewModel) {
        if shared == nil {
            let panel = AnswerOverlayWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 120),
                styleMask:   [.borderless],   // no .nonactivatingPanel — needs to be key window
                backing:     .buffered,       // so SwiftUI renders properly with .accessory policy
                defer:       false
            )
            panel.isOpaque           = false
            panel.backgroundColor    = .clear
            panel.level              = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isMovableByWindowBackground = false
            panel.hasShadow          = true
            panel.hidesOnDeactivate  = false

            let hosting = NSHostingView(rootView: AnswerOverlayView(vm: vm))
            hosting.sizingOptions = [.preferredContentSize]   // window follows content height
            panel.contentView = hosting
            panel.contentView?.clearLayerBackgrounds()
            AnswerOverlayWindow.shared = panel

            // Keep the top edge pinned whenever the content (and thus height) changes.
            // Store the token so the observer is removed when the panel is deallocated.
            panel.resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: panel, queue: .main
            ) { [weak panel] _ in panel?.anchorTop() }
        }

        // Position near the top-center of the screen (by the webcam).
        if let screen = NSScreen.main, let panel = shared {
            panel.topEdgeY = screen.visibleFrame.maxY - 10
            let x = screen.visibleFrame.midX - panel.frame.width / 2
            panel.setFrameOrigin(NSPoint(x: x, y: panel.topEdgeY - panel.frame.height))
        }
        shared?.makeKeyAndOrderFront(nil)
    }

    static func hide() { shared?.orderOut(nil) }

    // Re-pin the top edge after a resize (move only — never resize here, or we loop).
    func anchorTop() {
        let f = frame
        setFrameOrigin(NSPoint(x: f.origin.x, y: topEdgeY - f.height))
    }

    override var canBecomeKey: Bool  { true }
    override var canBecomeMain: Bool { false }
}

// ══════════════════════════════════════════════════════════════
// MARK: — Eye Mode SwiftUI view
// ══════════════════════════════════════════════════════════════

private struct EyeTranscriptHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct EyeAnswerHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct AnswerOverlayView: View {
    var vm: MainViewModel

    // Measured height of the answer content, so the box shrinks to fit a short answer
    // (no more giant empty black rectangle) and scrolls only once it exceeds the cap.
    @State private var answerContentHeight: CGFloat = 0
    @State private var transcriptContentHeight: CGFloat = 0
    @State private var dragOrigin: CGPoint?
    private let answerMaxHeight: CGFloat = 340

    private var hasAnswer: Bool { !vm.aiAnswer.isEmpty || vm.showThinking }
    private var isIdle: Bool { !vm.isListening && vm.aiAnswer.isEmpty && !vm.showThinking }

    private var statusText: String {
        if vm.showThinking || vm.isProcessing { return "Thinking…" }
        if vm.micNeedsRetry { return vm.micStatus.capitalized }
        if vm.micStatus == "CONNECTING" { return "Connecting…" }
        if vm.isListening { return "Listening" }
        return vm.micStatus.capitalized
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
                .gesture(DragGesture(minimumDistance: 6).onChanged { value in
                    guard let window = AnswerOverlayWindow.shared else { return }
                    if dragOrigin == nil { dragOrigin = window.frame.origin }
                    guard let origin = dragOrigin else { return }
                    let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
                    let x = max(screen.minX, min(origin.x + value.translation.width, screen.maxX - window.frame.width))
                    let y = max(screen.minY, min(origin.y - value.translation.height, screen.maxY - window.frame.height))
                    window.setFrameOrigin(CGPoint(x: x, y: y))
                    window.topEdgeY = window.frame.maxY
                }.onEnded { _ in dragOrigin = nil })

            // Show the interviewer's question whenever we're listening OR have captured
            // text — with a "Listening…" placeholder — so the question area is never blank.
            if vm.isListening || !vm.transcriptForDisplay.isEmpty {
                divider
                ScrollView {
                    transcriptRow.background(GeometryReader { geometry in
                        Color.clear.preference(key: EyeTranscriptHeightKey.self, value: geometry.size.height)
                    })
                }
                .frame(height: min(max(transcriptContentHeight, 44), 100))
                .onPreferenceChange(EyeTranscriptHeightKey.self) { transcriptContentHeight = $0 }
            }

            if hasAnswer {
                divider
                answerArea
            }
        }
        .frame(width: 600)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(
                    colors: [
                        Color(red: 3/255,  green: 7/255,  blue: 18/255).opacity(vm.mainWindowOpacity),
                        Color(red: 5/255,  green: 15/255, blue: 30/255).opacity(vm.mainWindowOpacity)
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.18), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16))

    }

    // ── Status bar (always visible) ──
    private var statusBar: some View {
        HStack(spacing: 9) {
            Button {
                if vm.micNeedsRetry { vm.retryMic() }
                else { vm.handleSpacePress(source: "COMPACT") }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: vm.isListening ? "pause.circle.fill" : "play.circle.fill")
                        .foregroundColor(vm.micColor)
                    Text(statusText)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Listen, pause, or answer (Space)")
            .accessibilityLabel("Listening control: " + statusText)
            if isIdle {
                Text(vm.listeningMode.isAutomatic ? "Auto, press Space to pause or resume" : "Press Space to listen or answer")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
            }
            Spacer()
            // Manual screen-analysis trigger — eye mode had no way to fire F9 other than
            // the physical key, unlike the main window's visible Analyze button.
            // Labelled "Read screen", matching Windows (AnswerWindow.xaml). "Analyze" is
            // the old name and says what the code does rather than what the user gets;
            // in compact mode this is the only button on the bar, so its label is the
            // entire explanation of what it will do.
            // Same answer history as the main window: in compact mode this bar is the only
            // way back to an answer something replaced.
            if !vm.answerHistory.isEmpty {
                HStack(spacing: 2) {
                    Button(action: { vm.showPreviousAnswer() }) {
                        Image(systemName: "chevron.left").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .disabled(!vm.canGoBack)
                    .foregroundColor(vm.canGoBack ? Color(hex: "#cbd5e1") : Color(hex: "#475569"))
                    .help("Previous answer (⌃⌥←)")
                    if vm.isShowingHistory {
                        Text(vm.historyPosition)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(Color(hex: "#fbbf24"))
                            .fixedSize()
                    }
                    Button(action: { vm.showNextAnswer() }) {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .disabled(!vm.canGoForward)
                    .foregroundColor(vm.canGoForward ? Color(hex: "#cbd5e1") : Color(hex: "#475569"))
                    .help("Next answer (⌃⌥→)")
                }
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.05)))
            }

            Button(action: { vm.runScreenAnalysis() }) {
                ReadScreenButtonLabel(busy: vm.isScreenAnalyzing)
            }
            .buttonStyle(GlassButtonStyle(windowOpacity: vm.mainWindowOpacity,
                                          minHeight: 28, horizontalPadding: 9, verticalPadding: 3))
            .disabled(vm.isProcessing || vm.isScreenAnalyzing)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(AnswerLayout.copyText(vm.aiAnswer), forType: .string)
            } label: {
                Image(systemName: "doc.on.doc").foregroundColor(Color(hex: "#94a3b8"))
            }
            .buttonStyle(.plain)
            .disabled(vm.aiAnswer.isEmpty)
            .help("Copy answer")
            .accessibilityLabel("Copy answer")

            Image(systemName: "eye.fill")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.22))
            Button(action: { vm.exitCamera() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.45))
            }
            .buttonStyle(.plain)
            .help("Return to full view")
            .accessibilityLabel("Return to full view")
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    // ── Interviewer transcript (when listening / captured) ──
    private var transcriptRow: some View {
        HStack(alignment: .top, spacing: 9) {
            Text("THEM")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(Color(hex: "#38bdf8"))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color(hex: "#0d2540"))
                .cornerRadius(4)
            Text(vm.transcriptForDisplay.isEmpty ? "Listening…" : vm.transcriptForDisplay)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(vm.transcriptForDisplay.isEmpty
                                 ? Color(hex: "#64748b") : Color(hex: "#cbd5e1"))
                .lineLimit(nil)               // show the FULL question — never truncate
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    /// The spoken answer and the MORE TO SAY notes, split at the marker the answer path writes.
    private var answerParts: (spoken: String, more: String) {
        let parts = vm.aiAnswer.components(separatedBy: MainViewModel.moreToSayMarker)
        let spoken = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let more = parts.count > 1
            ? parts.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        return (spoken, more)
    }

    // ── AI answer (expands the box downward) ──
    private var answerArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    if vm.aiAnswer.isEmpty {
                        Text(vm.thinkingText)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.6), radius: 3, x: 0, y: 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        // The words to say and the notes behind them are two blocks, not one.
                        // As a single block the literal MORE TO SAY printed as a sentence in the
                        // middle of the answer and the bullets looked exactly as urgent as the
                        // words being spoken. Windows a191a81: answer 16pt, quiet label, notes
                        // 13pt and dimmer.
                        let parts = answerParts
                        VStack(alignment: .leading, spacing: 10) {
                            if vm.isProcessing && (parts.spoken.contains("```") || parts.spoken.hasPrefix("From your screen")) {
                                // An answer with code, or a screen answer, streams in the layout it will end in.
                                AnswerContentView(raw: parts.spoken, fontSize: 16, codeFontSize: 12, streaming: true)
                            } else if vm.isProcessing {
                                // Streaming: plain text for smooth rendering (no parse cost)
                                Text(parts.spoken)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.white)
                                    .shadow(color: .black.opacity(0.6), radius: 3, x: 0, y: 1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                // Finished: rich renderer (styled headers + highlighted code)
                                AnswerContentView(raw: parts.spoken, fontSize: 16, codeFontSize: 12)
                            }
                            if !parts.more.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("MORE TO SAY")
                                        .font(.system(size: 10, weight: .bold)).tracking(0.8)
                                        .foregroundColor(Color(hex: "#64748b"))
                                    Text(parts.more)
                                        .font(.system(size: 13))
                                        .foregroundColor(Color(hex: "#94a3b8"))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }
                                .padding(.top, 4)
                            }
                        }
                    }
                }
                .padding(16)
                .id("eyeContent")
                .background(GeometryReader { g in
                    Color.clear.preference(key: EyeAnswerHeightKey.self, value: g.size.height)
                })
            }
            // Fit the box to the answer (short answers → small box, no giant black
            // rectangle) and cap it so long answers scroll inside the overlay.
            .frame(height: min(max(answerContentHeight, 44), answerMaxHeight))
            .onPreferenceChange(EyeAnswerHeightKey.self) { answerContentHeight = $0 }
            // Jump to the top of a NEW answer; don't auto-follow while it streams
            .onChange(of: vm.answerEpoch) {
                proxy.scrollTo("eyeContent", anchor: .top)
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
    }
}
