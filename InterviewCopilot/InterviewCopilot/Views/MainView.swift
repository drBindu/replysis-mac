import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Measured height of the interviewer transcript, so the box can grow to fit it.
private struct MainTranscriptHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct MainView: View {
    /// Height the transcript actually needs; the box grows to it, up to a cap, then scrolls.
    @State private var transcriptContentHeight: CGFloat = 0
    @Environment(MainViewModel.self) var vm
    @State private var resumeCollapsed = false
    @State private var showSettings    = false
    @State private var showLogin       = false
    @State private var showSignOutConfirm = false
    @State private var showDebugLog    = false
    @State private var showProfileMenu = false
    @State private var showCreditsPopover = false
    @State private var resumeSaveTimer: Timer?
    @State private var resumeOpen = true   // false = collapsed to a compact "loaded" card
    @State private var showResumeLibrary = false
    @FocusState private var focusedField: FocusField?
    @State private var jobSaveTimer: Timer?
    @State private var resumeParseError = ""
    @State private var showResumeError = false
    @State private var dropTargeted = false   // resume drop-zone hover highlight
    @State private var didAutoSlide = false    // one-shot: auto-collapse the setup panel when the interview starts

    /// Setup is drawn SOLID. The glass backdrop exists to make the window hard to see during a
    /// call; Setup is never on screen during one, and the same transparency there only makes
    /// the page hard to read against whatever is behind it (Windows EnterSetupStep).
    private var setupOpacity: Double { vm.inSetup ? 1.0 : vm.mainWindowOpacity }

