import SwiftUI

// ══════════════════════════════════════════════════════════════════════════
// The one pill of the top bar (Windows MAC_CATCHUP, 2026-10-19: decided and locked by the owner on Windows, "Mac: match this layout"), shared by
// the main window and the compact bar. "Auto" or "Manual": how it answers (one listening mode since Windows 1.0.45: there is no Interview or
// Practice any more). It opens a menu with that choice and the window choices (Compact and Pin on top, or Full window when it is opened from the compact bar). A popover, so it is a
// window of its own (Stealth Mode covers it, see StealthWindows) that stays open until a choice is made, a click lands elsewhere, or Esc.
// ══════════════════════════════════════════════════════════════════════════
struct ModePill: View {
    @Environment(MainViewModel.self) var vm
    /// True in the compact bar: the window choice is then "Full window", and Pin on top is left out.
    let inCompact: Bool
    @State private var showMenu = false

    var body: some View {
        let answers = vm.listeningMode == .auto ? "Auto" : "Manual"
        Button(action: { showMenu.toggle() }) {
            HStack(spacing: 6) {
                Image(systemName: vm.listeningMode == .auto ? "bolt.fill" : "hand.tap.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(answers).font(.system(size: 11.5, weight: .semibold))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundColor(Color(hex: "#64748b"))
            }
            .foregroundColor(.white)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 12).padding(.vertical, inCompact ? 5 : 8)
            .background(Capsule().fill(Color(hex: "#161b22")))
            .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Mode menu: \(answers)")
        .help("How Replysis answers, and the window. It always hears the meeting and your microphone, and answers the interviewer.")
        .popover(isPresented: $showMenu, arrowEdge: .bottom) { menu }
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("HOW IT ANSWERS")
            row(icon: "bolt.fill", title: "Auto", subtitle: "Answers as soon as the question ends. Auto or Manual: Control Shift A", selected: vm.listeningMode == .auto) {
                vm.setListeningMode(.auto)
            }
            row(icon: "hand.tap.fill", title: "Manual", subtitle: "Press Space to listen, and again to answer", selected: vm.listeningMode == .manual) {
                vm.setListeningMode(.manual)
            }
            heading("WINDOW")
            if inCompact {
                row(icon: "rectangle.expand.vertical", title: "Full window", subtitle: "Back to the full window. Control Shift C", selected: false) {
                    vm.toggleCamera()
                }
            } else {
                row(icon: "rectangle.compress.vertical", title: "Compact", subtitle: "A small bar instead of the full window. Control Shift C", selected: vm.showCameraOverlay) {
                    vm.toggleCamera()
                }
                row(icon: vm.isPinnedOnTop ? "pin.fill" : "pin", title: "Pin on top", subtitle: "Keep the window above other apps", selected: vm.isPinnedOnTop) {
                    vm.togglePin()
                }
            }
        }
        .padding(.vertical, 8)
        .frame(width: 300)
        .background(Color(hex: "#0b1018"))
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .bold)).tracking(0.6)
            .foregroundColor(Color(hex: "#64748b"))
            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 4)
    }

    private func row(icon: String, title: String, subtitle: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: { action(); showMenu = false }) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 12)).frame(width: 18)
                    .foregroundColor(selected ? Color(hex: "#4ade80") : Color(hex: "#94a3b8"))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundColor(.white)
                    Text(subtitle).font(.system(size: 10.5)).foregroundColor(Color(hex: "#7c8aa0"))
                }
                Spacer(minLength: 6)
                if selected { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(Color(hex: "#4ade80")) }
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
