import SwiftUI

struct LoginView: View {
    @Environment(MainViewModel.self) var vm
    @Environment(\.dismiss) var dismiss

    @State private var email       = ""
    @State private var password    = ""
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

    // Saved account for "Continue As" card
    private var savedEmail: String { UserSession.shared.email }
    // BUG-14 FIX: check refreshToken (not idToken) — idToken can be populated even when
    // expired, so the "Continue As" card would show for an unusable token.
    private var hasSavedAccount: Bool { !savedEmail.isEmpty && !UserSession.shared.refreshToken.isEmpty }

    var body: some View {
        ZStack {
            // Background
            Color(red: 13/255, green: 17/255, blue: 23/255).ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {

                    // ── Logo + Brand ──────────────────────────────────
                    VStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(Color(red: 56/255, green: 189/255, blue: 248/255).opacity(0.15))
                                .frame(width: 64, height: 64)
                            Image(systemName: "brain.head.profile")
                                .font(.system(size: 30))
                                .foregroundColor(Color(hex: "#38bdf8"))
                        }
                        Text("Replysis")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.white)
                        Text("Your AI-powered interview assistant")
                            .font(.system(size: 13))
                            .foregroundColor(Color(hex: "#6b7280"))
                    }
                    .padding(.top, 36)
                    .padding(.bottom, 28)