    var body: some View {
        // ── Outer glass container — matches original #B3080C14 border with CornerRadius 14
        ZStack {
            // Painted exactly like the compact overlay (CameraOverlayView:118-127), because
            // that one is right and this one was not. Compact is ONE gradient layer at the
            // slider's opacity with a single white hairline and no blur. The main window had
            // a tint, a second panel under the answer, and at one point a frosted material —
            // which is why the same slider produced a readable overlay and an unreadable
            // window. Same paint, same result.
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(
                    colors: [
                        Color(red: 3/255,  green: 7/255,  blue: 18/255).opacity(setupOpacity),
                        Color(red: 5/255,  green: 15/255, blue: 30/255).opacity(setupOpacity)
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing))

            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)

            VStack(spacing: 0) {
                headerBar
                    // Was an almost-opaque slab across the top, which cut the glass in half.
                    // A whisper of light over the same material separates it instead.
                    .background(Color.white.opacity(0.05))
                    .overlay(alignment: .top) {
                        LinearGradient(colors: [Color.white.opacity(0.10), .clear],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: 1)
                    }
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14))
                Divider().background(Color.white.opacity(0.08))
                // TRANSIENT MESSAGES GET THEIR OWN LINE. They used to sit inside the header
                // row: when one appeared there was no width left, no header tier fitted, and
                // SwiftUI drew "Read screen" over "Compact" — a broken toolbar for as long as
                // the message lasted, tidying itself when the message timed out. A separate
                // row cannot squeeze the controls, and the message is easier to read.
                transientMessageRow
                if vm.inSetup { setupPage } else { bodyArea }
            }
            if vm.showOnboarding { onboardingOverlay }
        }
        .ignoresSafeArea()
        .onChange(of: vm.appStep) {
            // Starting the interview tucks the resume column away, as Windows does. NOT animated:
            // this is a whole-page swap, and animating the column's width at the same moment
            // made the hosting view resize the window every frame until AppKit's layout-pass
            // limit aborted the process (crash on Start interview, 2026-09-30).
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { resumeCollapsed = vm.appStep == .interview }
        }
        .onAppear {
            vm.onAppear()
            vm.showOnboardingIfFirstRun()
            vm.runFlowScriptIfAny()
            // Start collapsed if already filled — don't make the user hide it manually
            resumeOpen = vm.resumeText.isEmpty
        }
        .onChange(of: vm.resumeLocked) {
            // Interview started (first answer requested) → tuck the resume away
            // for a clean, focused view. The user can reopen it anytime.
            if vm.resumeLocked { withAnimation { resumeOpen = false } }
            else { didAutoSlide = false }   // new session → re-arm the auto-slide
        }
        .onChange(of: vm.isListening) {
            // When the interview starts (first Space → listening), slide the whole
            // setup panel closed automatically for a clean, focused view. One-shot —
            // the ◀ arrow still reopens it, and it re-arms on a new session.
            if vm.isListening && !didAutoSlide {
                didAutoSlide = true
                if !resumeCollapsed {
                    withAnimation(.easeInOut(duration: 0.28)) { resumeCollapsed = true }
                }
            }
        }
        .onChange(of: focusedField) {
            vm.isEditingText = focusedField != nil
            vm.refreshHotkeyGate()   // so the global Space tap types in text boxes, not toggles
        }
        .onReceive(NotificationCenter.default.publisher(for: .showDebugLog)) { _ in showDebugLog = true }
        // Pressing Space (or tapping the mic) while signed out routes here → open sign-in.
        .onReceive(NotificationCenter.default.publisher(for: .showLogin)) { _ in showLogin = true }
        .sheet(isPresented: $showSettings)  { SettingsView() }
        .sheet(isPresented: Bindable(vm).sessionsOpen)  { SessionsView() }
        .sheet(isPresented: $showLogin)     { LoginView() }
        .sheet(isPresented: $showDebugLog)  { DebugLogView() }
        // First-run permission explainer (fixed-size sheet so it can never stretch the
        // window). Shown only when something is still undecided — see
        // MainViewModel.checkAndRequestPermissions. Blocks swipe-to-dismiss only until the
        // microphone prompt has been answered either way; Accessibility can be granted here
        // or skipped for now (the app still works via the local key monitor without it).
        .sheet(isPresented: Bindable(vm).needsPermissionSetup) {
            PermissionSetupView()
                .interactiveDismissDisabled(!vm.permMicrophone && !vm.micDenied)
        }
        .alert("Resume Upload Failed", isPresented: $showResumeError) {
            Button("OK") {}
        } message: {
            Text(resumeParseError)
        }
    }

    // ══════════════════════════════════════════════
    // MARK: — HEADER  (matches original exactly)
    // ══════════════════════════════════════════════
    var headerBar: some View {
        // Was a ZStack with micControl mathematically centered on the WHOLE window,
        // independent of how wide brandView/rightCluster actually were. That's fine when
        // both sides are narrow, but rightCluster can show up to 7 optional items at once
        // (Analyze, eye, pin, session timer, credits, profile, close) — once that content
        // got wide enough (adding the credits pill was what tipped it over), its left edge
        // crossed the true center point and visually overlapped the mic control. A plain
        // HStack with guaranteed minimum gaps can never overlap, regardless of how many
        // optional buttons are showing — trading perfect mathematical centering (which was
        // never guaranteed to hold anyway) for a layout that's simply never broken.
        // Priorities alone could not solve this. At full detail the header wants more width
        // than a 13" display has, and when something must give, SwiftUI takes it from
        // whatever is flexible — which turned out to be the control labels, truncating them
        // to "PRACTICE…", "2…", "0:…". Labels are the one thing in here a user must read to
        // operate the app, so they are never what gets sacrificed.
        //
        // Instead the header drops DETAIL, in a deliberate order, and only as much as it has
        // to: the brand strapline first, then the brand wordmark, then the mic hint. Each
        // rung is a complete layout; ViewThatFits picks the first that fits honestly rather
        // than squeezing one that does not.
        Group {
            if vm.inSetup {
                setupHeaderRow
            } else {
                ViewThatFits(in: .horizontal) {
                    headerRow(.full)
                    headerRow(.noStrapline)
                    headerRow(.iconBrand)
                    headerRow(.minimal)
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 64)
    }

    enum HeaderTier { case full, noStrapline, iconBrand, minimal }

    func headerRow(_ tier: HeaderTier) -> some View {
        HStack(spacing: 0) {
            brandView(tier)
                .layoutPriority(2)
            Spacer(minLength: 12)
            micControl(tier)
                .layoutPriority(1)
            Spacer(minLength: 12)
            rightCluster
                .layoutPriority(3)   // the controls are fixed-size now, so give them the
                // strongest claim: if anything must give up width it should be the mic
                // pill's hint text, never a button label breaking across three lines.   // PREMIUM FIX: never let the mic pill's growth (its hint
                // text is much longer while LISTENING — "Press SPACE again to get answer" vs
                // "Press SPACE to listen") squeeze rightCluster below its natural size. Without
                // this, an HStack with only minimum gaps shares the shortfall across ALL
                // children when content is tight, and rightCluster's own nested icon buttons
                // would get compressed into overlapping fragments — exactly the broken blob
                // seen switching MUTED → LISTENING. Giving both edges priority means only the
                // (already width-capped, see micControl) center pill ever absorbs the squeeze.
        }
    }

    /// The mic notice and the Interview / Practice tips, on their own line under the header.
    @ViewBuilder
    var transientMessageRow: some View {
        if !vm.alertTitle.isEmpty || !vm.listeningNotice.isEmpty {
            HStack(spacing: 10) {
                if !vm.alertTitle.isEmpty {
                    audioSourceAlert
                }
                if !vm.listeningNotice.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "mic.slash.fill")
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "#f59e0b"))
                        Text(vm.listeningNotice)
                            .font(.system(size: 10, weight: .bold)).tracking(0.4)
                            .foregroundColor(Color(hex: "#fcd34d"))
                            .lineLimit(1).minimumScaleFactor(0.8)
                            .frame(maxWidth: 320, alignment: .leading)
                    }
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(Capsule().fill(Color(hex: "#2A1F0D")))
                    .overlay(Capsule().stroke(Color(hex: "#7c5e1e"), lineWidth: 1))
                    .help("Press Space to start listening again")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
            .transition(.opacity)
        }
    }

    // ── Brand (left) ───────────────────────────────────────────────
    func brandView(_ tier: HeaderTier) -> some View {
        HStack(spacing: 9) {
            // The real Replysis mark, as-is. The blue head-and-brain tile that stood here was
            // the previous brand.
            Image("ReplysisMark")
                .resizable().interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 34, height: 34)
                .accessibilityLabel("Replysis")
            // The strapline is the first thing to go: it is decoration, and it costs more
            // width than the wordmark it sits under. The wordmark goes next; the mark itself
            // always stays, so the window is still identifiably the app.
            if tier == .full || tier == .noStrapline {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Replysis AI")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    // No strapline: a tagline in tiny tracked capitals reads as generated, and the
                    // owner's copy rules ban taglines and fake letter-spacing. The wordmark is enough.
                }
            }
        }
    }

    // ── Mic hero (center) ──────────────────────────────────────────
    func micControl(_ tier: HeaderTier) -> some View {
        let listening = vm.isListening
        return Button(action: micAction) {
            HStack(spacing: 11) {
                ZStack {
                    Circle()
                        .fill(Color(hex: "#0c1220"))
                        .frame(width: 34, height: 34)
                        .overlay(Circle().stroke(vm.micColor, lineWidth: 2))
                    Image(systemName: listening ? "mic.fill" : "mic.slash.fill")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(listening ? Color(hex: "#4ade80") : .white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle().fill(vm.micColor).frame(width: 7, height: 7)
                        Text(vm.micStatus)
                            .font(.system(size: 11, weight: .bold)).tracking(0.5)
                            .foregroundColor(.white)
                            // The one label in the header with no line limit, so it was the
                            // one that broke: LISTENING wrapped to "LIST / ENIN / G". A
                            // status word that wraps also reports a tiny ideal width, which
                            // told ViewThatFits the full layout fitted when it did not — so
                            // it kept the widest tier and then mangled it. Never wraps now.
                            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    }
                    // ROOT-CAUSE FIX: the LISTENING hint ("Press SPACE again to get answer")
                    // is much longer than the idle one ("Press SPACE to listen"), so the pill
                    // used to grow wider the instant you started listening — squeezing the
                    // header's right side into an overlapping mess. lineLimit + a fixed frame
                    // keep this pill's footprint constant across every state.
                    // Last detail to be dropped, and only at the tightest rung: the status
                    // word above it ("LISTENING" / "MUTED") still says what is happening.
                    if tier != .minimal {
                        Text(micHintText)
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundColor(micHintColor)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .frame(maxWidth: 172, alignment: .leading)
                    }
                }
            }
            .padding(.leading, 8).padding(.trailing, 14).padding(.vertical, 7)
            .background(
                Capsule().fill(Color.white.opacity(0.035))
                    .overlay(Capsule().stroke(
                        listening ? Color(hex: "#4ade80").opacity(0.45) : Color.white.opacity(0.08),
                        lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .help(vm.micNeedsRetry ? "Tap to retry audio capture" : "Press SPACE to toggle mic")
    }

    var micHintText: String {
        if vm.micNeedsRetry { return "Tap to retry" }
        // Armed but not yet hearing anything. Saying "listening" here is the difference
        // between the user waiting calmly and the user believing it heard them.
        if vm.micStatus == "CONNECTING" { return "Connecting — nothing is being heard yet" }
        switch vm.listeningMode {
        case .manual:
            return vm.isListening ? "Press SPACE again to get answer" : "Press SPACE to listen"
        case .auto:
            return vm.isListening ? "Listening, answers on its own" : "Auto, answers when the question ends"
        }
    }
    var micHintColor: Color {
        if vm.micStatus == "CONNECTING" { return Color(hex: "#f59e0b") }
        if vm.isListening { return Color(hex: "#4ade80") }
        if vm.micNeedsRetry { return Color(hex: "#6b7280") }
        return Color(hex: "#3d4d5f")
    }
    func micAction() {
        if vm.micNeedsRetry { vm.retryMic() }
        else { vm.handleSpacePress(source: "BUTTON") }
    }

    // ── Right cluster: interview actions + profile + window ────────
    var rightCluster: some View {
        // Wider gaps between groups than inside them: separation is what makes a toolbar
        // read as a few considered clusters instead of one crowded row.
        HStack(spacing: 13) {
            // No Analyze button: it duplicated what F8/F9 already do, and the footer
            // names both. Watch Screen is the control worth toolbar space, because it is
            // the one set once before the call and then never touched — reaching for a
            // menu mid-interview is exactly what this product exists to avoid.

            // Eye Mode · Pin · Stealth — one premium segmented glass pill instead of three
            // separately-bordered floating buttons, so the header reads as a few clean
            // groups (Analyze / view toggles / status / account) rather than a row of
            // many individual chips.
            listeningModeSwitch

            watchAndCompactGroup

            // Pin joins the view-toggle group visually instead of floating alone.
            toolSegmentGroup

            headerSeparator

            // Status cluster: session time and credits read as one unit, because they are
            // both "how the session is going" rather than controls.
            HStack(spacing: 8) {
            // Session timer (live)
            if vm.sessionTimerVisible {
                HStack(spacing: 5) {
                    Image(systemName: "record.circle").font(.system(size: 10)).foregroundColor(Color(hex: "#ef4444"))
                    Text(vm.sessionTimerText)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(hex: "#cbd5e1"))
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, 11).padding(.vertical, 8)
                .background(Capsule().fill(Color.white.opacity(0.04)))
                .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
            }

            // Visible credits indicator — previously the ONLY place to see your credit
            // balance was inside the profile avatar's dropdown, which most users (guests
            // especially) never think to click. BUG FIX: this used to open the FULL
            // profile dropdown (Settings/Sessions/Sign Out) on click, which felt wrong —
            // clicking specifically the credits number shouldn't dump you into the whole
            // account menu. Now opens its own small popover with just the credits card.
            creditsBadgeView

            }

            headerSeparator

            accountAndCloseControls
        }
    }

    /// The answers badge. Shared by the interview header and the Setup header.
    @ViewBuilder
    var creditsBadgeView: some View {
        if vm.showCreditsBadge {
                Button(action: { vm.askAgainNow(); showCreditsPopover.toggle() }) {
                    Text(vm.creditsText)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(vm.creditsColor)
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Capsule().fill(Color.white.opacity(0.05)))
                        .overlay(Capsule().stroke(vm.creditsColor.opacity(0.35), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help(vm.creditsTooltip)
                .popover(isPresented: $showCreditsPopover, arrowEdge: .bottom) {
                    creditsCard
                        .padding(14)
                        .frame(width: 260)
                        .background(Color(hex: "#0b1018"))
                }
            }
    }

    /// Profile (or Sign In) and Close. Shared by the interview header and the Setup header.
    @ViewBuilder
    var accountAndCloseControls: some View {
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

    /// One hairline used between header groups, so the spacing reads as deliberate
    /// grouping rather than an accidental gap.
    var headerSeparator: some View {
        Rectangle().fill(Color.white.opacity(0.10))
            .frame(width: 1, height: 24)
            .padding(.horizontal, 2)
    }

    // ── AUTO | MANUAL ──────────────────────────────────────────────
    // WHEN the app answers, never which audio it hears; that stopped being a choice when the
    // modes merged. Two visible segments rather than a menu: a dropdown hides the state until
    // it is opened, and this is state a candidate has to read at a glance mid-interview.
    // The "Real interview? Mic off in Settings" capsule lived here. It pointed at a
    // Settings switch that is now a segment in this same toolbar, and the two tips that
    // matter are alerts with a button that performs the switch (see interviewTipAlert).
    var listeningModeSwitch: some View { listeningModeSegments }

    // Group 1: WHEN the app answers. Group 2, past the hairline: WHAT it hears.
    // The audio choice was a checkbox in Settings called "microphone", and people left it
    // on in real interviews, so the app heard the candidate's own answers and took them as
    // new questions. Named for the situation, beside the mode it belongs with, and read
    // before the call starts. Windows 9294be2.
    var listeningModeSegments: some View {
        HStack(spacing: 0) {
            modeSegment(.auto, label: "AUTO",
                        help: "Auto. Answers as soon as the question ends.")
            Rectangle().fill(Color.white.opacity(0.10)).frame(width: 1, height: 18)
            modeSegment(.manual, label: "MANUAL",
                        help: "Manual. Press Space to listen, and again to answer. Most accurate, because you decide when the question ends. In Auto the end is inferred from a pause, so an interviewer who stops mid-sentence to think can be answered half-way.")

            Rectangle().fill(Color.white.opacity(0.18))
                .frame(width: 1, height: 18).padding(.horizontal, 6)

            audioSegment(practice: false, label: "Interview", icon: "video.fill",
                         help: AudioSourceRules.interviewHelp)
            audioSegment(practice: true, label: "Practice", icon: "mic.fill",
                         help: AudioSourceRules.practiceHelp)
        }
        .help(AudioSourceRules.hearingLine(practiceOn: vm.practiceAudioOn))
        .background(Capsule().fill(Color(hex: "#161b22")))
        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
        .clipShape(Capsule())
    }

    func modeSegment(_ mode: ListeningMode, label: String, help: String) -> some View {
        let selected = vm.listeningMode == mode
        let accent = GlassMaterial.text
        return Button(action: { vm.setListeningMode(mode) }) {
            HStack(spacing: 6) {
                Circle().fill(selected ? accent : Color.clear).frame(width: 6, height: 6)
                Text(label)
                    .font(.system(size: 10, weight: .bold)).tracking(0.7)
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    .foregroundColor(selected ? .white : Color(hex: "#64748b"))
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(selected ? GlassMaterial.fill(GlassMaterial.selectedSegment, windowOpacity: vm.mainWindowOpacity) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// An in-app alert that can carry one action, for the Interview / Practice tips.
    /// One click does the thing it suggests, so nobody has to find a setting mid-call.
    var audioSourceAlert: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "#fbbf24"))
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.alertTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                Text(vm.alertBody)
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(hex: "#c3ccd8"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 320, alignment: .leading)
            if !vm.alertActionLabel.isEmpty {
                Button(action: { vm.runAlertAction() }) {
                    Text(vm.alertActionLabel)
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1).fixedSize()
                }
                .buttonStyle(GlassButtonStyle(windowOpacity: vm.mainWindowOpacity,
                                              minHeight: 26, horizontalPadding: 10, verticalPadding: 3))
            }
            Button(action: { vm.dismissAlert() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Color(hex: "#8b9bb0"))
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: "#161b22").opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .transition(.opacity)
    }

    func audioSegment(practice: Bool, label: String, icon: String, help: String) -> some View {
        let selected = vm.practiceAudioOn == practice
        return Button(action: { vm.selectAudioSource(practice: practice) }) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                Text(label)
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            }
            .foregroundColor(selected ? GlassMaterial.text : Color(hex: "#92929F"))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 4).fill(
                selected ? GlassMaterial.fill(GlassMaterial.selectedSegment, windowOpacity: vm.mainWindowOpacity)
                         : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // ── WATCH SCREEN | COMPACT — one grouped pill, as on Windows ──
    var watchAndCompactGroup: some View {
        HStack(spacing: 6) {
            // AN ACTION, NOT A SWITCH. Pressing it reads the screen there and then; the label
            // never changes, because a control whose text changes is read as a switch.
            // Whether screen answers are armed is a Settings preference, said in the tooltip.
            // Styled to the Windows 1.0.21 glass spec: neutral silver, fills that follow the
            // opacity slider, text that never fades.
            Button(action: { vm.runScreenAnalysis(wholeScreen: false) }) {
                ReadScreenButtonLabel(busy: vm.isScreenAnalyzing)
            }
            .buttonStyle(GlassButtonStyle(windowOpacity: vm.mainWindowOpacity,
                                          minHeight: 28, horizontalPadding: 9, verticalPadding: 3))
            .disabled(vm.isScreenAnalyzing)
            .help(vm.isWatchMode
                  ? "Read the screen now (F8). Screen answers are ARMED — questions about the screen are answered from it automatically. Change that in Settings."
                  : "Read the screen now (F8). Automatic screen answers are off — turn them on in Settings.")

            Button(action: { vm.toggleCamera() }) {
                HStack(spacing: 6) {
                    Image(systemName: vm.showCameraOverlay ? "eye.fill" : "eye")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Compact")
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1).fixedSize()
                }
            }
            .buttonStyle(GlassButtonStyle(windowOpacity: vm.mainWindowOpacity,
                                          minHeight: 28, horizontalPadding: 9, verticalPadding: 3))
            .help("Compact overlay — a small bar instead of the full window")
        }
    }

    /// ◀ ▶ over this session's answers, with where you are and a way back to live.
    @ViewBuilder
    var answerHistoryControls: some View {
        if !vm.answerHistory.isEmpty {
            HStack(spacing: 4) {
                Button(action: { vm.showPreviousAnswer() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .disabled(!vm.canGoBack)
                .foregroundColor(vm.canGoBack ? Color(hex: "#cbd5e1") : Color(hex: "#475569"))
                .help("Previous answer (⌃⌥←)")

                if vm.isShowingHistory {
                    Text(vm.historyPosition)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(hex: "#fbbf24"))
                        .fixedSize()
                }

                Button(action: { vm.showNextAnswer() }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .disabled(!vm.canGoForward)
                .foregroundColor(vm.canGoForward ? Color(hex: "#cbd5e1") : Color(hex: "#475569"))
                .help("Next answer (⌃⌥→)")

                if vm.isShowingHistory {
                    Button(action: { vm.returnToLive() }) {
                        Text(vm.newerAnswerWaiting ? vm.newerAnswerBadge : "Back to live")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(vm.newerAnswerWaiting ? Color(hex: "#34d399") : Color(hex: "#cbd5e1"))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color.white.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .help("Return to the newest answer (⌃⌥→)")
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.white.opacity(0.04)))
            .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
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
                    // A guest's session.email is intentionally empty (no account exists
                    // yet) — showing that blank looked like a rendering bug. Say plainly
                    // what state they're in instead.
                    Text(vm.session.isGuestSession ? "Free trial — not signed in" : vm.session.email)
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
                        subtitle: "Listening, screen, appearance") {
                    showProfileMenu = false; showSettings = true
                }
                menuRow(icon: "clock.arrow.circlepath", title: "Past Sessions",
                        subtitle: "Review previous interviews") {
                    showProfileMenu = false; vm.sessionsOpen = true
                }
                // A guest (free trial, no account) previously had NO way to reach the
                // sign-in screen except clicking "Sign Out" — confusing, since they never
                // signed in to anything. Show a direct "Sign In" entry instead; the real
                // "Upgrade to Pro" link only makes sense once there's an actual account.
                if vm.session.isGuestSession {
                    menuRow(icon: "person.crop.circle.badge.checkmark", title: "Sign In",
                            subtitle: "Save your sessions across devices", accent: Color(hex: "#38bdf8")) {
                        showProfileMenu = false; showLogin = true
                    }
                } else if !vm.session.isPaidPlan {
                    // Only offered to accounts actually below the paid tiers. Gating this on
                    // isUnlimited offered "Upgrade to Pro" to a Max subscriber, because Max
                    // is paid but still metered — an upsell to a LOWER tier than the one
                    // they are on.
                    menuRow(icon: "bolt.fill", title: "Upgrade to Pro",
                            subtitle: PlanFacts.allowanceText(plan: "pro", signedIn: true), accent: Color(hex: "#a78bfa")) {
                        showProfileMenu = false
                        NSWorkspace.shared.open(URL(string: "https://replysis.com/pricing")!)
                    }
                } else if !vm.session.isUnlimited {
                    // Paid but metered: the useful action is more answers, not a new plan.
                    menuRow(icon: "creditcard.fill", title: "Get more answers",
                            subtitle: vm.session.creditsKnown
                                ? "\(vm.session.plan.capitalized) plan, \(PlanFacts.answersLabel(vm.session.credits)) left"
                                : "Checking how many answers are left",
                            accent: Color(hex: "#34E08A")) {
                        showProfileMenu = false
                        NSWorkspace.shared.open(PlanFacts.addAnswersURL)
                    }
                }
            }
            .padding(.vertical, 6)

            // "Sign Out" only makes sense for a real signed-in account — a guest never
            // signed anything in, so this row is replaced by "Sign In" above instead.
            if !vm.session.isGuestSession {
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)

                menuRow(icon: "rectangle.portrait.and.arrow.right", title: "Sign Out",
                        subtitle: nil, accent: Color(hex: "#ef4444"), destructive: true) {
                    showProfileMenu = false; vm.signOut()
                }
                .padding(.vertical, 6)
            }
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
                        Text(vm.session.creditsKnown ? PlanFacts.answersLabel(vm.session.credits) : "Checking answers")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(creditsAccent)
                        Text(vm.onFreeTrial
                             ? "Free trial, \(PlanFacts.allowanceText(plan: vm.session.plan, signedIn: false)). Not refreshed"
                             : "\(vm.session.plan.capitalized) plan, \(PlanFacts.allowanceText(plan: vm.session.plan, signedIn: true))")
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "#64748b"))
                    }
                    Spacer(minLength: 0)
                    // A guest has no account to buy credits on — route to Sign In instead of
                    // a pricing page they can't actually act on. Real accounts keep "Top up".
                    Button(action: {
                        // creditsCard is shared between the full profile dropdown and the
                        // standalone credits popover — close whichever one is actually open.
                        showProfileMenu = false
                        showCreditsPopover = false
                        if vm.session.isGuestSession {
                            showLogin = true
                        } else {
                            NSWorkspace.shared.open(PlanFacts.addAnswersURL)
                        }
                    }) {
                        Text(vm.session.isGuestSession ? "Sign In" : "Get more")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(vm.session.isGuestSession ? Color(hex: "#1d4ed8") : Color(hex: "#1a6b3a")))
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
        if !vm.session.creditsKnown { return Color(white: 0.62) }
        if !PlanFacts.isLow(c)  { return Color(hex: "#4ade80") }
        if !PlanFacts.isEmpty(c) { return Color(hex: "#f59e0b") }
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

            // Toggle arrow — glass pill, matching the mic control's translucent fill +
            // hairline border instead of the old flat solid-color block.
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { resumeCollapsed.toggle() } }) {
                Image(systemName: resumeCollapsed ? "chevron.right" : "chevron.left")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Color(hex: "#94A3B8"))
                    .frame(width: 22)
                    .frame(maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.035))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))
                    )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 3)

            // Right panel
            rightPanel
        }
        .padding(22)
        .padding(.top, 0)
    }

    // ══════════════════════════════════════════════
    // MARK: — RESUME PANEL
    // ══════════════════════════════════════════════
    // Single-column "Interview Setup" (matches the Windows UI): resume drop zone on top,
    // then Previous resumes, then the Target Role fields. No tabs, no Ask/Guide box.
    var resumePanel: some View {
        VStack(alignment: .leading, spacing: 16) {
                // ── Section header ──
                HStack(spacing: 7) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 12)).foregroundColor(Color(hex: "#64748b"))
                    Text("INTERVIEW SETUP")
                        .font(.system(size: 11, weight: .bold)).tracking(1.2)
                        .foregroundColor(Color(hex: "#94A3B8"))
                    Spacer()
                }

                // ── Resume: drop zone (empty) or loaded card (filled) ──
                resumeSetupCard

                // ── Previous resumes ──
                if !vm.savedResumes.isEmpty {
                    Button(action: { showResumeLibrary.toggle() }) {
                        HStack(spacing: 8) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Previous resumes")
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                        }
                        .foregroundColor(Color(hex: "#7dd3fc"))
                        .padding(.horizontal, 14).padding(.vertical, 11)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: "#0c2540")))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: "#1e3a5f"), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showResumeLibrary, arrowEdge: .bottom) {
                        resumeLibraryPopover()
                    }
                }

                Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1).padding(.vertical, 2)

                // ── Target role (fills the remaining height so there's no bottom gap) ──
                targetRoleSection
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.trailing, 14)
        .padding(.bottom, 6)
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

    // ── Resume setup card: drop zone when empty, loaded confirmation when filled ──
    var resumeSetupCard: some View {
        Group {
            if vm.resumeText.isEmpty {
                // Drop zone — matches the Windows "Drop your resume here" panel.
                Button(action: uploadResume) {
                    VStack(spacing: 10) {
                        ZStack {
                            Circle().fill(Color(hex: "#0e3a5a")).frame(width: 52, height: 52)
                            Image(systemName: "arrow.up")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(Color(hex: "#38bdf8"))
                        }
                        Text("Drop your resume here")
                            .font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                        Text("or click to browse")
                            .font(.system(size: 12)).foregroundColor(Color(hex: "#64748b"))
                        HStack(spacing: 6) {
                            ForEach(["PDF", "DOCX", "TXT"], id: \.self) { ext in
                                Text(ext)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(Color(hex: "#7dd3fc"))
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Capsule().fill(Color(hex: "#0c2540")))
                            }
                        }
                        .padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color(red: 14/255, green: 18/255, blue: 26/255).opacity(vm.mainWindowOpacity))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .strokeBorder(
                                        dropTargeted ? Color(hex: "#38bdf8") : Color.white.opacity(0.18),
                                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                            )
                    )
                }
                .buttonStyle(.plain)
                .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                    handleDroppedResume(providers)
                }
            } else {
                // Loaded — confirmation card with a View/Edit toggle + Replace.
                VStack(spacing: 0) {
                    HStack(spacing: 11) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 22)).foregroundColor(Color(hex: "#22c55e"))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Resume loaded")
                                .font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                            Text("\(vm.resumeText.count) characters")
                                .font(.system(size: 10)).foregroundColor(Color(hex: "#4b5563"))
                        }
                        Spacer()
                        Button(action: { withAnimation(.easeOut(duration: 0.15)) { resumeOpen.toggle() } }) {
                            Image(systemName: resumeOpen ? "chevron.up" : "pencil")
                                .font(.system(size: 11, weight: .bold)).foregroundColor(Color(hex: "#94A3B8"))
                                .padding(.horizontal, 9).padding(.vertical, 6)
                                .background(Color(hex: "#1A1F2E"))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.2), lineWidth: 1))
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                        .help(resumeOpen ? "Hide resume" : "View / edit resume")
                        Button(action: uploadResume) {
                            Text("Replace").font(.system(size: 11, weight: .medium))
                                .foregroundColor(Color(hex: "#94A3B8"))
                                .padding(.horizontal, 9).padding(.vertical, 6)
                                .background(Color(hex: "#1A1F2E"))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.2), lineWidth: 1))
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                        .help("Upload a different resume")
                    }
                    .padding(12)

                    if resumeOpen {
                        ZStack(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(red: 14/255, green: 18/255, blue: 26/255).opacity(vm.mainWindowOpacity))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.12), lineWidth: 1))
                            TextEditor(text: Bindable(vm).resumeText)
                                .font(.system(size: 12))
                                .foregroundColor(Color(hex: "#CBD5E1"))
                                .scrollContentBackground(.hidden)
                                .background(Color.clear)
                                .disabled(vm.resumeLocked)
                                .opacity(vm.resumeLocked ? 0.6 : 1.0)
                                .padding(8)
                                .frame(height: 200)
                                .focused($focusedField, equals: .resume)
                                .onChange(of: vm.resumeText) { scheduleResumeSave() }
                        }
                        .padding(.horizontal, 12).padding(.bottom, 12)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color(red: 10/255, green: 22/255, blue: 14/255).opacity(vm.mainWindowOpacity))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(hex: "#22c55e").opacity(0.25), lineWidth: 1))
                )
            }
        }
    }

    // Load a resume dropped onto the drop zone (same parse path as the Upload button).
    private func handleDroppedResume(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            let name = url.deletingPathExtension().lastPathComponent
            Task { @MainActor in
                let text = await Task.detached(priority: .userInitiated) {
                    ResumeParser.readResumeFile(url)
                }.value
                if !text.isEmpty {
                    vm.resumeText = text
                    vm.saveResumeToLibrary(name: name)
                    vm.saveResume()
                    withAnimation { resumeOpen = false }
                } else {
                    resumeParseError = "Couldn't read that file. Try exporting your resume as PDF or pasting the text directly."
                    showResumeError = true
                }
            }
        }
        return true
    }

    // ── Target role: company + job description (always visible, matches Windows) ──
    var targetRoleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "briefcase.fill")
                    .font(.system(size: 11)).foregroundColor(Color(hex: "#64748b"))
                Text("TARGET ROLE")
                    .font(.system(size: 11, weight: .bold)).tracking(1)
                    .foregroundColor(Color(hex: "#94A3B8"))
                Text("tailors every answer")
                    .font(.system(size: 10)).foregroundColor(Color(hex: "#4b5563"))
                Spacer()
            }

            TextField("Company  (e.g. Google, Stripe, Amazon…)", text: Bindable(vm).companyName)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color(red: 14/255, green: 18/255, blue: 26/255).opacity(vm.mainWindowOpacity))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.12), lineWidth: 1))
                .cornerRadius(10)
                .focused($focusedField, equals: .company)
                .onChange(of: vm.companyName) { scheduleJobSave() }

            // Screening details. Asked in the first two minutes of nearly every contract
            // screen, and answerable from no resume ever written — so they are set once
            // here rather than guessed at, or waffled around, in front of a recruiter.
            screeningSection

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(red: 14/255, green: 18/255, blue: 26/255).opacity(vm.mainWindowOpacity))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.12), lineWidth: 1))
                if vm.jobDescription.isEmpty {
                    Text("Paste the role & requirements: title, must-have skills, tech stack, seniority.")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "#64748b"))
                        .padding(14)
                        .allowsHitTesting(false)
                }
                TextEditor(text: Bindable(vm).jobDescription)
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#CBD5E1"))
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .padding(8)
                    .focused($focusedField, equals: .job)
                    .onChange(of: vm.jobDescription) { scheduleJobSave() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The five screening answers, and a free-text rate.
    ///
    /// Every one defaults to "Not specified" and an unset field is left out of the prompt
    /// entirely — a blank must never become a confident answer, because inventing somebody's
    /// visa status or rate is worse than saying it is open, and a recruiter writes both down.
    var screeningSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "person.text.rectangle")
                    .font(.system(size: 10)).foregroundColor(Color(hex: "#64748b"))
                Text("SCREENING ANSWERS")
                    .font(.system(size: 10, weight: .bold)).tracking(0.9)
                    .foregroundColor(Color(hex: "#94A3B8"))
                Text("asked at the start of the call")
                    .font(.system(size: 9)).foregroundColor(Color(hex: "#4b5563"))
                Spacer()
            }
            HStack(spacing: 7) {
                screeningPicker("Work type", MainViewModel.workTypeOptions, Bindable(vm).workType)
                screeningPicker("Authorization", MainViewModel.workAuthOptions, Bindable(vm).workAuth)
            }
            HStack(spacing: 7) {
                screeningPicker("Can start", MainViewModel.canStartOptions, Bindable(vm).canStart)
                screeningPicker("Where", MainViewModel.locationOptions, Bindable(vm).workLocation)
            }
            // Free text, because "$65/hr on C2C" and "$140k base" are not the same shape.
            TextField("Pay  (e.g. $65/hr on C2C, or $140k base)", text: Bindable(vm).payRate)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Color(red: 14/255, green: 18/255, blue: 26/255).opacity(vm.mainWindowOpacity))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.12), lineWidth: 1))
                .cornerRadius(9)
                .focused($focusedField, equals: .pay)
                .onChange(of: vm.payRate) { scheduleJobSave() }
        }
    }

    func screeningPicker(_ label: String, _ options: [String], _ binding: Binding<String>) -> some View {
        let isSet = binding.wrappedValue != MainViewModel.notSpecified
        return Menu {
            ForEach(options, id: \.self) { opt in
                Button(opt) { binding.wrappedValue = opt; scheduleJobSave() }
            }
        } label: {
            HStack(spacing: 5) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(label.uppercased())
                        .font(.system(size: 8, weight: .bold)).tracking(0.6)
                        .foregroundColor(Color(hex: "#4b5563"))
                    Text(binding.wrappedValue)
                        .font(.system(size: 11, weight: isSet ? .semibold : .regular))
                        .foregroundColor(isSet ? Color(hex: "#7dd3fc") : Color(hex: "#64748b"))
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 2)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(Color(hex: "#4b5563"))
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(red: 14/255, green: 18/255, blue: 26/255).opacity(vm.mainWindowOpacity))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(
                isSet ? Color(hex: "#2b6ea8").opacity(0.55) : Color.white.opacity(0.12), lineWidth: 1))
            .cornerRadius(9)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
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

                    // minLength (not a plain Spacer): this row can show up to 3 clusters
                    // at once (label+STAR badge, thinking indicator, 4 action buttons) —
                    // same defensive treatment as the header fix, so they always keep a
                    // minimum gap rather than potentially crowding together at narrow
                    // widths instead of quietly assuming there's always room.
                    Spacer(minLength: 12)

                    // Thinking indicator
                    if vm.showThinking {
                        HStack(spacing: 4) {
                            ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                            Text(vm.thinkingText)
                                .font(.system(size: 12).italic())
                                .foregroundColor(Color(hex: "#38BDF8"))
                            Text("F8 all screens, F9 primary")
                                .font(.system(size: 11))
                                .foregroundColor(Color(hex: "#334466"))
                        }
                        Spacer(minLength: 12)
                    }

                    // Action buttons
                    HStack(spacing: 6) {
                        // Answer length, as on the Setup page: Short or Detailed. Shows what is
                        // ON NOW; the old button showed the state it would switch TO, which read
                        // as "Detailed" while answers were at their default length.
                        Button(action: { vm.setAnswerDetailed(!vm.answerDetailed) }) {
                            Text(vm.answerDetailed ? "Detailed" : "Short")
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1).fixedSize()
                        }
                        .buttonStyle(GlassButtonStyle(windowOpacity: vm.mainWindowOpacity,
                                                      minHeight: 28, horizontalPadding: 11, verticalPadding: 3))
                        .help(vm.answerDetailed
                              ? "Detailed answers: fuller, with an example, about a minute to say. Tap for short."
                              : "Short answers: fit the question, easy to say fast. Tap for detailed.")

                        // Step back through this session's answers. Instant, local, and it
                        // never calls the model: the answer a stray voice replaced is one
                        // press away instead of gone.
                        answerHistoryControls

                        ghostBtn("📋 Copy") { copyAnswer() }
                        ghostBtn("✕ Clear") { vm.clearAnswer() }
                        // Back to the Setup page without ending the session, and Finish: save,
                        // and review this interview in Past sessions.
                        Button(action: { vm.backToSetup() }) {
                            Text("Setup").font(.system(size: 11, weight: .semibold)).lineLimit(1).fixedSize()
                        }
                        .buttonStyle(GlassButtonStyle(windowOpacity: vm.mainWindowOpacity,
                                                      minHeight: 28, horizontalPadding: 11, verticalPadding: 3))
                        .accessibilityLabel("Setup")
                        .help("Return to interview setup")

                        Button(action: { Task { _ = await vm.finishInterview() } }) {
                            Text(vm.finishing ? "Saving..." : "Finish")
                                .font(.system(size: 11, weight: .semibold)).lineLimit(1).fixedSize()
                                .foregroundColor(Color(hex: "#0B0F17"))
                                .padding(.horizontal, 13).frame(minHeight: 28)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: "#EBF2FF")))
                        }
                        .buttonStyle(.plain)
                        .disabled(vm.finishing)
                        .accessibilityLabel("Finish")
                        .help("Finish, save, and review this interview in Past Sessions.")

                        Button(action: { vm.newSession() }) {
                            HStack(spacing: 6) {
                                Image(systemName: "plus")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("New session")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .lineLimit(1).fixedSize()
                            }
                        }
                        .buttonStyle(GlassButtonStyle(windowOpacity: vm.mainWindowOpacity,
                                                      minHeight: 30, minWidth: 112,
                                                      horizontalPadding: 14, verticalPadding: 4))
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
                    // Half what it was: this panel covers most of the window, so it decides
                    // whether any glass is visible at all.
                    // Also floored: this panel is what the answer text sits on, so it decides
                    // whether the answer can be read at all.
                    // Barely there. Compact puts no second layer under its answer and stays
                    // readable on text shadows alone; this matches that.
                    .fill(Color.white.opacity(0.04))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(hex: "#38bdf8").opacity(0.22), lineWidth: 1))
            )

            // Transcript box — 1/3 height (matches original)
            VStack(spacing: 0) {
                // Hotkey bar
                HStack {
                    // Both voices arrive here since the modes merged, so the box is not labelled
                    // as either speaker.
                    Text("TRANSCRIPT")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color(hex: "#2A4A6A"))

                    Spacer()

                    HStack(spacing: 6) {
                        hotKeyBadge("F8  this screen", color: "#4ade80", bg: "#0D2E0D")
                        hotKeyBadge("F9  main screen", color: "#4ade80", bg: "#0D2E0D")
                        // An automatic mode exists to remove the keypress, so advertising
                        // SPACE there is advice that contradicts the mode the user picked.
                        if vm.listeningMode.isAutomatic {
                            hotKeyBadge("AUTO  answers on its own", color: "#34E08A", bg: "#0D2E0D")
                        } else {
                            hotKeyBadge("SPACE  listen / answer", color: "#38BDF8", bg: "#0D1B2E")
                        }
                    }
                }
                .padding(.bottom, 8)

                // Transcript or hint
                ScrollViewReader { proxy in
                    ScrollView {
                        if vm.transcriptForDisplay.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: "waveform")
                                    .font(.system(size: 14, weight: .light))
                                    .foregroundColor(Color(hex: "#33506f"))
                                Text("The conversation appears here as it is spoken")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(Color(hex: "#33506f"))
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 6)
                        } else {
                            Text(vm.transcriptForDisplay)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .shadow(color: .black.opacity(0.6), radius: 3, x: 0, y: 1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .background(GeometryReader { g in
                                    Color.clear.preference(key: MainTranscriptHeightKey.self, value: g.size.height)
                                })
                                .id("transcriptBottom")
                        }
                    }
                    // GROWS WITH THE QUESTION, then scrolls. It was a fixed 64pt — about three
                    // lines — so a long interviewer turn was read through a letterbox while the
                    // window had room to show it. Capped at 152pt (about eight lines, the cap
                    // Windows uses on its compact overlay) so the answer below keeps its space.
                    .frame(height: vm.transcriptForDisplay.isEmpty ? 64 : min(max(transcriptContentHeight, 64), 152))
                    .onPreferenceChange(MainTranscriptHeightKey.self) { transcriptContentHeight = $0 }
                    .onChange(of: vm.transcriptForDisplay) {
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

    // ── Eye Mode · Pin — one segmented glass pill ──
    // Groups the view-toggle buttons into a single premium capsule with a hairline divider,
    // instead of separately-bordered chips floating with gaps between them. Stealth Mode
    // moved to Settings (default ON) — it's a set-once preference, not a mid-interview
    // toggle, so it no longer needs header real estate.
    var toolSegmentGroup: some View {
        // Only Pin lives here now. The eye icon called vm.toggleCamera() — the exact same
        // action as the COMPACT button — so the toolbar carried two different-looking
        // controls that did one thing. Pin has no Windows equivalent but is genuinely
        // needed on macOS, where a normal window falls behind the meeting app.
        segmentButton(icon: vm.isPinnedOnTop ? "pin.fill" : "pin",
                      active: vm.isPinnedOnTop,
                      activeColor: Color(hex: "#38bdf8"),
                      help: "Pin on top — keep the window above other apps") {
            vm.togglePin()
        }
        .background(Capsule().fill(Color.white.opacity(0.035)))
        .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
        .clipShape(Capsule())
    }

    private var segmentDivider: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1, height: 20)
    }

    private func segmentButton(icon: String, active: Bool, activeColor: Color,
                                help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(active ? activeColor : Color(hex: "#94A3B8"))
                .frame(width: 34, height: 32)
                .background(active ? activeColor.opacity(0.16) : Color.clear)
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
        if vm.session.creditsKnown && vm.session.credits == 0 && !vm.session.isUnlimited {
            NSWorkspace.shared.open(URL(string: "https://replysis.com/pricing")!)
        } else {
            Task { await vm.fetchCredits() }
        }
    }

    func scheduleResumeSave() {
        resumeSaveTimer?.invalidate()
        let t = Timer(timeInterval: 0.8, repeats: false) { [weak vm] _ in
            Task { @MainActor in vm?.saveResume() }
        }
        RunLoop.main.add(t, forMode: .common)   // fires even while NSOpenPanel is visible
        resumeSaveTimer = t
    }

    func scheduleJobSave() {
        jobSaveTimer?.invalidate()
        let t = Timer(timeInterval: 0.8, repeats: false) { [weak vm] _ in
            Task { @MainActor in vm?.saveJob() }
        }
        RunLoop.main.add(t, forMode: .common)
        jobSaveTimer = t
    }

    func uploadResume() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .plainText,
            UTType(filenameExtension: "docx") ?? .data,
            UTType(filenameExtension: "doc")  ?? .data]
        panel.allowsMultipleSelection = false
        panel.message = "Choose your resume (PDF, DOCX, or TXT)"
        // Non-blocking: keeps RunLoop free (runModal blocks it, causing stuck timers/saves).
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let name = url.deletingPathExtension().lastPathComponent
            Task { @MainActor in
                // Parse off the main actor — PDF/DOCX extraction can take 100-500ms.
                let text = await Task.detached(priority: .userInitiated) {
                    ResumeParser.readResumeFile(url)
                }.value
                if !text.isEmpty {
                    vm.resumeText = text
                    vm.saveResumeToLibrary(name: name)
                    vm.saveResume()
                    withAnimation { resumeOpen = false }
                } else {
                    resumeParseError = "Couldn't read that file. Try exporting your resume as PDF or pasting the text directly."
                    showResumeError = true
                }
            }
        }
    }
}

