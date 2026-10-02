import SwiftUI

struct LoginView: View {
    @Environment(MainViewModel.self) var vm
    @Environment(\.dismiss) var dismiss

    @State private var email       = ""
    @State private var password    = ""
    @State private var fullName    = ""
    @State private var isCreatingAccount = false   // false = Sign In form, true = Create Account form
    @State private var isLoading   = false
    @State private var errorMsg    = ""
    @State private var successMsg  = ""
    // Hidden by default: "Continue with Google" only appears once a real client secret is
    // confirmed available. Google sign-in was ALWAYS failing with a "temporarily
    // unavailable" error (no GOOGLE_CLIENT_SECRET configured anywhere) — showing a button
    // that's guaranteed to fail on every click was the actual bug, not a flaky backend.
    // This is a permanent safety net: if the secret is ever missing again for any reason
    // (misconfigured secret, backend down), users see a clean email/password form instead
    // of a dead-end button and a red error banner.
    @State private var googleSignInAvailable = false

    /// `flat` draws the form without a scroll view, for the debug snapshot (an image renderer
    /// cannot draw a scroll view's content). The real window always scrolls if it has to.
    private let flat: Bool
    init(creating: Bool = false, flat: Bool = false) {
        _isCreatingAccount = State(initialValue: creating); self.flat = flat
    }

    // Saved account for "Continue As" card
    private var savedEmail: String { UserSession.shared.email }
    // BUG-14 FIX: check refreshToken (not idToken) — idToken can be populated even when
    // expired, so the "Continue As" card would show for an unusable token.
    private var hasSavedAccount: Bool { !savedEmail.isEmpty && !UserSession.shared.refreshToken.isEmpty }

    // The sign-in window, redesigned to match Windows (bf6222d, 3665daa) and the website: a light
    // split layout, a product panel on the left and the form on the right. No glows, no
    // letter-spacing and no animation loops: the page is meant to look finished, not busy.
    private enum Palette {
        static let page      = Color(hex: "#FEFEFC")
        static let ink       = Color(hex: "#16150F")
        static let body      = Color(hex: "#5A5F55")
        static let muted     = Color(hex: "#7A8177")
        static let faint     = Color(hex: "#8A9086")
        static let line      = Color(hex: "#DCE4D8")
        static let hairline  = Color(hex: "#E4E8E0")
        static let chip      = Color(hex: "#F0F2EE")
        static let green     = Color(hex: "#1C7A3E")
        static let greenLit  = Color(hex: "#21924A")
        static let greenTint = Color(hex: "#EEF7EF")
        static let greenLine = Color(hex: "#BFDFC7")
        static let errorBg   = Color(hex: "#FDF1F1")
        static let errorLine = Color(hex: "#F3C6C6")
        static let errorInk  = Color(hex: "#9A2E24")
    }

    private enum Field { case name, email, password }
    @FocusState private var focus: Field?
    @State private var showPassword = false

    private func submit() { isCreatingAccount ? createAccount() : signIn() }

    private func switchMode() {
        withAnimation(.easeOut(duration: 0.18)) {
            isCreatingAccount.toggle(); errorMsg = ""; successMsg = ""
        }
    }