                    // ── Error / Success Banner ────────────────────────
                    if !errorMsg.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundColor(Color(hex: "#ef4444"))
                            Text(errorMsg)
                                .font(.system(size: 13))
                                .foregroundColor(Color(hex: "#fca5a5"))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Color(hex: "#ef4444").opacity(0.12))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: "#ef4444").opacity(0.3), lineWidth: 1))
                        .cornerRadius(8)
                        .padding(.horizontal, 28)
                        .padding(.bottom, 16)
                        .transition(.opacity)
                    }

                    if !successMsg.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(Color(hex: "#4ade80"))
                            Text(successMsg)
                                .font(.system(size: 13))
                                .foregroundColor(Color(hex: "#86efac"))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Color(hex: "#4ade80").opacity(0.12))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: "#4ade80").opacity(0.3), lineWidth: 1))
                        .cornerRadius(8)
                        .padding(.horizontal, 28)
                        .padding(.bottom, 16)
                        .transition(.opacity)
                    }

                    // ── "Continue As" card ────────────────────────────
                    if hasSavedAccount {
                        Button(action: continueAsSaved) {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(Color(hex: "#1e3a5f"))
                                        .frame(width: 38, height: 38)
                                    Text(UserSession.shared.initials.isEmpty ? "?" : UserSession.shared.initials)
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundColor(Color(hex: "#38bdf8"))
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Continue as \(UserSession.shared.firstName)")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.white)
                                    Text(savedEmail)
                                        .font(.system(size: 12))
                                        .foregroundColor(Color(hex: "#6b7280"))
                                }
                                Spacer()
                                if isLoading {
                                    ProgressView().scaleEffect(0.7)
                                } else {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(Color(hex: "#38bdf8"))
                                }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            .background(Color(hex: "#0d2540"))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: "#1e40af").opacity(0.6), lineWidth: 1))
                            .cornerRadius(10)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 28)
                        .padding(.bottom, 20)
                    }

                    // ── Card background ───────────────────────────────
                    VStack(spacing: 16) {

                        // Email field
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Email")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Color(hex: "#9ca3af"))
                            TextField("you@example.com", text: $email)
                                .textFieldStyle(.plain)
                                .autocorrectionDisabled()
                                .padding(.horizontal, 12).padding(.vertical, 9)
                                .background(Color(hex: "#161b22"))
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.12), lineWidth: 1))
                                .cornerRadius(7)
                                .foregroundColor(.white)
                                .font(.system(size: 14))
                        }

                        // Password field
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Password")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(Color(hex: "#9ca3af"))
                                Spacer()
                                Button("Forgot password?") { forgotPassword() }
                                    .font(.system(size: 12))
                                    .foregroundColor(Color(hex: "#38bdf8"))
                                    .buttonStyle(.plain)
                            }
                            SecureField("••••••••", text: $password)
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 12).padding(.vertical, 9)
                                .background(Color(hex: "#161b22"))
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.12), lineWidth: 1))
                                .cornerRadius(7)
                                .foregroundColor(.white)
                                .font(.system(size: 14))
                        }

                        // Sign In button
                        Button(action: signIn) {
                            HStack(spacing: 8) {
                                if isLoading { ProgressView().scaleEffect(0.75).tint(.white) }
                                Text("Sign In")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .foregroundColor(.white)
                            .padding(.vertical, 11)
                            .background(
                                LinearGradient(colors: [Color(hex: "#1d4ed8"), Color(hex: "#1e40af")],
                                               startPoint: .leading, endPoint: .trailing)
                            )
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                        .disabled(isLoading)

                        // ── OR divider + Continue with Google ──
                        // Only shown once a real client secret is confirmed present — see
                        // googleSignInAvailable's declaration for why.
                        if googleSignInAvailable {
                            HStack(spacing: 12) {
                                Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
                                Text("OR").font(.system(size: 11)).foregroundColor(Color(hex: "#4b5563"))
                                Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
                            }

                            Button(action: signInWithGoogle) {
                                HStack(spacing: 10) {
                                    GoogleLogoShape().frame(width: 18, height: 18)
                                    Text("Continue with Google")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.white)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(Color(hex: "#1f2937"))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.18), lineWidth: 1))
                                .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                            .disabled(isLoading)
                        }
                    }
                    .padding(24)
                    .background(Color(hex: "#0d1117").opacity(0.5))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08), lineWidth: 1))
                    .cornerRadius(12)
                    .padding(.horizontal, 28)

                    // ── Footer: Sign up link + Cancel ─────────────────
                    VStack(spacing: 12) {
                        HStack(spacing: 4) {
                            Text("Don't have an account?")
                                .font(.system(size: 12))
                                .foregroundColor(Color(hex: "#6b7280"))
                            Link("Sign up at coopilotxai.com",
                                 destination: URL(string: "https://coopilotxai.com")!)
                                .font(.system(size: 12))
                                .foregroundColor(Color(hex: "#38bdf8"))
                        }

                        Button("Cancel") { dismiss() }
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "#6b7280"))
                            .buttonStyle(.plain)
                    }
                    .padding(.top, 20)
                    .padding(.bottom, 32)
                }
            }
        }
        // Tall enough that the Cancel button is always visible without scrolling.
        .frame(width: 400, height: hasSavedAccount ? 700 : 620)
        .task {
            // Check whether Google sign-in can actually succeed BEFORE showing its button.
            // Baked-in secret (set via the GOOGLE_CLIENT_SECRET GitHub secret at build time)
            // is checked first; if that's empty, try the remote-config fetch once as a
            // fallback. Either way, the button only appears once this resolves true.
            if AppConfig.googleClientSecret.isEmpty { await AppConfig.fetchRemoteConfig() }
            googleSignInAvailable = !AppConfig.googleClientSecret.isEmpty
        }
    }

    // MARK: — Actions

    func signIn() {
        guard !email.isEmpty && !password.isEmpty else {
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
                errorMsg = "Session expired — please sign in again."
            }
        }
    }

    func forgotPassword() {
        guard !email.isEmpty else {
            errorMsg = "Enter your email above, then tap Forgot password."
            return
        }
        // BUG-18 FIX: guard prevents spamming the Firebase reset endpoint via rapid taps.
        guard !isLoading else { return }
        isLoading = true
        Task {
            let sent = await sendPasswordReset(email: email)
            isLoading = false
            if sent {
                successMsg = "Password reset email sent to \(email)"
                errorMsg   = ""
            } else {
                errorMsg = "Could not send reset email. Check the address."
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
            "email": email, "password": password, "returnSecureToken": true
        ])
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return (false, "Invalid response")
            }
            if let idToken      = obj["idToken"]      as? String,
               let refreshToken = obj["refreshToken"] as? String,
               let localId      = obj["localId"]      as? String {
                UserSession.shared.idToken       = idToken
                UserSession.shared.refreshToken  = refreshToken
                UserSession.shared.userId        = localId
                UserSession.shared.email         = email
                UserSession.shared.name          = (obj["displayName"] as? String)
                    ?? email.components(separatedBy: "@").first ?? "User"
                UserSession.shared.isLoggedIn    = true
                UserSession.shared.saveToDisk()   // BUG-2 FIX: was saveToDisK() typo
                return (true, nil)
            }
            // BUG-9 FIX: map raw Firebase error codes to user-friendly messages that don't
            // expose account enumeration (EMAIL_NOT_FOUND vs INVALID_PASSWORD tells attacker
            // which emails are registered — collapse both to the same message).
            let errCode = (obj["error"] as? [String: Any])?["message"] as? String ?? ""
            let errMsg: String
            switch errCode {
            case "EMAIL_NOT_FOUND", "INVALID_PASSWORD", "INVALID_LOGIN_CREDENTIALS":
                errMsg = "Incorrect email or password."
            case "USER_DISABLED":
                errMsg = "This account has been disabled. Contact support."
            case "TOO_MANY_ATTEMPTS_TRY_LATER":
                errMsg = "Too many failed attempts. Please try again later."
            case "WEAK_PASSWORD":
                errMsg = "Password must be at least 6 characters."
            default:
                errMsg = errCode.isEmpty ? "Sign in failed. Please try again." :
                    errCode.replacingOccurrences(of: "_", with: " ").capitalized
            }
            return (false, errMsg)
        } catch let urlErr as URLError where urlErr.code == .timedOut {
            return (false, "Connection timed out. Check your internet and try again.")
        } catch {
            return (false, "Connection error. Please try again.")
        }
    }

    func sendPasswordReset(email: String) async -> Bool {
        guard let url = URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:sendOobCode?key=\(AppConfig.firebaseApiKey)") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
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
