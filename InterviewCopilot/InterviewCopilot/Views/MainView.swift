import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MainView: View {
    @Environment(MainViewModel.self) var vm
    @State private var resumeCollapsed = false
    @State private var showSettings    = false
    @State private var showSessions    = false
    @State private var showLogin       = false
    @State private var showSignOutConfirm = false
    @State private var showDebugLog    = false
    @State private var showProfileMenu = false
    @State private var resumeSaveTimer: Timer?
    @State private var hintsSaveTimer: Timer?
    @State private var resumeOpen = true   // false = collapsed to a compact "loaded" card
    @State private var jobOpen = true      // false = Job & Company collapsed to a card
    @State private var showResumeLibrary = false
    @FocusState private var focusedField: FocusField?
    @State private var askText = ""   // unified Ask / Guide bar input
    @State private var jobSaveTimer: Timer?
    @State private var leftTab = 0   // 0 = Resume, 1 = Job & Company

    var body: some View {
        // ── Outer glass container — matches original #B3080C14 border with CornerRadius 14
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(red: 9/255, green: 13/255, blue: 21/255).opacity(vm.mainWindowOpacity))
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.13), lineWidth: 1)

            VStack(spacing: 0) {
                headerBar
                    .background(Color(red: 13/255, green: 17/255, blue: 23/255).opacity(0.85))
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14))
                Divider().background(Color.white.opacity(0.1))
                if vm.showHotkeyBanner { hotkeyUpsellBanner }
                bodyArea
            }
        }
        .ignoresSafeArea()
        .onAppear {
            vm.onAppear()
            // Start collapsed if already filled — don't make the user hide them manually
            resumeOpen = vm.resumeText.isEmpty
            jobOpen = jobIsEmpty
        }
        .onChange(of: vm.resumeLocked) {
            // Interview started (first answer requested) → tuck away resume & job panels
            // for a clean, focused view. The user can reopen them anytime.
            if vm.resumeLocked { withAnimation { resumeOpen = false; jobOpen = false } }
        }
        .onChange(of: focusedField) { vm.isEditingText = focusedField != nil }
        .onKeyPress(.space) {
            // While typing in a field, let the space through (type it); otherwise toggle mic.
            if vm.isEditingText { return .ignored }
            vm.handleSpacePress(source: "KEYBOARD")
            return .handled
        }
        .onReceive(NotificationCenter.default.publisher(for: .showDebugLog)) { _ in showDebugLog = true }
        // Pressing Space (or tapping the mic) while signed out routes here → open sign-in.
        .onReceive(NotificationCenter.default.publisher(for: .showLogin)) { _ in showLogin = true }
        .sheet(isPresented: $showSettings)  { SettingsView() }
        .sheet(isPresented: $showSessions)  { SessionsView() }
        .sheet(isPresented: $showLogin)     { LoginView() }
        .sheet(isPresented: $showDebugLog)  { DebugLogView() }
        // OPTIONAL hotkey setup (fixed-size sheet so it can never stretch the window).
        // Shown only when the user taps "Enable Space bar" — the app is fully usable
        // without it via the mic button, so this is a dismissible upgrade, never a wall.
        .sheet(isPresented: Bindable(vm).needsPermissionSetup) { PermissionSetupView() }
    }

    // ── Optional "enable Space bar" upsell — subtle, dismissible, never blocks ──
    var hotkeyUpsellBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "keyboard")
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "#38bdf8"))
            Text("Tip: enable the global Space bar so it works even while Zoom or your browser is in front.")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color(hex: "#cbd5e1"))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 8)
            Button(action: { vm.beginHotkeyUpgrade() }) {
                Text("Enable")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(LinearGradient(colors: [Color(hex: "#1d4ed8"), Color(hex: "#1e40af")],
                                               startPoint: .leading, endPoint: .trailing))
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            Button(action: { vm.dismissHotkeyBanner() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Color(hex: "#64748b"))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color(hex: "#0c2033"))
        .overlay(Rectangle().fill(Color(hex: "#38bdf8").opacity(0.15)).frame(height: 1), alignment: .bottom)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // ══════════════════════════════════════════════
    // MARK: — HEADER  (matches original exactly)
    // ══════════════════════════════════════════════
    var headerBar: some View {
        ZStack {
            // CENTER: primary mic control — perfectly centered regardless of side widths
            micControl

            HStack(spacing: 0) {
                brandView
                Spacer()
                rightCluster
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 64)
    }

    // ── Brand (left) ───────────────────────────────────────────────
    var brandView: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(LinearGradient(colors: [Color(hex: "#0e3a5a"), Color(hex: "#0a2236")],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 34, height: 34)
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Color(hex: "#38bdf8"))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Interview Copilot")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                Text("by CoopilotX")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(Color(hex: "#3d4d5f"))
            }
        }
    }

    // ── Mic hero (center) ──────────────────────────────────────────
    var micControl: some View {
        let listening = vm.isListening
        return Button(action: micAction) {
            HStack(spacing: 11) {
                ZStack {
                    Circle()
                        .fill(Color(hex: "#0c1220"))
                        .frame(width: 42, height: 42)
                        .overlay(Circle().stroke(vm.micColor, lineWidth: 2))
                    Image(systemName: listening ? "mic.fill" : "mic.slash.fill")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(listening ? Color(hex: "#4ade80") : .white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle().fill(vm.micColor).frame(width: 7, height: 7)
                        Text(vm.micStatus)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                    }
                    Text(micHintText)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(micHintColor)
                }
            }
            .padding(.leading, 8).padding(.trailing, 16).padding(.vertical, 6)
            .background(
                Capsule().fill(Color.white.opacity(0.035))
                    .overlay(Capsule().stroke(
                        listening ? Color(hex: "#4ade80").opacity(0.45) : Color.white.opacity(0.08),
                        lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .help(vm.micStatus == "NO MIC" ? "Tap to retry microphone" : "Press SPACE to toggle mic")
    }

    var micHintText: String {
        if vm.isListening { return "Press SPACE again to get answer" }
        if vm.micStatus == "NO MIC" { return "Tap to retry" }
        return "Press SPACE to listen"
    }
    var micHintColor: Color {
        if vm.isListening { return Color(hex: "#4ade80") }
        if vm.micStatus == "NO MIC" { return Color(hex: "#6b7280") }
        return Color(hex: "#3d4d5f")
    }
    func micAction() {
        if vm.micStatus == "NO MIC" { vm.retryMic() }
        else { vm.handleSpacePress(source: "BUTTON") }
    }

    // ── Right cluster: interview actions + profile + window ────────
    var rightCluster: some View {
        HStack(spacing: 8) {
            // Primary interview action — Screen Analyze
            Button(action: { vm.runScreenAnalysis() }) {
                HStack(spacing: 6) {
                    if vm.isScreenAnalyzing {
                        ProgressView().scaleEffect(0.5).frame(width: 13, height: 13)
                    } else {
                        Image(systemName: "viewfinder").font(.system(size: 12, weight: .semibold))
                    }
                    Text(vm.isScreenAnalyzing ? "Analyzing…" : "Analyze")
                        .font(.system(size: 12, weight: .semibold))
                    Text("F9")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color(hex: "#7dd3fc"))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color(hex: "#0c2a40"))
                        .cornerRadius(4)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(
                    Capsule().fill(LinearGradient(
                        colors: [Color(hex: "#0e4c7c"), Color(hex: "#0a3a5e")],
                        startPoint: .top, endPoint: .bottom)))
                .overlay(Capsule().stroke(Color(hex: "#1e90d8").opacity(0.4), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Analyze your screen with AI (F9)")

            // Camera overlay toggle
            toolButton(icon: "eye.fill", active: vm.showCameraOverlay, help: "Toggle Eye Mode — compact answer overlay") {
                vm.toggleCamera()
            }

            // Pin on top — float above other apps (for the actual interview)
            toolButton(icon: vm.isPinnedOnTop ? "pin.fill" : "pin",
                       active: vm.isPinnedOnTop,
                       help: "Pin on top — keep the window floating above other apps") {
                vm.togglePin()
            }

            // Session timer (live)
            if vm.sessionTimerVisible {
                HStack(spacing: 5) {
                    Image(systemName: "record.circle").font(.system(size: 10)).foregroundColor(Color(hex: "#ef4444"))
                    Text(vm.sessionTimerText)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(hex: "#cbd5e1"))
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Capsule().fill(Color.white.opacity(0.04)))
                .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
            }

            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1, height: 22)
                .padding(.horizontal, 2)

            // Profile / account  → opens rich dropdown
            if vm.showProfile {
                profileButton
            } else {
                Button(action: { showLogin = true }) {
                    HStack(spacing: 5) {
                        Image(systemName: "bolt.fill").font(.system(size: 11))
                        Text("Sign In").font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(Color(hex: "#38bdf8"))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Color(hex: "#0c2540")))
                    .overlay(Capsule().stroke(Color(hex: "#2255AA"), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            // Close (quit). No minimize: as an accessory app there's no Dock icon
            // to restore from — use the opacity slider to fade it instead.
            windowDot(icon: "xmark", color: "#6b3a3a") {
                NSApplication.shared.terminate(nil)
            }
            .padding(.leading, 2)
        }
    }

    // ── Profile button + dropdown popover ──────────────────────────
    var profileButton: some View {
        Button(action: { showProfileMenu.toggle() }) {
            HStack(spacing: 8) {
                profileAvatar(size: 32, fontSize: 12)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(Color(hex: "#475569"))
            }
            .padding(.leading, 4).padding(.trailing, 8).padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.04)))
            .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Account")
        .popover(isPresented: $showProfileMenu, arrowEdge: .bottom) {
            profileDropdown
        }
    }

    func profileAvatar(size: CGFloat, fontSize: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: vm.session.isUnlimited
                        ? [Color(hex: "#3b1d6e"), Color(hex: "#1a0f2e")]
                        : [Color(hex: "#1e3a5f"), Color(hex: "#0c2236")],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size, height: size)
                .overlay(Circle().stroke(
                    vm.session.isUnlimited ? Color(hex: "#a78bfa").opacity(0.6) : Color(hex: "#38bdf8").opacity(0.4),
                    lineWidth: 1.5))
            Text(vm.avatarInitials)
                .font(.system(size: fontSize, weight: .bold))
                .foregroundColor(vm.session.isUnlimited ? Color(hex: "#c4b5fd") : Color(hex: "#7dd3fc"))
        }
    }

    var profileDropdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Identity header
            HStack(spacing: 12) {
                profileAvatar(size: 46, fontSize: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.profileName)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                    Text(vm.session.email)
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#64748b"))
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(16)

            // Plan / credits card
            creditsCard
                .padding(.horizontal, 16)
                .padding(.bottom, 14)

            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)

            // Appearance — live window opacity control
            opacitySlider
                .padding(.horizontal, 16).padding(.vertical, 11)

            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)

            // Menu items
            VStack(spacing: 0) {
                menuRow(icon: "gearshape.fill", title: "Settings",
                        subtitle: "AI model · audio · appearance") {
                    showProfileMenu = false; showSettings = true
                }
                menuRow(icon: "clock.arrow.circlepath", title: "Past Sessions",
                        subtitle: "Review previous interviews") {
                    showProfileMenu = false; showSessions = true
                }
                if !vm.session.isUnlimited {
                    menuRow(icon: "bolt.fill", title: "Upgrade to Pro",
                            subtitle: "Unlimited answers", accent: Color(hex: "#a78bfa")) {
                        showProfileMenu = false
                        NSWorkspace.shared.open(URL(string: "https://coopilotxai.com/pricing")!)
                    }
                }
            }
            .padding(.vertical, 6)

            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)

            menuRow(icon: "rectangle.portrait.and.arrow.right", title: "Sign Out",
                    subtitle: nil, accent: Color(hex: "#ef4444"), destructive: true) {
                showProfileMenu = false; vm.signOut()
            }
            .padding(.vertical, 6)
        }
        .frame(width: 296)
        .background(Color(hex: "#0b1018"))
    }

    var creditsCard: some View {
        Group {
            if vm.session.isUnlimited {
                HStack(spacing: 11) {
                    Text("👑").font(.system(size: 20))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pro Plan")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(Color(hex: "#c4b5fd"))
                        Text("Unlimited AI answers")
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "#7c6ba8"))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 11)
                        .fill(LinearGradient(colors: [Color(hex: "#241141"), Color(hex: "#150a26")],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color(hex: "#7c3aed").opacity(0.4), lineWidth: 1))
            } else {
                HStack(spacing: 11) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 16))
                        .foregroundColor(creditsAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(vm.session.credits) credits")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(creditsAccent)
                        Text("\(vm.session.plan.capitalized) plan")
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "#64748b"))
                    }
                    Spacer(minLength: 0)
                    Button(action: {
                        showProfileMenu = false
                        NSWorkspace.shared.open(URL(string: "https://coopilotxai.com/pricing")!)
                    }) {
                        Text("Top up")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(Color(hex: "#1a6b3a")))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 11).fill(Color.white.opacity(0.03)))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.white.opacity(0.08), lineWidth: 1))
            }
        }
    }

    var creditsAccent: Color {
        let c = vm.session.credits
        if c > 20 { return Color(hex: "#4ade80") }
        if c > 5  { return Color(hex: "#f59e0b") }
        return Color(hex: "#ef4444")
    }

    // Live window-opacity slider — drag down for more transparency / stealth,
    // up for maximum readability. Persists on release.
    var opacitySlider: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: 12)).foregroundColor(Color(hex: "#64748b"))
                Text("Window opacity")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(Color(hex: "#cbd5e1"))
                Spacer()
                Text("\(Int(vm.mainWindowOpacity * 100))%")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(hex: "#38bdf8"))
            }
            Slider(value: Bindable(vm).mainWindowOpacity, in: 0.0...1.0,
                   onEditingChanged: { editing in if !editing { vm.saveSettings() } })
                .controlSize(.small)
                .tint(Color(hex: "#38bdf8"))
        }
    }

    // ══════════════════════════════════════════════
    // MARK: — BODY (resume | arrow | right)
    // ══════════════════════════════════════════════
    var bodyArea: some View {
        HStack(spacing: 0) {
            // Resume panel
            if !resumeCollapsed {
                resumePanel
                    .frame(width: 270)
                    .frame(maxHeight: .infinity)
            }

            // Toggle arrow
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { resumeCollapsed.toggle() } }) {
                Text(resumeCollapsed ? "▶" : "◀")
                    .font(.system(size: 14))
                    .foregroundColor(Color(hex: "#94A3B8"))
                    .frame(width: 22)
                    .frame(maxHeight: .infinity)
                    .background(Color(hex: "#1A1F2E"))
            }
            .buttonStyle(.plain)

            // Right panel
            rightPanel
        }
        .padding(22)
        .padding(.top, 0)
    }

    // ══════════════════════════════════════════════
    // MARK: — RESUME PANEL
    // ══════════════════════════════════════════════
    var resumePanel: some View {
        VStack(spacing: 0) {
            // Tabs: Resume / Job & Company
            HStack(spacing: 6) {
                leftTabButton(title: "Resume", icon: "doc.text.fill", index: 0)
                leftTabButton(title: "Job & Company", icon: "target", index: 1)
            }
            .padding(.bottom, 10)

            if leftTab == 0 { resumeTabContent } else { jobTabContent }

            // Ask / Guide composer sits right under the resume controls — one tidy group
            // anchored at the TOP of the sidebar, so any empty space falls at the bottom
            // (reads as "end of content") instead of floating in the middle.
            liveHintsBox(expanded: leftTab == 0 && !resumeOpen && !vm.resumeText.isEmpty)
                .padding(.top, 14)
        }
        .padding(.trailing, 14)
    }

    // ── Saved-resumes picker popover ──
    func resumeLibraryPopover() -> some View {
        let names = vm.savedResumes
        return VStack(alignment: .leading, spacing: 0) {
            Text("SAVED RESUMES")
                .font(.system(size: 10, weight: .bold)).tracking(1)
                .foregroundColor(Color(hex: "#64748b"))
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            if names.isEmpty {
                Text("No saved resumes yet")
                    .font(.system(size: 12)).foregroundColor(Color(hex: "#4b5563"))
                    .padding(.horizontal, 14).padding(.bottom, 14)
            }
            ForEach(names, id: \.self) { name in
                HStack(spacing: 9) {
                    Image(systemName: "doc.text.fill").font(.system(size: 12)).foregroundColor(Color(hex: "#38bdf8"))
                    Text(name).font(.system(size: 12, weight: .medium)).foregroundColor(.white).lineLimit(1)
                    Spacer(minLength: 8)
                    Button(action: { vm.deleteSavedResume(name); showResumeLibrary = vm.savedResumes.isEmpty ? false : true }) {
                        Image(systemName: "trash").font(.system(size: 11)).foregroundColor(Color(hex: "#6b7280"))
                    }
                    .buttonStyle(.plain)
                    .help("Delete this saved resume")
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .contentShape(Rectangle())
                .onTapGesture {
                    vm.loadSavedResume(name)
                    showResumeLibrary = false
                    withAnimation { resumeOpen = false }
                }
                Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
            }
        }
        .frame(width: 264)
        .background(Color(hex: "#0b1018"))
    }

    // ── Unified Ask / Guide bar (always visible under the tabs) ──
    // Type a question + Enter → answer it instantly (Parakeet-style, and the 100%-
    // accuracy fallback when speech mishears). Or 📌 Pin → keep it as context that
    // steers EVERY answer (Live Hints). One bar, both powers.
    func liveHintsBox(expanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10)).foregroundColor(Color(hex: "#fbbf24"))
                Text("ASK or GUIDE")
                    .font(.system(size: 10, weight: .bold)).tracking(0.4)
                    .foregroundColor(Color(hex: "#c79a3c"))
                Text("· type to ask · 📌 to remember")
                    .font(.system(size: 9)).foregroundColor(Color(hex: "#6b5630")).italic()
                Spacer()
            }

            // Big composer — a real text area that FILLS the sidebar's remaining height,
            // so the panel reads as full and intentional, not a tiny field at an edge.
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(red: 26/255, green: 20/255, blue: 6/255).opacity(vm.mainWindowOpacity))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: "#fbbf24").opacity(0.28), lineWidth: 1))
                if askText.isEmpty {
                    Text("Ask a question to answer it instantly,\nor add context the AI should remember…")
                        .font(.system(size: 12)).foregroundColor(Color(hex: "#6b5a2a")).italic()
                        .padding(.horizontal, 13).padding(.vertical, 13).allowsHitTesting(false)
                }
                TextEditor(text: $askText)
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "#fde68a"))
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .padding(9)
                    .focused($focusedField, equals: .hints)
            }
            .frame(maxHeight: .infinity)   // ← fills the sidebar's leftover vertical space

            // Pinned context (the live hints that steer every answer)
            if !vm.liveHints.isEmpty {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "pin.fill").font(.system(size: 8))
                        .foregroundColor(Color(hex: "#b08930")).padding(.top, 2)
                    Text(vm.liveHints)
                        .font(.system(size: 10)).foregroundColor(Color(hex: "#cbb06a"))
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(action: { vm.liveHints = ""; vm.saveHints() }) {
                        Text("Clear").font(.system(size: 9)).foregroundColor(Color(hex: "#6b7280"))
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: "#fbbf24").opacity(0.06)))
            }

            // Actions row — Pin (secondary) + Ask (primary, fills the row), anchored at the bottom.
            HStack(spacing: 8) {
                Button(action: { vm.addHint(askText); askText = "" }) {
                    HStack(spacing: 4) {
                        Image(systemName: "pin.fill").font(.system(size: 11, weight: .bold))
                        Text("Pin").font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(Color(hex: "#fbbf24"))
                    .frame(height: 38).padding(.horizontal, 16)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: "#3a2e0a")))
                }
                .buttonStyle(.plain).help("Pin as context the AI remembers for every answer")
                .disabled(askText.trimmingCharacters(in: .whitespaces).isEmpty)

                Button(action: { submitAsk() }) {
                    HStack(spacing: 5) {
                        Text("Ask").font(.system(size: 13, weight: .bold))
                        Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity).frame(height: 38)
                    .background(RoundedRectangle(cornerRadius: 10)
                        .fill(askText.trimmingCharacters(in: .whitespaces).isEmpty
                              ? Color(hex: "#1e3a8a").opacity(0.4) : Color(hex: "#2563eb")))
                }
                .buttonStyle(.plain).help("Answer this question now")
                .disabled(askText.trimmingCharacters(in: .whitespaces).isEmpty || vm.isProcessing)
            }
        }
        .frame(maxHeight: .infinity)
    }

    // Send the bar's text as an immediate question, then clear + unfocus.
    private func submitAsk() {
        let t = askText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        vm.askManually(t)
        askText = ""
        focusedField = nil
    }

    func leftTabButton(title: String, icon: String, index: Int) -> some View {
        let active = leftTab == index
        return Button(action: { withAnimation(.easeOut(duration: 0.12)) { leftTab = index } }) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(active ? .white : Color(hex: "#4b5563"))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(active ? Color(hex: "#0c2240") : Color.white.opacity(0.03))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(
                active ? Color(hex: "#0e4c7c") : Color.white.opacity(0.06), lineWidth: 1))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    // ── Resume tab ──
    var resumeTabContent: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("📄 RESUME")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color(hex: "#2A4A6A"))
                    Text("Your background — set before the interview")
                        .font(.system(size: 8))
                        .foregroundColor(Color(hex: "#1a2a3a"))
                        .italic()
                        .lineLimit(1)   // truncate instead of squeezing the buttons
                }
                Spacer()
                // Saved-resumes picker — switch between previously uploaded resumes
                if !vm.savedResumes.isEmpty {
                    Button(action: { showResumeLibrary.toggle() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "clock.arrow.circlepath").font(.system(size: 10))
                            Text("Saved").font(.system(size: 11))
                        }
                        .foregroundColor(Color(hex: "#94A3B8"))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Color(hex: "#1A1F2E"))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.2), lineWidth: 1))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .help("Switch between saved resumes")
                    .popover(isPresented: $showResumeLibrary, arrowEdge: .bottom) {
                        resumeLibraryPopover()
                    }
                }
                // Collapse / edit toggle — only once a resume exists
                if !vm.resumeText.isEmpty {
                    Button(action: { withAnimation(.easeOut(duration: 0.15)) { resumeOpen.toggle() } }) {
                        Image(systemName: resumeOpen ? "chevron.up" : "pencil").font(.system(size: 10, weight: .bold))
                            .foregroundColor(Color(hex: "#94A3B8"))
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .background(Color(hex: "#1A1F2E"))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.2), lineWidth: 1))
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .help(resumeOpen ? "Hide resume" : "Edit resume")
                }
                Button(action: uploadResume) {
                    HStack(spacing: 5) {
                        Text("⬆").font(.system(size: 11))
                        Text("Upload").font(.system(size: 11)).lineLimit(1)
                    }
                    .fixedSize(horizontal: true, vertical: false)   // never wrap "Upload"
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color(hex: "#1A1F2E"))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.2), lineWidth: 1))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .foregroundColor(Color(hex: "#94A3B8"))
                .help("Upload PDF, DOCX or TXT resume")
            }
            .padding(.bottom, 8)

            if resumeOpen || vm.resumeText.isEmpty {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color(red: 14/255, green: 18/255, blue: 26/255).opacity(vm.mainWindowOpacity))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12), lineWidth: 1))

                    if vm.resumeText.isEmpty {
                        Text("Paste your resume here, or drag & drop a PDF / DOCX / TXT file — or click \"Upload\".")
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "#1e3040"))
                            .italic()
                            .padding(16)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: Bindable(vm).resumeText)
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "#CBD5E1"))
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .disabled(vm.resumeLocked)
                        .opacity(vm.resumeLocked ? 0.6 : 1.0)
                        .padding(8)
                        .focused($focusedField, equals: .resume)
                        .onChange(of: vm.resumeText) { scheduleResumeSave() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if vm.resumeLocked {
                    HStack(alignment: .top, spacing: 4) {
                        Text("🔒").font(.system(size: 10))
                        Text("Locked during the interview — type anything new in Live Hints below ↓")
                            .font(.system(size: 9))
                            .foregroundColor(Color(hex: "#f59e0b"))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                    }
                    .padding(.top, 6)
                }
            } else {
                // Collapsed — compact confirmation card, frees space for Live Hints
                HStack(spacing: 11) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 20))
                        .foregroundColor(Color(hex: "#22c55e"))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Resume loaded")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                        Text("\(vm.resumeText.count) characters · tap Edit to view")
                            .font(.system(size: 9))
                            .foregroundColor(Color(hex: "#4b5563"))
                    }
                    Spacer()
                }
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(red: 10/255, green: 22/255, blue: 14/255).opacity(vm.mainWindowOpacity))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: "#22c55e").opacity(0.25), lineWidth: 1))
                )
            }
        }
    }

    private var jobIsEmpty: Bool {
        vm.companyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        vm.jobDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // ── Job & Company tab ──
    var jobTabContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("🎯 TARGET ROLE")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color(hex: "#2A4A6A"))
                    Text("Tailors every answer to this role")
                        .font(.system(size: 8))
                        .foregroundColor(Color(hex: "#1a2a3a"))
                        .italic()
                }
                Spacer()
                if !jobIsEmpty {
                    Button(action: { withAnimation(.easeOut(duration: 0.15)) { jobOpen.toggle() } }) {
                        HStack(spacing: 4) {
                            Image(systemName: jobOpen ? "chevron.up" : "pencil").font(.system(size: 9, weight: .bold))
                            Text(jobOpen ? "Hide" : "Edit").font(.system(size: 11))
                        }
                        .foregroundColor(Color(hex: "#94A3B8"))
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Color(hex: "#1A1F2E"))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.2), lineWidth: 1))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            }

            if !jobOpen && !jobIsEmpty {
                HStack(spacing: 11) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 20)).foregroundColor(Color(hex: "#22c55e"))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(vm.companyName.isEmpty ? "Role details saved" : "Targeting \(vm.companyName)")
                            .font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                        Text("tap Edit to view").font(.system(size: 9)).foregroundColor(Color(hex: "#4b5563"))
                    }
                    Spacer()
                }
                .padding(12).frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(red: 10/255, green: 22/255, blue: 14/255).opacity(vm.mainWindowOpacity))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: "#22c55e").opacity(0.25), lineWidth: 1))
                )
            } else {

            VStack(alignment: .leading, spacing: 4) {
                Text("COMPANY")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(Color(hex: "#3d4d5f")).tracking(1)
                TextField("e.g. Stripe", text: Bindable(vm).companyName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Color(red: 14/255, green: 18/255, blue: 26/255).opacity(vm.mainWindowOpacity))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.12), lineWidth: 1))
                    .cornerRadius(8)
                    .focused($focusedField, equals: .company)
                    .onChange(of: vm.companyName) { scheduleJobSave() }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("JOB DESCRIPTION")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(Color(hex: "#3d4d5f")).tracking(1)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(red: 14/255, green: 18/255, blue: 26/255).opacity(vm.mainWindowOpacity))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.12), lineWidth: 1))
                    if vm.jobDescription.isEmpty {
                        Text("Paste the job description — responsibilities, required skills, tech stack. The AI connects your answers to exactly what this role needs, and nails \"why this company\".")
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "#1e3040"))
                            .italic()
                            .padding(14)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: Bindable(vm).jobDescription)
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "#CBD5E1"))
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .padding(7)
                        .focused($focusedField, equals: .job)
                        .onChange(of: vm.jobDescription) { scheduleJobSave() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            }   // end else (expanded job fields)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // ══════════════════════════════════════════════
    // MARK: — RIGHT PANEL (AI 2/3 + Transcript 1/3)
    // ══════════════════════════════════════════════
    var rightPanel: some View {
        VStack(spacing: 14) {

            // AI Answer box — 2/3 height (matches original)
            VStack(spacing: 0) {
                // Toolbar row inside AI box
                HStack {
                    // Label
                    HStack(spacing: 6) {
                        Text("🤖  AI Answer")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Color(hex: "#38BDF8"))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color(hex: "#0a0f1e"))
                    .cornerRadius(6)

                    // STAR badge — lights up when the answer used STAR structure (behavioral Q)
                    if vm.answerIsBehavioral && !vm.aiAnswer.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "star.fill").font(.system(size: 8))
                            Text("STAR").font(.system(size: 9, weight: .bold)).tracking(0.5)
                        }
                        .foregroundColor(Color(hex: "#fbbf24"))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color(hex: "#241a06"))
                        .overlay(Capsule().stroke(Color(hex: "#fbbf24").opacity(0.5), lineWidth: 1))
                        .clipShape(Capsule())
                        .help("Behavioral question — answer follows STAR structure (Situation, Task, Action, Result)")
                        .transition(.scale.combined(with: .opacity))
                    }

                    Spacer()

                    // Thinking indicator
                    if vm.showThinking {
                        HStack(spacing: 4) {
                            ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                            Text(vm.thinkingText)
                                .font(.system(size: 12).italic())
                                .foregroundColor(Color(hex: "#38BDF8"))
                            Text("· F8 all screens  ·  F9 primary")
                                .font(.system(size: 11))
                                .foregroundColor(Color(hex: "#334466"))
                        }
                        Spacer()
                    }

                    // Action buttons
                    HStack(spacing: 6) {
                        // Answer length: Concise ⇄ Detailed
                        Button(action: { vm.conciseAnswers.toggle(); vm.saveSettings() }) {
                            HStack(spacing: 4) {
                                Image(systemName: vm.conciseAnswers ? "bolt.fill" : "text.alignleft")
                                    .font(.system(size: 10, weight: .semibold))
                                Text(vm.conciseAnswers ? "Concise" : "Detailed")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundColor(vm.conciseAnswers ? Color(hex: "#fbbf24") : Color(hex: "#94A3B8"))
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(vm.conciseAnswers ? Color(hex: "#241a06") : Color(hex: "#1A1F2E"))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(
                                vm.conciseAnswers ? Color(hex: "#fbbf24").opacity(0.4) : Color.white.opacity(0.2),
                                lineWidth: 1))
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                        .help(vm.conciseAnswers
                              ? "Concise — short, spoken-length answers. Tap for detailed."
                              : "Detailed — full structured answers. Tap for concise.")

                        ghostBtn("📋 Copy") { copyAnswer() }
                        ghostBtn("✕ Clear") { vm.clearAnswer() }
                        Button(action: { vm.newSession() }) {
                            Text("＋ New Session")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Color(hex: "#1a6b3a"))
                                .cornerRadius(10)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 10)

                // Answer text
                ScrollViewReader { proxy in
                    ScrollView {
                        Group {
                            if vm.aiAnswer.isEmpty {
                                Text(vm.aiAnswerHint)
                                    .font(.system(size: 15))
                                    .foregroundColor(Color(hex: "#94A3B8").opacity(0.7))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else if vm.isProcessing {
                                // While streaming: plain text only — no parsing/highlighting
                                // overhead, so tokens render smoothly instead of in janky bursts.
                                Text(vm.aiAnswer)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.white)
                                    .shadow(color: .black.opacity(0.6), radius: 3, x: 0, y: 1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            } else {
                                // Finished: apply the rich renderer (headers + highlighted code)
                                AnswerContentView(raw: vm.aiAnswer)
                            }
                        }
                        .padding(.bottom, 4)
                        .id("aiContent")
                    }
                    // Jump to the TOP when a NEW answer starts so you read from the
                    // beginning. Do NOT auto-follow to the bottom while it streams.
                    .onChange(of: vm.answerEpoch) {
                        proxy.scrollTo("aiContent", anchor: .top)
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity)
            .frame(maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(red: 11/255, green: 17/255, blue: 30/255).opacity(vm.mainWindowOpacity))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(hex: "#38bdf8").opacity(0.22), lineWidth: 1))
            )

            // Transcript box — 1/3 height (matches original)
            VStack(spacing: 0) {
                // Hotkey bar
                HStack {
                    Text("INTERVIEWER")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color(hex: "#2A4A6A"))

                    Spacer()

                    HStack(spacing: 6) {
                        hotKeyBadge("SPACE · listen → answer", color: "#38BDF8", bg: "#0D1B2E")
                        hotKeyBadge("F8 / F9 · analyze screen", color: "#4ade80", bg: "#0D2E0D")
                        hotKeyBadge("F12 · debug", color: "#a78bfa", bg: "#1a0f2e")
                    }
                }
                .padding(.bottom, 8)

                // Transcript or hint
                ScrollViewReader { proxy in
                    ScrollView {
                        if vm.transcript.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: "waveform")
                                    .font(.system(size: 14, weight: .light))
                                    .foregroundColor(Color(hex: "#33506f"))
                                Text("Your conversation appears here as you speak")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(Color(hex: "#33506f"))
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 6)
                        } else {
                            Text(vm.transcript)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .shadow(color: .black.opacity(0.6), radius: 3, x: 0, y: 1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id("transcriptBottom")
                        }
                    }
                    .frame(height: 64)
                    .onChange(of: vm.transcript) {
                        withAnimation { proxy.scrollTo("transcriptBottom", anchor: .bottom) }
                    }
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(red: 14/255, green: 18/255, blue: 26/255).opacity(vm.mainWindowOpacity))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12), lineWidth: 1))
            )
        }
    }

    // ══════════════════════════════════════════════
    // MARK: — HELPERS
    // ══════════════════════════════════════════════

    func iconBtn(_ icon: String, help: String = "", action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(icon).font(.system(size: 15))
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(Color(hex: "#1A1F2E"))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.2), lineWidth: 1))
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // SF-symbol tool button (icon only) with active state — for the header right cluster
    func toolButton(icon: String, active: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(active ? Color(hex: "#38bdf8") : Color(hex: "#94A3B8"))
                .frame(width: 36, height: 36)
                .background(Capsule().fill(active ? Color(hex: "#0c2540") : Color.white.opacity(0.04)))
                .overlay(Capsule().stroke(
                    active ? Color(hex: "#38bdf8").opacity(0.5) : Color.white.opacity(0.08),
                    lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // Small circular window control (minimize / close)
    func windowDot(icon: String, color: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(Color(hex: "#94A3B8"))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(0.05)))
                .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // Row inside the profile dropdown
    func menuRow(icon: String, title: String, subtitle: String?,
                 accent: Color = Color(hex: "#94A3B8"), destructive: Bool = false,
                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(accent)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(destructive ? Color(hex: "#ef4444") : .white)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "#64748b"))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowButtonStyle())
    }

    func ghostBtn(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "#94A3B8"))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color(hex: "#1A1F2E"))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.2), lineWidth: 1))
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    func hotKeyBadge(_ label: String, color: String, bg: String) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(Color(hex: color))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color(hex: bg))
            .cornerRadius(5)
    }

    func copyAnswer() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(vm.aiAnswer, forType: .string)
    }

    func creditsTapped() {
        if vm.session.credits == 0 && !vm.session.isUnlimited {
            NSWorkspace.shared.open(URL(string: "https://coopilotxai.com/pricing")!)
        } else {
            Task { await vm.fetchCredits() }
        }
    }

    func scheduleResumeSave() {
        resumeSaveTimer?.invalidate()
        resumeSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [vm] _ in
            Task { @MainActor in vm.saveResume() }
        }
    }

    func scheduleHintsSave() {
        hintsSaveTimer?.invalidate()
        hintsSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [vm] _ in
            Task { @MainActor in vm.saveHints() }
        }
    }

    func scheduleJobSave() {
        jobSaveTimer?.invalidate()
        jobSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [vm] _ in
            Task { @MainActor in vm.saveJob() }
        }
    }

    func uploadResume() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .plainText,
            UTType(filenameExtension: "docx") ?? .data,
            UTType(filenameExtension: "doc")  ?? .data]
        panel.allowsMultipleSelection = false
        panel.message = "Choose your resume (PDF, DOCX, or TXT)"
        if panel.runModal() == .OK, let url = panel.url {
            // Proper extraction for PDF/DOCX/TXT (reading a .docx/.pdf as a raw String
            // produces binary garbage — that was the bug).
            let text = ResumeParser.readResumeFile(url)
            if !text.isEmpty {
                vm.resumeText = text
                vm.saveResumeToLibrary(name: url.deletingPathExtension().lastPathComponent)
                vm.saveResume()
                withAnimation { resumeOpen = false }
            } else {
                vm.resumeText = "⚠ Couldn't read that file. Try exporting your resume as PDF or pasting the text directly."
            }
        }
    }
}