    // ── Left: the product ────────────────────────────────────────────
    private var productPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image("ReplysisMark")
                    .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(width: 40, height: 40)
                    .frame(width: 42, height: 42)
                    .background(RoundedRectangle(cornerRadius: 11).fill(Color.white))
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color(hex: "#D8E3D6"), lineWidth: 1))
                    .accessibilityLabel("Replysis")
                VStack(alignment: .leading, spacing: 2) {
                    Text("REPLYSIS").font(.system(size: 15, weight: .bold)).foregroundColor(Palette.ink)
                    Text("AI INTERVIEW COPILOT").font(.system(size: 8.5, weight: .semibold)).foregroundColor(Palette.muted)
                }
            }

            Spacer(minLength: 12)

            HStack(spacing: 7) {
                Circle().fill(Palette.greenLit).frame(width: 5, height: 5)
                Text("YOUR INTERVIEW, IN FOCUS").font(.system(size: 9, weight: .bold)).foregroundColor(Palette.green)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Palette.greenLit.opacity(0.08)))
            .overlay(Capsule().stroke(Palette.greenLit.opacity(0.2), lineWidth: 1))
            .padding(.bottom, 16)

            Text("Be ready for the\nquestion that matters.")
                .font(.system(size: 27, weight: .semibold)).foregroundColor(Palette.ink)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
            Text("Replysis listens, understands the role and grounds every response in your real experience.")
                .font(.system(size: 12.5)).foregroundColor(Palette.body)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12).padding(.trailing, 8)

            // What the product does, shown rather than described: a question, and the answer.
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 8) {
                        Text("IN").font(.system(size: 8, weight: .bold)).foregroundColor(Palette.body)
                            .frame(width: 24, height: 24).background(Circle().fill(Palette.chip))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("INTERVIEWER").font(.system(size: 8, weight: .bold)).foregroundColor(Palette.faint)
                            Text("Tell me about a project you led.").font(.system(size: 11.5)).foregroundColor(Palette.ink)
                        }
                    }
                    .padding(.horizontal, 13).padding(.vertical, 10)
                    .frame(width: 285, height: 62, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: "#E3E8E0"), lineWidth: 1))
                    .shadow(color: Palette.ink.opacity(0.10), radius: 12, x: 0, y: 6)
                    .rotationEffect(.degrees(-1.5))
                    .padding(.leading, 7).padding(.top, 7)
                }
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        HStack(spacing: 7) {
                            Image(systemName: "bolt.fill").font(.system(size: 8, weight: .bold)).foregroundColor(Palette.green)
                                .frame(width: 18, height: 18).background(RoundedRectangle(cornerRadius: 5).fill(Palette.greenLit.opacity(0.13)))
                            Text("REPLYSIS ANSWER").font(.system(size: 8.5, weight: .bold)).foregroundColor(Palette.green)
                        }
                        Spacer(minLength: 4)
                        HStack(spacing: 5) {
                            Circle().fill(Palette.greenLit).frame(width: 5, height: 5)
                            Text("RESUME GROUNDED").font(.system(size: 7.5, weight: .bold)).foregroundColor(Color(hex: "#4F8A62"))
                        }
                    }
                    Text("I led the migration by splitting delivery into safe phases, reducing deployment risk while keeping the service available.")
                        .font(.system(size: 10.5)).foregroundColor(Color(hex: "#2B3A2E"))
                        .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .frame(width: 302, height: 82, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 11).fill(Palette.greenTint))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(Palette.greenLine, lineWidth: 1))
                .shadow(color: Palette.green.opacity(0.12), radius: 14, x: 0, y: 8)
                .rotationEffect(.degrees(1.2))
                .offset(x: 28, y: 92)
            }
            .frame(width: 330, height: 178, alignment: .topLeading)
            .padding(.top, 18)

            Spacer(minLength: 16)

            HStack(spacing: 11) {
                Text("\(PlanFacts.answers(PlanFacts.freeCredits))")
                    .font(.system(size: 22, weight: .semibold)).foregroundColor(Palette.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("FREE ANSWERS TO TRY IT").font(.system(size: 9, weight: .bold)).foregroundColor(Palette.ink)
                    Text("Included with every new account").font(.system(size: 9.5)).foregroundColor(Palette.muted)
                }
                Spacer(minLength: 8)
                Text("NO CARD").font(.system(size: 7.5, weight: .bold)).foregroundColor(Palette.body)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(Capsule().fill(Palette.chip))
                    .overlay(Capsule().stroke(Palette.line, lineWidth: 1))
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line, lineWidth: 1))
        }
        .padding(.leading, 48).padding(.trailing, 44).padding(.top, 42).padding(.bottom, 40)
        .frame(width: 420, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(
            LinearGradient(colors: [Color(hex: "#F6F8F3"), Color(hex: "#F1F5EE"), Color(hex: "#EAF3EC")],
                           startPoint: .topLeading, endPoint: .bottomTrailing))
        .overlay(alignment: .trailing) { Rectangle().fill(Color(hex: "#DCE4D8")).frame(width: 1) }
    }

    // ── Right: the form ──────────────────────────────────────────────
    private func fieldShell<Content: View>(_ icon: String, focused: Bool, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 0) {
            Image(systemName: icon).font(.system(size: 13, weight: .regular)).foregroundColor(Palette.faint)
                .frame(width: 42)
            content()
        }
        .frame(height: 48)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(focused ? Palette.greenLit : Palette.line, lineWidth: focused ? 1.6 : 1.3))
        .animation(.easeOut(duration: 0.12), value: focused)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundColor(Palette.body)
    }

    private func banner(_ text: String, error: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: error ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 12)).foregroundColor(error ? Color(hex: "#C0392B") : Palette.greenLit)
                .padding(.top, 1)
            Text(text).font(.system(size: 11.5)).foregroundColor(error ? Palette.errorInk : Palette.green)
                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 8).fill(error ? Palette.errorBg : Palette.greenTint))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(error ? Palette.errorLine : Palette.greenLine, lineWidth: 1))
        .transition(.opacity)
    }

    private var formPanel: some View {
        ZStack(alignment: .topTrailing) {
            Color.white
            LoginCloseButton { dismiss() }
                .padding(.top, 14).padding(.trailing, 16)

            MaybeScroll(flat: flat) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(isCreatingAccount ? "Create your account" : "Welcome back")
                        .font(.system(size: 25, weight: .semibold)).foregroundColor(Palette.ink)
                    Text(isCreatingAccount ? "Your free answers are ready as soon as you sign up"
                                           : "Sign in to continue to your workspace")
                        .font(.system(size: 12.5)).foregroundColor(Palette.muted)
                        .padding(.top, 5).padding(.bottom, 22)

                    if !errorMsg.isEmpty { banner(errorMsg, error: true).padding(.bottom, 12) }
                    if !successMsg.isEmpty { banner(successMsg, error: false).padding(.bottom, 12) }

                    if hasSavedAccount && !isCreatingAccount {
                        Button(action: continueAsSaved) {
                            HStack(spacing: 12) {
                                Text(UserSession.shared.initials.isEmpty ? "?" : UserSession.shared.initials)
                                    .font(.system(size: 13, weight: .bold)).foregroundColor(Palette.green)
                                    .frame(width: 36, height: 36).background(Circle().fill(Palette.greenTint))
                                    .overlay(Circle().stroke(Palette.greenLine, lineWidth: 1))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Continue as \(UserSession.shared.firstName)")
                                        .font(.system(size: 13.5, weight: .semibold)).foregroundColor(Palette.ink)
                                    Text(savedEmail).font(.system(size: 11.5)).foregroundColor(Palette.muted)
                                }
                                Spacer()
                                if isLoading { ProgressView().controlSize(.small) }
                                else { Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundColor(Palette.green) }
                            }
                            .padding(.horizontal, 14).padding(.vertical, 11)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Palette.greenTint))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.greenLine, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .disabled(isLoading)
                        .padding(.bottom, 18)
                    }

                    if isCreatingAccount {
                        fieldLabel("Full name").padding(.bottom, 7)
                        fieldShell("person", focused: focus == .name) {
                            TextField("", text: $fullName, prompt: Text("Jane Doe").foregroundColor(Palette.faint))
                                .textFieldStyle(.plain).focused($focus, equals: .name)
                                .font(.system(size: 13.5)).foregroundColor(Palette.ink)
                                .autocorrectionDisabled().onSubmit { focus = .email }
                        }
                        .padding(.bottom, 16)
                    }

                    fieldLabel("Email address").padding(.bottom, 7)
                    fieldShell("envelope", focused: focus == .email) {
                        TextField("", text: $email, prompt: Text("you@example.com").foregroundColor(Palette.faint))
                            .textFieldStyle(.plain).focused($focus, equals: .email)
                            .font(.system(size: 13.5)).foregroundColor(Palette.ink)
                            .autocorrectionDisabled().onSubmit { focus = .password }
                    }
                    .padding(.bottom, 16)

                    fieldLabel("Password").padding(.bottom, 7)
                    fieldShell("lock", focused: focus == .password) {
                        Group {
                            if showPassword {
                                TextField("", text: $password, prompt: Text("Your password").foregroundColor(Palette.faint))
                            } else {
                                SecureField("", text: $password, prompt: Text("Your password").foregroundColor(Palette.faint))
                            }
                        }
                        .textFieldStyle(.plain).focused($focus, equals: .password)
                        .font(.system(size: 13.5)).foregroundColor(Palette.ink)
                        .onSubmit { submit() }
                        Button(action: { showPassword.toggle() }) {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .font(.system(size: 13)).foregroundColor(Palette.faint)
                                .frame(width: 38, height: 34)
                        }
                        .buttonStyle(.plain)
                        .help(showPassword ? "Hide password" : "Show password")
                        .padding(.trailing, 5)
                    }

                    HStack {
                        if isCreatingAccount {
                            Text("At least 6 characters").font(.system(size: 11)).foregroundColor(Palette.muted)
                        }
                        Spacer()
                        if !isCreatingAccount {
                            Button("Forgot password?") { forgotPassword() }
                                .buttonStyle(LoginLinkStyle(size: 11))
                        }
                    }
                    .padding(.top, 8).padding(.bottom, 18)

                    Button(action: submit) {
                        HStack(spacing: 8) {
                            if isLoading { ProgressView().controlSize(.small).tint(.white) }
                            Text(isLoading ? (isCreatingAccount ? "Creating account..." : "Signing in...")
                                           : (isCreatingAccount ? "Create account" : "Sign In"))
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity).frame(height: 43)
                    }
                    .buttonStyle(LoginPrimaryButtonStyle())
                    .disabled(isLoading)
                    .keyboardShortcut(.defaultAction)
                    .padding(.bottom, 14)

                    if googleSignInAvailable {
                        HStack(spacing: 12) {
                            Rectangle().fill(Palette.hairline).frame(height: 1)
                            Text("OR").font(.system(size: 9, weight: .bold)).foregroundColor(Palette.faint)
                            Rectangle().fill(Palette.hairline).frame(height: 1)
                        }
                        .padding(.bottom, 14)

                        Button(action: signInWithGoogle) {
                            HStack(spacing: 10) {
                                GoogleLogoShape().frame(width: 16, height: 16)
                                Text(isCreatingAccount ? "Sign up with Google" : "Continue with Google")
                                    .font(.system(size: 12.5, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity).frame(height: 43)
                        }
                        .buttonStyle(LoginSecondaryButtonStyle())
                        .disabled(isLoading)
                        .padding(.bottom, 16)
                    } else {
                        Spacer().frame(height: 4)
                    }

                    HStack(spacing: 4) {
                        Spacer()
                        Text(isCreatingAccount ? "Already have an account?" : "New to Replysis?")
                            .font(.system(size: 11.5)).foregroundColor(Palette.muted)
                        Button(isCreatingAccount ? "Sign in" : "Create an account") { switchMode() }
                            .buttonStyle(LoginLinkStyle(size: 11.5))
                        Spacer()
                    }
                }
                .frame(width: 390)
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 600)
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            productPanel
            formPanel
        }
        .frame(width: 960, height: 600)
        .background(Palette.page)
        // Light in every system appearance: the page is a light page, and a dark system would
        // turn its fields and text into something unreadable.
        .preferredColorScheme(.light)
        .task {
            // Check whether Google sign-in can actually succeed BEFORE showing its button.
            // Baked-in secret (set via the GOOGLE_CLIENT_SECRET GitHub secret at build time)
            // is checked first; if that's empty, try the remote-config fetch once as a
            // fallback. Either way, the button only appears once this resolves true.
            if AppConfig.googleClientSecret.isEmpty { await AppConfig.fetchRemoteConfig() }
            googleSignInAvailable = !AppConfig.googleClientSecret.isEmpty
            focus = hasSavedAccount ? nil : .email
        }
    }

    // MARK: — Actions

    /// What was typed, without the space or line break a paste brings with it. An email with a
    /// trailing space was refused as "Incorrect email or password", which sends someone to reset a
    /// password that was never wrong.
    private var cleanEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    func signIn() {
        guard !isLoading else { return }   // a double click sent two requests, and "too many attempts" is real
        guard !cleanEmail.isEmpty && !password.isEmpty else {
            errorMsg = "Please enter your email and password."
            return
        }
        isLoading = true
        errorMsg = ""
        Task {
            let result = await signInWithEmailPassword()
            isLoading = false
            if result.success {
                vm.onLoginSuccess()
                dismiss()
            } else {
                errorMsg = result.error ?? "Sign in failed. Please try again."
            }
        }
    }

    func createAccount() {
        guard !fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMsg = "Please enter your name."
            return
        }
        guard !isLoading else { return }
        guard !cleanEmail.isEmpty && !password.isEmpty else {
            errorMsg = "Please enter your email and password."
            return
        }
        guard password.count >= 6 else {
            errorMsg = "Password must be at least 6 characters."
            return
        }
        isLoading = true
        errorMsg = ""
        Task {
            let result = await signUpWithEmailPassword()
            isLoading = false
            if result.success {
                vm.onLoginSuccess()
                dismiss()
            } else {
                errorMsg = result.error ?? "Could not create account. Please try again."
            }
        }
    }

    func signInWithGoogle() {
        // BUG-13 FIX: guard prevents double-tap opening two browser windows and leaking
        // the loopback server socket for up to 2 minutes per extra tap.
        guard !isLoading else { return }
        isLoading = true
        errorMsg = ""
        Task {
            let result = await GoogleSignIn.signIn()
            isLoading = false
            if result.success {
                UserSession.shared.idToken      = result.idToken
                UserSession.shared.refreshToken = result.refreshToken
                UserSession.shared.email        = result.email
                UserSession.shared.name         = result.displayName
                UserSession.shared.userId       = result.userId
                UserSession.shared.isLoggedIn   = true
                UserSession.shared.saveToDisk()   // BUG-2 FIX: was saveToDisK() — typo silently skipped Keychain write
                vm.onLoginSuccess()
                dismiss()
            } else {
                errorMsg = result.error
                // Report real failures so they surface automatically instead of only being
                // known if the user happens to report them — but skip the two cases that
                // are just the user closing the browser or double-tapping, not a bug.
                if !result.error.contains("cancelled") && !result.error.contains("already in progress") {
                    CrashReporter.reportIssue("Google sign-in failed: \(result.error)", category: "google_signin")
                }
            }
        }
    }

    func continueAsSaved() {
        isLoading = true
        errorMsg = ""
        Task {
            let ok = await UserSession.shared.tryRefreshAsync()
            isLoading = false
            if ok {
                vm.onLoginSuccess()
                dismiss()
            } else {
                errorMsg = "Your session expired. Please sign in again."
            }
        }
    }

    func forgotPassword() {
        guard !cleanEmail.isEmpty else {
            errorMsg = "Enter your email above, then tap Forgot password."
            return
        }
        // BUG-18 FIX: guard prevents spamming the Firebase reset endpoint via rapid taps.
        guard !isLoading else { return }
        isLoading = true
        Task {
            let sent = await sendPasswordReset(email: cleanEmail)
            isLoading = false
            if sent {
                successMsg = "Password reset email sent to \(cleanEmail)"
                errorMsg   = ""
            } else {
                errorMsg = "Could not send the reset email. Check the address and your connection."
            }
        }
    }

    // MARK: — Network

    func signInWithEmailPassword() async -> (success: Bool, error: String?) {
        guard let url = URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=\(AppConfig.firebaseApiKey)") else {
            return (false, "Config error")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15   // BUG-8 FIX: default 60s left spinner up for an entire minute on bad networks
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "email": cleanEmail, "password": password, "returnSecureToken": true
        ])
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return (false, "Sign in failed. Please try again.")
            }
            if let idToken      = obj["idToken"]      as? String,
               let refreshToken = obj["refreshToken"] as? String,
               let localId      = obj["localId"]      as? String {
                UserSession.shared.idToken       = idToken
                UserSession.shared.refreshToken  = refreshToken
                UserSession.shared.userId        = localId
                UserSession.shared.email         = cleanEmail
                UserSession.shared.name          = (obj["displayName"] as? String)
                    ?? cleanEmail.components(separatedBy: "@").first ?? "User"
                UserSession.shared.isLoggedIn    = true
                UserSession.shared.saveToDisk()   // BUG-2 FIX: was saveToDisK() typo
                return (true, nil)
            }
            // BUG-9 FIX: map raw Firebase error codes to user-friendly messages that don't
            // expose account enumeration (EMAIL_NOT_FOUND vs INVALID_PASSWORD tells attacker
            // which emails are registered — collapse both to the same message).
            let errCode = (obj["error"] as? [String: Any])?["message"] as? String ?? ""
            // Matched by the start: the service adds text after the code ("TOO_MANY_ATTEMPTS_TRY_LATER :
            // Access to this account has been temporarily disabled..."), and an exact match let that
            // fall through to a title-cased dump of the raw message.
            func code(_ c: String) -> Bool { errCode == c || errCode.hasPrefix(c + " ") }
            let errMsg: String
            if code("EMAIL_NOT_FOUND") || code("INVALID_PASSWORD") || code("INVALID_LOGIN_CREDENTIALS") {
                errMsg = "Incorrect email or password."
            } else if code("INVALID_EMAIL") {
                errMsg = "Please enter a valid email address."
            } else if code("USER_DISABLED") {
                errMsg = "This account has been disabled. Contact support."
            } else if code("TOO_MANY_ATTEMPTS_TRY_LATER") {
                errMsg = "Too many failed attempts. Please try again later."
            } else if code("MISSING_PASSWORD") || code("MISSING_EMAIL") {
                errMsg = "Please enter your email and password."
            } else {
                if !errCode.isEmpty { dlog("AUTH: sign in refused with code \(errCode.prefix(40))", tag: "AUTH") }
                errMsg = "Sign in failed. Please try again."
            }
            return (false, errMsg)
        } catch let urlErr as URLError where urlErr.code == .timedOut {
            return (false, "Connection timed out. Check your internet and try again.")
        } catch {
            return (false, "Connection error. Please try again.")
        }
    }

    // Firebase's accounts:signUp is the create-account counterpart to accounts:signInWithPassword
    // above — same identitytoolkit REST API, same API key, creates a brand-new user directly.
    func signUpWithEmailPassword() async -> (success: Bool, error: String?) {
        guard let url = URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=\(AppConfig.firebaseApiKey)") else {
            return (false, "Config error")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "email": cleanEmail, "password": password, "returnSecureToken": true
        ])
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return (false, "Could not create account. Please try again.")
            }
            if let idToken      = obj["idToken"]      as? String,
               let refreshToken = obj["refreshToken"] as? String,
               let localId      = obj["localId"]      as? String {
                let name = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
                // accounts:signUp doesn't accept displayName directly — it's set with a
                // follow-up accounts:update call so it's saved on the account for next time,
                // not just held locally for this session.
                await setDisplayName(idToken: idToken, name: name)
                UserSession.shared.idToken       = idToken
                UserSession.shared.refreshToken  = refreshToken
                UserSession.shared.userId        = localId
                UserSession.shared.email         = cleanEmail
                UserSession.shared.name          = name.isEmpty
                    ? (cleanEmail.components(separatedBy: "@").first ?? "User") : name
                UserSession.shared.isLoggedIn    = true
                UserSession.shared.saveToDisk()
                return (true, nil)
            }
            let errCode = (obj["error"] as? [String: Any])?["message"] as? String ?? ""
            func code(_ c: String) -> Bool { errCode == c || errCode.hasPrefix(c + " ") }
            let errMsg: String
            if code("EMAIL_EXISTS") {
                errMsg = "An account with this email already exists. Try signing in instead."
            } else if code("INVALID_EMAIL") {
                errMsg = "Please enter a valid email address."
            } else if code("WEAK_PASSWORD") {
                errMsg = "Password must be at least 6 characters."
            } else if code("OPERATION_NOT_ALLOWED") {
                errMsg = "Account creation is temporarily unavailable. Please try again later."
            } else if code("TOO_MANY_ATTEMPTS_TRY_LATER") {
                errMsg = "Too many attempts. Please try again later."
            } else if code("MISSING_PASSWORD") || code("MISSING_EMAIL") {
                errMsg = "Please enter your email and password."
            } else {
                if !errCode.isEmpty { dlog("AUTH: sign up refused with code \(errCode.prefix(40))", tag: "AUTH") }
                errMsg = "Could not create account. Please try again."
            }
            return (false, errMsg)
        } catch let urlErr as URLError where urlErr.code == .timedOut {
            return (false, "Connection timed out. Check your internet and try again.")
        } catch {
            return (false, "Connection error. Please try again.")
        }
    }

    private func setDisplayName(idToken: String, name: String) async {
        guard !name.isEmpty,
              let url = URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:update?key=\(AppConfig.firebaseApiKey)")
        else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "idToken": idToken, "displayName": name, "returnSecureToken": false
        ])
        _ = try? await URLSession.shared.data(for: req)
    }

    func sendPasswordReset(email: String) async -> Bool {
        guard let url = URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:sendOobCode?key=\(AppConfig.firebaseApiKey)") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["requestType": "PASSWORD_RESET", "email": email])
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }
}