// Which text field currently has keyboard focus (so Space types instead of toggling mic)
enum FocusField: Hashable { case resume, hints, company, job, pay }

// A parsed segment of an AI answer (for the rich coding-answer renderer)
enum AnswerBlock {
    case header(String)
    case code(String)
    case text(String)
}

func parseAnswerBlocks(_ raw: String) -> [AnswerBlock] {
    // The SAME list the history collapse uses. Kept in one place because when they were
    // two, they drifted immediately — a QUERY section rendered as code here and was still
    // carried as code into every later prompt.
    let codeTitles = PromptBuilder.codeSectionTitles
    var blocks: [AnswerBlock] = []
    var buffer: [String] = []
    var inCodeSection = false   // inside ━━━ SOLUTION ━━━ and friends
    var inFence = false         // inside a ``` block
    func flush() {
        let joined = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !joined.isEmpty {
            blocks.append((inCodeSection || inFence) ? .code(joined) : .text(joined))
        }
        buffer.removeAll()
    }
    for line in raw.components(separatedBy: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        // Fenced code. The prompt asks for ━━━ headers and forbids backticks, but a model
        // under instruction is not a model under control: when one arrives fenced anyway,
        // this used to be the path where it silently became prose — proportional font,
        // wrapped, no copy button — which is exactly the state the code panel exists to
        // prevent. An unclosed fence is normal while streaming, so the final flush treats
        // whatever is still open as code rather than dropping it.
        if t.hasPrefix("```") {
            flush()
            inFence.toggle()
            continue
        }
        if !inFence, t.hasPrefix("━━━"), t.hasSuffix("━━━"), t.count > 6 {
            flush()
            let title = t.replacingOccurrences(of: "━", with: "").trimmingCharacters(in: .whitespaces)
            blocks.append(.header(title))
            inCodeSection = codeTitles.contains(title.uppercased())
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

            // Indicators ON. Code does not wrap here — long lines run off the right edge —
            // so with the scrollbar hidden there was nothing on screen saying more code
            // existed. In a coding round the line that runs off is as likely as not the one
            // with the return statement in it.
            ScrollView(.horizontal, showsIndicators: true) {
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





// ══════════════════════════════════════════════════════════════════════════
// Glass buttons — the Windows 1.0.21 spec (App.xaml + Glass.ApplyButtonMaterials).
//
// Fills are rgb(235,242,255) at alpha = value × strength, where strength follows the
// window-opacity slider: strength = 0.35 + 0.65 × backdrop, backdrop =
// clamp((opacity − 0.50) / 0.50, 0.06, 1). Only the FILLS follow the slider; the text
// stays #F4F7FC at full strength so it never fades with the window. Neutral silver,
// no green accents.
// ══════════════════════════════════════════════════════════════════════════
enum GlassMaterial {
    static let text = Color(red: 0xF4 / 255, green: 0xF7 / 255, blue: 0xFC / 255)
    static let disabledText = Color(red: 0x7C / 255, green: 0x88 / 255, blue: 0x99 / 255)

    static func strength(windowOpacity: Double) -> Double {
        let backdrop = min(max((windowOpacity - 0.50) / 0.50, 0.06), 1.0)
        return 0.35 + 0.65 * backdrop
    }

    static func fill(_ value: Double, windowOpacity: Double) -> Color {
        Color(red: 235 / 255, green: 242 / 255, blue: 1.0)
            .opacity(value * strength(windowOpacity: windowOpacity))
    }

    // The Windows resource values.
    static let surface = 0.20          // ScreenActionSurface / ActionSilverSurface
    static let stroke = 0.38           // ScreenActionStroke
    static let hoverSurface = 0.30     // ScreenActionHoverSurface
    static let hoverStroke = 0.50      // GlassButtonHoverStroke
    static let pressedSurface = 0.07   // GlassButtonPressedSurface
    static let selectedSegment = 0.20  // GlassButtonSelectedSurface (AUTO | MANUAL)
}

struct GlassButtonStyle: ButtonStyle {
    var windowOpacity: Double
    var minHeight: CGFloat
    var minWidth: CGFloat = 0
    var horizontalPadding: CGFloat
    var verticalPadding: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        GlassButtonBody(configuration: configuration, style: self)
    }

    private struct GlassButtonBody: View {
        let configuration: ButtonStyle.Configuration
        let style: GlassButtonStyle
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let surface: Double = !isEnabled ? 0.05
                : configuration.isPressed ? GlassMaterial.pressedSurface
                : hovering ? GlassMaterial.hoverSurface : GlassMaterial.surface
            let stroke: Double = hovering && isEnabled ? GlassMaterial.hoverStroke : GlassMaterial.stroke
            configuration.label
                .foregroundColor(isEnabled ? GlassMaterial.text : GlassMaterial.disabledText)
                .padding(.horizontal, style.horizontalPadding)
                .padding(.vertical, style.verticalPadding)
                .frame(minWidth: style.minWidth, minHeight: style.minHeight)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(GlassMaterial.fill(surface, windowOpacity: style.windowOpacity)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(GlassMaterial.fill(stroke, windowOpacity: style.windowOpacity), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .onHover { hovering = $0 }
        }
    }
}

/// The Windows "scan frame": four corner brackets and a line across the middle.
struct ScanFrameIcon: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let arm = rect.width * 0.30
        let (minX, minY, maxX, maxY) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
        p.move(to: CGPoint(x: minX, y: minY + arm)); p.addLine(to: CGPoint(x: minX, y: minY)); p.addLine(to: CGPoint(x: minX + arm, y: minY))
        p.move(to: CGPoint(x: maxX - arm, y: minY)); p.addLine(to: CGPoint(x: maxX, y: minY)); p.addLine(to: CGPoint(x: maxX, y: minY + arm))
        p.move(to: CGPoint(x: maxX, y: maxY - arm)); p.addLine(to: CGPoint(x: maxX, y: maxY)); p.addLine(to: CGPoint(x: maxX - arm, y: maxY))
        p.move(to: CGPoint(x: minX + arm, y: maxY)); p.addLine(to: CGPoint(x: minX, y: maxY)); p.addLine(to: CGPoint(x: minX, y: maxY - arm))
        p.move(to: CGPoint(x: minX + rect.width * 0.2, y: rect.midY)); p.addLine(to: CGPoint(x: maxX - rect.width * 0.2, y: rect.midY))
        return p
    }
}

/// "Read screen", as specified for both windows: 14pt scan frame, label, F8 at 55%.
struct ReadScreenButtonLabel: View {
    var busy: Bool
    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                if busy {
                    ProgressView().scaleEffect(0.45).frame(width: 14, height: 14)
                } else {
                    ScanFrameIcon()
                        .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        .frame(width: 14, height: 14)
                }
                Text("Read screen")
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1).fixedSize()
            }
            Text("F8")
                .font(.system(size: 9, weight: .semibold))
                .opacity(0.55)
        }
    }
}

