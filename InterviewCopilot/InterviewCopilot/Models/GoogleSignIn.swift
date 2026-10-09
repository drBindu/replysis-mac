import Foundation
import CryptoKit
import AppKit

// Google OAuth 2.0 — RFC 8252 loopback redirect + PKCE
// Matches original .NET GoogleSignIn.cs exactly:
//   redirect_uri = http://127.0.0.1:PORT/  (registered in Google Cloud Console)
//   Opens default browser via NSWorkspace, catches redirect on local HTTP server
@MainActor
class GoogleSignIn {

    static let shared = GoogleSignIn()
    private init() {}

    struct Result {
        let success: Bool
        let idToken: String
        let refreshToken: String
        let email: String
        let displayName: String
        let userId: String
        let error: String

        static func failure(_ msg: String) -> Result {
            Result(success: false, idToken: "", refreshToken: "", email: "", displayName: "", userId: "", error: msg)
        }
    }

    private static var isSigningIn = false

    static func signIn() async -> Result {
        guard !isSigningIn else {
            dlog("Google Sign In: already in progress — ignoring duplicate call", tag: "GOOGLE")
            return .failure("Sign-in already in progress.")
        }
        isSigningIn = true
        defer { isSigningIn = false }
        dlog("Google Sign In: starting loopback flow", tag: "GOOGLE")

        guard let (serverFd, port) = bindListenSocket() else {
            return .failure("Could not bind local port for OAuth redirect.")
        }

        let redirectUri   = "http://127.0.0.1:\(port)/"
        let codeVerifier  = randomBase64url(bytes: 32)
        let codeChallenge = sha256Base64url(codeVerifier)
        let state         = randomBase64url(bytes: 16)

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            URLQueryItem(name: "client_id",             value: AppConfig.googleClientId),
            URLQueryItem(name: "redirect_uri",          value: redirectUri),
            URLQueryItem(name: "response_type",         value: "code"),
            URLQueryItem(name: "scope",                 value: "openid email profile"),
            URLQueryItem(name: "code_challenge",        value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state",                 value: state),
            URLQueryItem(name: "access_type",           value: "offline"),
            URLQueryItem(name: "prompt",                value: "select_account"),
        ]
        guard let authURL = comps.url else {
            Darwin.close(serverFd)
            return .failure("Could not build Google auth URL.")
        }

        dlog("Google: opening browser on port \(port)", tag: "GOOGLE")
        NSWorkspace.shared.open(authURL)

        guard let cb = await waitForCallback(serverFd: serverFd, expectedState: state) else {
            return .failure("Sign-in timed out (2 min). Please try again.")
        }
        guard cb.stateValid else { return .failure("Security check failed. Please try again.") }
        guard let code = cb.code  else { return .failure(cb.error ?? "Google sign-in was cancelled.") }

        dlog("Google: got code, exchanging for tokens…", tag: "GOOGLE")

        // ROOT CAUSE FOUND & CONFIRMED (2026-07-16): the backend endpoint does the ENTIRE
        // sign-in server-side now (exchanges the code with Google, then calls Firebase's
        // signInWithIdp itself) and returns an already-complete Firebase session — not raw
        // Google tokens. The old code here treated it as raw tokens and sent the resulting
        // (already-Firebase-issued) idToken to Firebase AGAIN as if it still needed
        // validating as a Google token — which Firebase correctly rejected, since it isn't
        // one anymore. Verified live: decoded a real token from this endpoint and confirmed
        // iss=securetoken.google.com/copilotx-ai (a genuine Firebase token), not
        // accounts.google.com. Fix: the backend path returns a finished Result directly,
        // no second Firebase call. One path only, never try-then-fallback with the same code
        // (Google's auth codes are single-use, which is what broke the OLD fallback approach).
        // Always the server, as on Windows: it holds the Google client secret, so this app needs no key of its own. (This used to be
        // a 10 percent rollout, with the old direct path for everyone else. That path needs a secret nobody ships, so the button
        // was hidden for all users and Google sign-in was missing from the Mac app.)
        guard let result = await exchangeCodeViaBackend(code, redirectUri: redirectUri, verifier: codeVerifier) else {
            return .failure("Google sign-in is temporarily unavailable. Please sign in with your email and password above.")
        }
        return result
    }