// ── Google "G" logo shape ──────────────────────────────────────────────────────
struct GoogleLogoShape: View {
    var body: some View {
        Canvas { ctx, size in
            let s = size.width
            // Draw a simplified "G" using arcs and filled segments
            // Using the 4-color Google logo path
            let center = CGPoint(x: s / 2, y: s / 2)
            let radius = s * 0.45
            // White base circle
            ctx.fill(Path(ellipseIn: CGRect(x: s*0.05, y: s*0.05, width: s*0.9, height: s*0.9)),
                     with: .color(.white))
            // Red top-right
            var red = Path(); red.addArc(center: center, radius: radius, startAngle: .degrees(-15), endAngle: .degrees(90), clockwise: false)
            red.addLine(to: center); red.closeSubpath()
            ctx.fill(red, with: .color(Color(hex: "#EA4335")))
            // Green bottom-right
            var green = Path(); green.addArc(center: center, radius: radius, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            green.addLine(to: center); green.closeSubpath()
            ctx.fill(green, with: .color(Color(hex: "#34A853")))
            // Yellow bottom-left
            var yellow = Path(); yellow.addArc(center: center, radius: radius, startAngle: .degrees(180), endAngle: .degrees(255), clockwise: false)
            yellow.addLine(to: center); yellow.closeSubpath()
            ctx.fill(yellow, with: .color(Color(hex: "#FBBC05")))
            // Blue top-left
            var blue = Path(); blue.addArc(center: center, radius: radius, startAngle: .degrees(255), endAngle: .degrees(345), clockwise: false)
            blue.addLine(to: center); blue.closeSubpath()
            ctx.fill(blue, with: .color(Color(hex: "#4285F4")))
            // White inner circle
            let inner = s * 0.28
            ctx.fill(Path(ellipseIn: CGRect(x: center.x - inner/2, y: center.y - inner/2, width: inner, height: inner)),
                     with: .color(.white))
            // White horizontal bar for the G cutout
            let barH = s * 0.12
            let barW = s * 0.38
            ctx.fill(Path(CGRect(x: center.x, y: center.y - barH/2, width: barW, height: barH)),
                     with: .color(.white))
        }
    }
}


// ── Buttons and links for the light sign-in page ───────────────────────────────
// A shared dark-window icon button turned invisible on white on Windows, so the close button, the
// links and the two main buttons are their own, drawn for a light page.
struct LoginCloseButton: View {
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundColor(Color(hex: "#5A5F55"))
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color(hex: "#FDF1F1") : Color(hex: "#F0F2EE")))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(hovering ? Color(hex: "#F3C6C6") : Color(hex: "#DCE4D8"), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Close")
        .accessibilityLabel("Close")
    }
}