// ══════════════════════════════════════════════════════════════════════════
// SETUP PAGE — the first thing a person sees (Windows 3665daa, 2026-09-28).
//
// A full page, not the narrow side panel: the person's context on the left (resume, role,
// what they want), how the app should listen on the right, and one pinned bar with the single
// action that starts the interview. Copy is Windows' word for word, so the two apps read the
// same. Nothing here listens or watches the screen (see MainViewModel.AppStep).
// ══════════════════════════════════════════════════════════════════════════
extension MainView {

    // Windows palette, all neutral silver: no green accents (the owner's rule).
    private var setupTitle:  Color { Color(hex: "#FAFBFD") }
    private var setupMuted:  Color { Color(hex: "#8294AB") }
    private var setupLabel:  Color { Color(hex: "#7E90A8") }
    private var setupBody:   Color { Color(hex: "#93A4BA") }

    var setupPage: some View {
        VStack(spacing: 0) {
            ScrollView {
                HStack(alignment: .top, spacing: 0) {
                    setupContextColumn
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
                        .padding(.horizontal, 28)
                    setupListeningColumn
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .padding(.horizontal, 32).padding(.top, 22).padding(.bottom, 26)
            }
            startInterviewBar
        }
    }

    // ── Header: brand, answers, account. No microphone and no screen tools on this page. ──
    var setupHeaderRow: some View {
        HStack(spacing: 13) {
            brandView(.full)
            Spacer(minLength: 12)
            creditsBadgeView
            Button(action: { vm.replayIntro() }) {
                Image(systemName: "questionmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 26, height: 26)
                    .foregroundColor(Color(hex: "#cbd5e1"))
                    .background(Circle().fill(Color.white.opacity(0.06)))
                    .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Replay the quick intro")
            headerSeparator
            accountAndCloseControls
        }
    }

    // ── Left: the person's context ──────────────────────────────────────────────────────
    var setupContextColumn: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Interview setup")
                    .font(.system(size: 19, weight: .bold)).foregroundColor(setupTitle)
                Text("Prepare your context once. Replysis keeps it available throughout the interview.")
                    .font(.system(size: 11)).foregroundColor(setupMuted)
            }

            VStack(alignment: .leading, spacing: 10) {
                setupSectionTitle("Upload your resume", "Answers use your real experience, projects and tools.")
                resumeSetupCard
                savedResumesButton
            }

            VStack(alignment: .leading, spacing: 10) {
                setupSectionTitle("Add the company and role", "Tailors answers to this role.")
                setupTextField("e.g. Google, Stripe, Amazon", text: Bindable(vm).companyName, focus: .company) { scheduleJobSave() }
                setupFieldLabel("JOB DESCRIPTION")
                jobDescriptionEditor
            }

            VStack(alignment: .leading, spacing: 10) {
                setupFieldLabel("WORK AUTHORIZATION")
                HStack(spacing: 7) {
                    screeningPicker("Work type", MainViewModel.workTypeOptions, Bindable(vm).workType)
                    screeningPicker("Authorization", MainViewModel.workAuthOptions, Bindable(vm).workAuth)
                }
                HStack(spacing: 7) {
                    screeningPicker("Can start", MainViewModel.canStartOptions, Bindable(vm).canStart)
                    screeningPicker("Where", MainViewModel.locationOptions, Bindable(vm).workLocation)
                }
                setupFieldLabel("What you want")
                setupTextField("e.g. $65/hr on C2C, or $140k base", text: Bindable(vm).payRate, focus: .pay) { scheduleJobSave() }
                Text("Left blank, the app stays vague instead of guessing a number for you.")
                    .font(.system(size: 10.5)).foregroundColor(setupMuted)
            }
        }
    }