// Which text field currently has keyboard focus (so Space types instead of toggling mic)
enum FocusField: Hashable { case resume, hints, company, job }

// A parsed segment of an AI answer (for the rich coding-answer renderer)
enum AnswerBlock {
    case header(String)
    case code(String)
    case text(String)
}

func parseAnswerBlocks(_ raw: String) -> [AnswerBlock] {
    let codeTitles: Set<String> = ["SOLUTION", "QUERY", "FIX", "CODE"]
    var blocks: [AnswerBlock] = []
    var buffer: [String] = []
    var inCode = false
    func flush() {
        let joined = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !joined.isEmpty { blocks.append(inCode ? .code(joined) : .text(joined)) }
        buffer.removeAll()
    }
    for line in raw.components(separatedBy: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("━━━") && t.hasSuffix("━━━") && t.count > 6 {
            flush()
            let title = t.replacingOccurrences(of: "━", with: "").trimmingCharacters(in: .whitespaces)
            blocks.append(.header(title))
            inCode = codeTitles.contains(title.uppercased())
        } else {
            buffer.append(line)
        }
    }
    flush()
    return blocks
}

// Renders an AI answer: plain text for spoken answers; styled section headers +
// syntax-highlighted code blocks for structured screen/coding answers. Reused by the
// main window and Eye Mode.
struct AnswerContentView: View {
    let raw: String
    var fontSize: CGFloat = 15
    var codeFontSize: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(parseAnswerBlocks(raw).enumerated()), id: \.offset) { _, block in
                switch block {
                case .header(let title):
                    HStack(spacing: 7) {
                        Rectangle().fill(Color(hex: "#38bdf8")).frame(width: 3, height: 13).cornerRadius(2)
                        Text(title.uppercased())
                            .font(.system(size: 11, weight: .bold)).tracking(0.6)
                            .foregroundColor(Color(hex: "#7dd3fc"))
                    }
                    .padding(.top, 2)
                case .code(let code):
                    CodeBlockView(code: code, fontSize: codeFontSize)
                case .text(let text):
                    Text(text)
                        .font(.system(size: fontSize, weight: .semibold))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.6), radius: 3, x: 0, y: 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CodeBlockView: View {
    let code: String
    var fontSize: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top bar: language tag + copy
            HStack {
                Text(SyntaxHighlighter.detectLanguage(code))
                    .font(.system(size: 9, weight: .bold)).tracking(0.6)
                    .foregroundColor(Color(hex: "#64748b"))
                Spacer()
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "doc.on.doc").font(.system(size: 9))
                        Text("Copy code").font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(Color(hex: "#7dd3fc"))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color(hex: "#0c2a40"))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .help("Copy the code")
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(Color.white.opacity(0.03))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(SyntaxHighlighter.highlight(code, size: fontSize))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 5/255, green: 9/255, blue: 16/255)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: "#1e90d8").opacity(0.2), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// Lightweight regex-based syntax highlighter (no external library).
enum SyntaxHighlighter {
    static func highlight(_ code: String, size: CGFloat) -> AttributedString {
        var attr = AttributedString(code)
        attr.font = .system(size: size, design: .monospaced)
        attr.foregroundColor = Color(hex: "#d6e7ff")

        let total = attr.characters.count
        func color(_ pattern: String, _ c: Color) {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return }
            let ns = code as NSString
            re.enumerateMatches(in: code, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let m = m, let r = Range(m.range, in: code) else { return }
                let start = code.distance(from: code.startIndex, to: r.lowerBound)
                let len = code.distance(from: r.lowerBound, to: r.upperBound)
                guard start >= 0, len >= 0, start + len <= total else { return }
                let lo = attr.index(attr.startIndex, offsetByCharacters: start)
                let hi = attr.index(lo, offsetByCharacters: len)
                attr[lo..<hi].foregroundColor = c
            }
        }
        // Order matters: later passes override earlier ones inside their ranges.
        color("\\b(def|class|return|if|else|elif|for|while|import|from|func|let|var|const|function|public|private|protected|static|void|new|self|this|async|await|struct|enum|switch|case|break|continue|default|do|throw|throws|try|except|finally|catch|with|as|in|is|not|and|or|interface|extends|implements|yield|lambda)\\b", Color(hex: "#c792ea"))
        color("\\b(true|false|None|True|False|null|nil|undefined)\\b", Color(hex: "#f78c6c"))
        color("\\b\\d+(\\.\\d+)?\\b", Color(hex: "#f78c6c"))
        color("\"[^\"\\n]*\"|'[^'\\n]*'", Color(hex: "#c3e88d"))
        color("(//[^\\n]*|#[^\\n]*|/\\*[\\s\\S]*?\\*/)", Color(hex: "#5f7e8c"))
        return attr
    }

    static func detectLanguage(_ code: String) -> String {
        let c = code.lowercased()
        if c.contains("select ") && c.contains(" from ") { return "SQL" }
        if c.contains("#include") || c.contains("std::") || c.contains("cout") || c.contains("printf") { return "C / C++" }
        if c.contains("public class") || c.contains("system.out") || c.contains("public static void") || c.contains("import java") { return "Java" }
        if c.contains("func ") && (c.contains("let ") || c.contains("var ")) { return "Swift" }
        if c.contains("function ") || c.contains("console.log") || c.contains("=>") || c.contains("const ") { return "JavaScript" }
        if c.contains("def ") || c.contains("elif ") || c.contains("print(") || c.contains("import ") { return "Python" }
        return "Code"
    }
}

// Hover/press highlight for profile-dropdown rows
struct MenuRowButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Color.white.opacity(configuration.isPressed ? 0.08 : (hovering ? 0.05 : 0))
            )
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