struct LoginLinkStyle: ButtonStyle {
    var size: CGFloat
    func makeBody(configuration: Configuration) -> some View {
        LinkBody(configuration: configuration, size: size)
    }
    private struct LinkBody: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(.system(size: size, weight: .medium))
                .foregroundColor(hovering ? Color(hex: "#21924A") : Color(hex: "#1C7A3E"))
                .underline(hovering)
                .opacity(configuration.isPressed ? 0.7 : 1)
                .onHover { hovering = $0 }
        }
    }
}

struct LoginPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryBody(configuration: configuration)
    }
    private struct PrimaryBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false
        var body: some View {
            configuration.label
                .foregroundColor(.white)
                .background(
                    RoundedRectangle(cornerRadius: 7).fill(
                        LinearGradient(colors: [Color(hex: "#1C7A3E"), Color(hex: hovering ? "#26A053" : "#21924A")],
                                       startPoint: .leading, endPoint: .trailing)))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(hex: "#1C7A3E"), lineWidth: 1))
                .scaleEffect(configuration.isPressed ? 0.985 : 1)
                .opacity(enabled ? 1 : 0.55)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

struct LoginSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SecondaryBody(configuration: configuration)
    }
    private struct SecondaryBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false
        var body: some View {
            configuration.label
                .foregroundColor(Color(hex: "#16150F"))
                .background(RoundedRectangle(cornerRadius: 7).fill(
                    configuration.isPressed ? Color(hex: "#EEF2EC") : (hovering ? Color(hex: "#F6F8F3") : Color.white)))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(hovering ? Color(hex: "#C7D4C4") : Color(hex: "#DCE4D8"), lineWidth: 1))
                .opacity(enabled ? 1 : 0.55)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

/// A scroll view that can be left out. See LoginView.flat.
struct MaybeScroll<Content: View>: View {
    let flat: Bool
    @ViewBuilder let content: () -> Content
    var body: some View {
        if flat { content() } else { ScrollView { content() }.scrollIndicators(.hidden) }
    }
}