    var jobDescriptionEditor: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.12), lineWidth: 1))
            if vm.jobDescription.isEmpty {
                Text("Paste the title, must-have skills, tech stack and seniority.")
                    .font(.system(size: 12)).foregroundColor(Color(hex: "#64748b"))
                    .padding(14).allowsHitTesting(false)
            }
            TextEditor(text: Bindable(vm).jobDescription)
                .font(.system(size: 12)).foregroundColor(Color(hex: "#CBD5E1"))
                .scrollContentBackground(.hidden).background(Color.clear)
                .padding(8)
                .focused($focusedField, equals: .job)
                .onChange(of: vm.jobDescription) { scheduleJobSave() }
        }
        .frame(height: 132)
    }

    var savedResumesButton: some View {
        Group {
            if !vm.savedResumes.isEmpty || !vm.resumeText.isEmpty {
                Button(action: { showResumeLibrary.toggle() }) {
                    HStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 12, weight: .semibold))
                        Text("Previous resumes").font(.system(size: 12, weight: .semibold))
                        Spacer()
                    }
                    .foregroundColor(GlassMaterial.text)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 8).fill(GlassMaterial.fill(GlassMaterial.surface, windowOpacity: vm.mainWindowOpacity)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(GlassMaterial.fill(GlassMaterial.stroke, windowOpacity: vm.mainWindowOpacity), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showResumeLibrary, arrowEdge: .bottom) { resumeLibraryPopover() }
            }
        }
    }

    // ── Right: how the app listens ──────────────────────────────────────────────────────
    var setupListeningColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Listening controls")
                    .font(.system(size: 17, weight: .bold)).foregroundColor(setupTitle)
                Text("Choose how answers trigger and which audio Replysis should hear. You can change both later.")
                    .font(.system(size: 11)).foregroundColor(setupMuted)
            }

            setupChoiceGroup("WHEN TO ANSWER") {
                setupChoiceCard(icon: "bolt.fill", title: "Auto",
                                selected: vm.listeningMode == .auto,
                                action: { vm.setListeningMode(.auto) }) {
                    Text("Answers after each complete question.")
                }
                setupChoiceCard(icon: "keyboard", title: "Manual",
                                selected: vm.listeningMode == .manual,
                                action: { vm.setListeningMode(.manual) }) {
                    Text("Press Space to listen, then Space to answer.")
                }
            }

            setupChoiceGroup("WHAT IT HEARS") {
                setupChoiceCard(icon: "video.fill", title: "Interview",
                                selected: !vm.practiceAudioOn,
                                tag: ("Recommended for real interviews", Color(hex: "#5FC98E")),
                                action: { vm.selectAudioSource(practice: false) }) {
                    Text("Hears ") + Text("system audio only").fontWeight(.semibold).foregroundColor(Color(hex: "#DDE4EE"))
                        + Text(" from the meeting. Your microphone stays off, preventing your answer from becoming a new question.")
                }
                setupChoiceCard(icon: "mic.fill", title: "Practice",
                                selected: vm.practiceAudioOn,
                                tag: ("Practice environment only", Color(hex: "#D99B7C")),
                                action: { vm.selectAudioSource(practice: true) }) {
                    Text("Hears ") + Text("system audio and microphone").fontWeight(.semibold).foregroundColor(Color(hex: "#DDE4EE"))
                        + Text(" together, ideal for rehearsing aloud or practising with someone nearby.")
                }
            }

            setupChoiceGroup("ANSWER LENGTH") {
                setupChoiceCard(icon: "text.alignleft", title: "Short",
                                selected: !vm.answerDetailed,
                                action: { vm.setAnswerDetailed(false) }) {
                    Text("Fits the question. Quick ones get a sentence or two, easy to say fast.")
                }
                setupChoiceCard(icon: "text.justify", title: "Detailed",
                                selected: vm.answerDetailed,
                                action: { vm.setAnswerDetailed(true) }) {
                    Text("Fuller answers with more depth and an example, about a minute to say.")
                }
            }

            captureProtectionCard
        }
    }

    var captureProtectionCard: some View {
        let state = CaptureProtection.current()
        return HStack(alignment: .top, spacing: 11) {
            setupChip("lock.shield")
            VStack(alignment: .leading, spacing: 3) {
                Text("Check capture protection before the call")
                    .font(.system(size: 12.5, weight: .semibold)).foregroundColor(Color(hex: "#E9EFF7"))
                Text("Hides the app from screen sharing. Support varies, so check it in your meeting app first.")
                    .font(.system(size: 11)).foregroundColor(setupBody).fixedSize(horizontal: false, vertical: true)
                Text(CaptureProtection.summary(state))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(state == .hidden ? Color(hex: "#5FC98E") : Color(hex: "#D99B7C"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    // ── Pinned bar: the one action ──────────────────────────────────────────────────────
    var startInterviewBar: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ready for the interview?")
                    .font(.system(size: 13.5, weight: .semibold)).foregroundColor(Color(hex: "#E9EFF7"))
                Text("Your setup stays available if you need to come back.")
                    .font(.system(size: 11)).foregroundColor(Color(hex: "#718298"))
            }
            Spacer()
            Button(action: { vm.startInterview() }) {
                HStack(spacing: 8) {
                    Text("Start interview").font(.system(size: 13, weight: .semibold))
                    Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold))
                }
                .foregroundColor(Color(hex: "#0B0F17"))
                .padding(.horizontal, 22).frame(minHeight: 38)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: "#EBF2FF")))
            }
            .buttonStyle(.plain)
            .disabled(vm.finishing)
            .accessibilityLabel("Start interview")
        }
        .padding(.horizontal, 32).padding(.vertical, 14)
        .background(Color.white.opacity(0.04))
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
    }

    // ── Pieces ──────────────────────────────────────────────────────────────────────────
    func setupSectionTitle(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundColor(setupTitle)
            Text(sub).font(.system(size: 11)).foregroundColor(setupMuted)
        }
    }

    func setupFieldLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 9.5, weight: .bold)).foregroundColor(setupLabel)
    }

    func setupTextField(_ placeholder: String, text: Binding<String>, focus: FocusField,
                        onChange: @escaping () -> Void) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 13)).foregroundColor(.white)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.12), lineWidth: 1))
            .focused($focusedField, equals: focus)
            .onChange(of: text.wrappedValue) { onChange() }
    }

    func setupChip(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(Color(hex: "#C7D4E5"))
            .frame(width: 30, height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.10)))
    }

    func setupChoiceGroup<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            setupFieldLabel(label)
            VStack(spacing: 8) { content() }
        }
    }

    func setupChoiceCard(icon: String, title: String, selected: Bool,
                         tag: (String, Color)? = nil,
                         action: @escaping () -> Void,
                         @ViewBuilder body: () -> Text) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 11) {
                setupChip(icon)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                        .foregroundColor(selected ? GlassMaterial.text : Color(hex: "#B9C4D6"))
                    body()
                        .font(.system(size: 11)).foregroundColor(setupBody)
                        .fixedSize(horizontal: false, vertical: true)
                    if let tag {
                        Text(tag.0).font(.system(size: 10, weight: .semibold)).foregroundColor(tag.1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundColor(selected ? GlassMaterial.text : Color.white.opacity(0.25))
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11)
                .fill(selected ? GlassMaterial.fill(GlassMaterial.selectedSegment, windowOpacity: 1) : Color.white.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 11)
                .stroke(selected ? GlassMaterial.fill(GlassMaterial.stroke, windowOpacity: 1) : Color.white.opacity(0.08), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // ── First-run welcome ───────────────────────────────────────────────────────────────
    var onboardingOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
                .onTapGesture { vm.dismissOnboarding() }
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to Replysis AI").font(.system(size: 19, weight: .bold)).foregroundColor(setupTitle)
                    Text("Your live interview workspace. Here's how it works.")
                        .font(.system(size: 12)).foregroundColor(setupMuted)
                }
                onboardingStep("doc.text", "Upload your resume", "Answers use your real experience, projects and tools.")
                onboardingStep("briefcase", "Add the company & role", "Tailors answers to this role.")
                onboardingStep("lock.shield", "Check capture protection before the call",
                               "Hides the app from screen sharing. Support varies, so check it in your meeting app first.")
                onboardingStep("keyboard", "Press SPACE to listen and to answer", "Press once to listen, again to answer. Works from any app.")
                HStack {
                    Text("Reopen anytime from the ? button").font(.system(size: 10.5)).foregroundColor(Color(hex: "#718298"))
                    Spacer()
                    Button(action: { vm.dismissOnboarding() }) {
                        Text("Get Started").font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(Color(hex: "#0B0F17"))
                            .padding(.horizontal, 20).frame(minHeight: 34)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: "#EBF2FF")))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Get Started")
                }
            }
            .padding(26).frame(width: 470)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(hex: "#0F1520")))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.14), lineWidth: 1))
        }
    }

    func onboardingStep(_ symbol: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            setupChip(symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundColor(Color(hex: "#E9EFF7"))
                Text(body).font(.system(size: 11)).foregroundColor(setupBody).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