    // MARK: — Socket

    private static func bindListenSocket() -> (Int32, Int)? {
        guard let bound = OAuthLoopback.bind() else {
            dlog("Google: could not open the local listening port", tag: "GOOGLE")
            return nil
        }
        dlog("Google: listening on port \(bound.port)", tag: "GOOGLE")
        return (bound.fd, bound.port)
    }

    // MARK: — Callback Listener

    private typealias Callback = OAuthLoopback.Callback

    /// Waits for this attempt's answer for two minutes. A browser's spare connections and its request for an icon
    /// are not the answer and are ignored (see OAuthLoopback).
    private static func waitForCallback(serverFd: Int32, expectedState: String) async -> Callback? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: OAuthLoopback.waitForCallback(
                    serverFd: serverFd, expectedState: expectedState, timeout: 120,
                    successHTML: successHTML, failHTML: failHTML))
            }
        }
    }

    // MARK: — Token Exchange

    // Backend does the ENTIRE sign-in server-side and hands back an already-complete
    // Firebase session: { idToken, refreshToken, email, displayName, localId }. This is
    // NOT raw Google tokens — do not pass idToken on to any further
    // Firebase call. Verified live against the real endpoint (2026-07-16): confirmed
    // HTTP 200 with all 5 fields, and confirmed by decoding idToken that its issuer is
    // securetoken.google.com (a genuine Firebase token), not accounts.google.com.
    private static func exchangeCodeViaBackend(_ code: String, redirectUri: String, verifier: String) async -> Result? {
        guard let url = URL(string: "\(AppConfig.backendUrl)/api/v1/auth/google/exchange") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "code": code, "codeVerifier": verifier, "redirectUri": redirectUri
        ])
        do {
            let (data, resp) = try await URLSession.shared.data(for: AppIdentity.label(req))
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                dlog("Google: backend exchange HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)", tag: "GOOGLE")
                return nil
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let idToken      = obj["idToken"] as? String ?? ""
            let refreshToken = obj["refreshToken"] as? String ?? ""
            let email        = obj["email"] as? String ?? ""
            let localId      = obj["localId"] as? String ?? ""
            var displayName  = obj["displayName"] as? String ?? ""
            if displayName.isEmpty { displayName = email.components(separatedBy: "@").first ?? email }
            guard !idToken.isEmpty, !localId.isEmpty else {
                dlog("Google: backend exchange missing required fields — treating as unavailable", tag: "GOOGLE")
                return nil
            }
            dlog("Google: backend exchange OK (full Firebase session) — \(UserSession.maskEmail(email))", tag: "GOOGLE")
            return Result(success: true, idToken: idToken, refreshToken: refreshToken,
                          email: email, displayName: displayName, userId: localId, error: "")
        } catch {
            dlog("Google: backend exchange request failed: \(error.localizedDescription)", tag: "GOOGLE")
            return nil
        }
    }

    // MARK: — PKCE

    private static func randomBase64url(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func sha256Base64url(_ input: String) -> String {
        let hash = SHA256.hash(data: Data(input.utf8))
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: — HTML pages shown in browser after redirect

    nonisolated private static let successHTML = """
    <html><head><title>Replysis</title></head>
    <body style='font-family:-apple-system,sans-serif;text-align:center;padding-top:80px;background:#0d1117;color:#e6edf3;'>
    <h2 style='color:#4ade80'>&#10003; Signed in!</h2>
    <p>You can close this tab and return to Replysis.</p>
    </body></html>
    """

    nonisolated private static let failHTML = """
    <html><head><title>Replysis</title></head>
    <body style='font-family:-apple-system,sans-serif;text-align:center;padding-top:80px;background:#0d1117;color:#e6edf3;'>
    <h2 style='color:#ef4444'>Sign-in cancelled</h2>
    <p>Please close this tab and try again in Replysis.</p>
    </body></html>
    """
}
