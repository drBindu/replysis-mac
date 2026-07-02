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

    static func show(vm: MainViewModel) {
        if shared == nil {
            let panel = AnswerOverlayWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 120),
                styleMask:   [.borderless, .nonactivatingPanel],
                backing:     .buffered,
                defer:       false
            )
            panel.isOpaque           = false
            panel.backgroundColor    = .clear
            panel.level              = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isMovableByWindowBackground = true
            panel.hasShadow          = true
            panel.hidesOnDeactivate  = false

            let hosting = NSHostingView(rootView: AnswerOverlayView(vm: vm))
            hosting.sizingOptions = [.preferredContentSize]   // window follows content height
            panel.contentView = hosting
            AnswerOverlayWindow.shared = panel

            // Keep the top edge pinned whenever the content (and thus height) changes.
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: panel, queue: .main
            ) { [weak panel] _ in panel?.anchorTop() }
        }

        // Position near the top-center of the screen (by the webcam).
        if let screen = NSScreen.main, let panel = shared {
            panel.topEdgeY = screen.visibleFrame.maxY - 10
            let x = screen.visibleFrame.midX - panel.frame.width / 2
            panel.setFrameOrigin(NSPoint(x: x, y: panel.topEdgeY - panel.frame.height))
        }
        shared?.orderFrontRegardless()
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

struct AnswerOverlayView: View {
    let vm: MainViewModel

    private var hasAnswer: Bool { !vm.aiAnswer.isEmpty || vm.showThinking }
    private var isIdle: Bool { !vm.isListening && vm.aiAnswer.isEmpty && !vm.showThinking }

    private var statusText: String {
        if vm.showThinking || vm.isProcessing { return "Thinking…" }
        if vm.isListening { return "Listening" }
        if vm.micStatus == "NO MIC" { return "No mic" }
        return "Ready"
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar

            if !vm.transcript.isEmpty {
                divider
                transcriptRow
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
        .gesture(DragGesture().onChanged { value in
            guard let w = AnswerOverlayWindow.shared else { return }
            let o = w.frame.origin
            w.setFrameOrigin(NSPoint(x: o.x + value.translation.width,
                                     y: o.y - value.translation.height))
            w.topEdgeY = w.frame.maxY       // remember new top so resizes stay put
        })
    }

    // ── Status bar (always visible) ──
    private var statusBar: some View {
        HStack(spacing: 9) {
            Circle().fill(vm.micColor).frame(width: 8, height: 8)
            Text(statusText)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white)
            if isIdle {
                Text("· press Space to listen")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
            }
            Spacer()
            Image(systemName: "eye.fill")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.22))
            Button(action: { vm.exitCamera() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.45))
            }
            .buttonStyle(.plain)
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
            Text(vm.transcript)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color(hex: "#cbd5e1"))
                .lineLimit(nil)               // show the FULL question — never truncate
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
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
                    } else if vm.isProcessing {
                        // Streaming: plain text for smooth rendering (no parse/highlight cost)
                        Text(vm.aiAnswer)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.6), radius: 3, x: 0, y: 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        // Finished: rich renderer (styled headers + highlighted code)
                        AnswerContentView(raw: vm.aiAnswer, fontSize: 17, codeFontSize: 12)
                    }
                }
                .padding(16)
                .id("eyeContent")
            }
            .frame(height: 300)
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
