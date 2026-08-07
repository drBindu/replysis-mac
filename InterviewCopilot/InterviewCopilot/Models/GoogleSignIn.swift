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

        // The client secret is loaded from remote config. If it hasn't arrived yet, try
        // once now so we don't fail the token exchange purely for a missing secret.
        if AppConfig.googleClientSecret.isEmpty { await AppConfig.fetchRemoteConfig() }

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
        // no second Firebase call. Gradual rollout via RolloutGate — straight either/or per
        // device, never try-then-fallback with the same code (Google's auth codes are
        // single-use, which is what broke the OLD fallback approach).
        if RolloutGate.isEnabled("backend_google_exchange", percent: 10) {
            if let result = await exchangeCodeViaBackend(code, redirectUri: redirectUri, verifier: codeVerifier) {
                return result
            }
            return .failure("Google sign-in is temporarily unavailable. Please sign in with your email and password above.")
        }

        guard let tokens = await exchangeCodeDirect(code, redirectUri: redirectUri, verifier: codeVerifier) else {
            return .failure("Google sign-in is temporarily unavailable. Please sign in with your email and password above.")
        }

        dlog("Google: signing into Firebase…", tag: "GOOGLE")
        return await firebaseSignIn(tokens: tokens)
    }

    // MARK: — Socket

    private static func bindListenSocket() -> (Int32, Int)? {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { dlog("Google: socket() failed", tag: "GOOGLE"); return nil }
        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port   = 0
        // Bind to 127.0.0.1 ONLY (RFC 8252 loopback) — not 0.0.0.0, which would expose
        // the OAuth callback port to the whole local network.
        addr.sin_addr   = in_addr(s_addr: inet_addr("127.0.0.1"))
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ok == 0 else {
            dlog("Google: bind failed errno=\(errno) (\(String(cString:strerror(errno))))", tag: "GOOGLE")
            Darwin.close(sock); return nil
        }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(sock, $0, &len) }
        }
        let port = Int(addr.sin_port.bigEndian)
        listen(sock, 1)
        dlog("Google: listening on port \(port)", tag: "GOOGLE")
        return (sock, port)
    }

    // MARK: — Callback Listener

    private struct Callback {
        let code: String?
        let stateValid: Bool
        let error: String?
    }

    private static func waitForCallback(serverFd: Int32, expectedState: String) async -> Callback? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                defer { Darwin.close(serverFd) }
                var tv = timeval(tv_sec: 120, tv_usec: 0)
                setsockopt(serverFd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

                let client = accept(serverFd, nil, nil)
                guard client >= 0 else { continuation.resume(returning: nil); return }
                defer { Darwin.close(client) }

                // Read timeout on the CLIENT too — otherwise a connection that opens but
                // never sends data would block recv() forever and hang the sign-in spinner.
                var ctv = timeval(tv_sec: 15, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &ctv, socklen_t(MemoryLayout<timeval>.size))

                var buf = [UInt8](repeating: 0, count: 8192)
                let n = recv(client, &buf, buf.count - 1, 0)
                guard n > 0 else { continuation.resume(returning: nil); return }

                let req = String(bytes: buf.prefix(n), encoding: .utf8) ?? ""
                let cb  = parseRequest(req, expectedState: expectedState)

                let html = (cb.code != nil && cb.stateValid) ? successHTML : failHTML
                let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
                resp.withCString { _ = send(client, $0, strlen($0), 0) }

                continuation.resume(returning: cb)
            }
        }
    }

    nonisolated private static func parseRequest(_ req: String, expectedState: String) -> Callback {
        guard let line  = req.components(separatedBy: "\r\n").first,
              let qMark = line.range(of: "?"),
              let http  = line.range(of: " HTTP") else {
            return Callback(code: nil, stateValid: false, error: "Invalid callback")
        }
        var params: [String: String] = [:]
        for pair in String(line[qMark.upperBound ..< http.lowerBound]).components(separatedBy: "&") {
            // Split on the FIRST '=' only — a value can itself contain '=' (base64),
            // and the old kv.count==2 check silently dropped those params.
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let key = String(pair[..<eq])
            let val = String(pair[pair.index(after: eq)...])
            params[key] = val.removingPercentEncoding ?? val
        }
        return Callback(
            code:       params["code"],
            stateValid: (params["state"] ?? "") == expectedState,
            error:      params["error"] == nil ? nil : "Google sign-in was cancelled."
        )
    }

    // MARK: — Token Exchange

    private struct TokenResponse {
        let idToken: String
        let accessToken: String
    }

    // Backend does the ENTIRE sign-in server-side and hands back an already-complete
    // Firebase session: { idToken, refreshToken, email, displayName, localId }. This is
    // NOT raw Google tokens — do not pass idToken to firebaseSignIn() or any further
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
            let (data, resp) = try await URLSession.shared.data(for: req)
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

    private static func exchangeCodeDirect(_ code: String, redirectUri: String, verifier: String) async -> TokenResponse? {
        guard let url = URL(string: "https://oauth2.googleapis.com/token") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let enc = { (s: String) in
            s.addingPercentEncoding(withAllowedCharacters: .init(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? s
        }
        // Include client_secret only when we actually have one. For a "Desktop app" OAuth
        // client, the PKCE code_verifier alone can satisfy the exchange — so omitting an
        // empty secret gives sign-in a chance to work even when remote config is down.
        var bodyStr = "code=\(enc(code))&client_id=\(AppConfig.googleClientId)&redirect_uri=\(enc(redirectUri))&code_verifier=\(verifier)&grant_type=authorization_code"
        if !AppConfig.googleClientSecret.isEmpty {
            bodyStr += "&client_secret=\(AppConfig.googleClientSecret)"
        }
        req.httpBody = bodyStr.data(using: .utf8)

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                dlog("Google: bad JSON: \(String(data:data,encoding:.utf8) ?? "")", tag: "GOOGLE"); return nil
            }
            if let err = obj["error"] {
                dlog("Google token error: \(err) — \(obj["error_description"] ?? "")", tag: "GOOGLE"); return nil
            }
            let idToken     = obj["id_token"]      as? String ?? ""
            let accessToken = obj["access_token"]  as? String ?? ""
            guard !idToken.isEmpty || !accessToken.isEmpty else {
                dlog("Google: token exchange returned empty tokens", tag: "GOOGLE"); return nil
            }
            dlog("Google: token exchange OK — idToken=\(!idToken.isEmpty) accessToken=\(!accessToken.isEmpty)", tag: "GOOGLE")
            return TokenResponse(idToken: idToken, accessToken: accessToken)
        } catch {
            dlog("Google: token exchange failed: \(error)", tag: "GOOGLE"); return nil
        }
    }

    private static func firebaseSignIn(tokens: TokenResponse) async -> Result {
        let urlStr = "https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp?key=\(AppConfig.firebaseApiKey)"
        guard let url = URL(string: urlStr) else { return .failure("Firebase URL error") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Send access_token (not id_token) so Firebase validates via Google's tokeninfo
        // endpoint rather than checking the audience — works across GCP projects.
        var postBody = "access_token=\(tokens.accessToken)&providerId=google.com"
        if !tokens.idToken.isEmpty { postBody += "&id_token=\(tokens.idToken)" }
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "postBody": postBody,
            "requestUri": "http://localhost",
            "returnIdpCredential": true,
            "returnSecureToken": true
        ])
        guard let (data, _) = try? await URLSession.shared.data(for: req) else {
            return .failure("Network error during Firebase sign-in.")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure("Invalid Firebase response")
        }
        if let err = (obj["error"] as? [String: Any])?["message"] as? String {
            return .failure("Google sign-in failed: \(err)")
        }
        let idToken      = obj["idToken"]      as? String ?? ""
        let refreshToken = obj["refreshToken"] as? String ?? ""
        let email        = obj["email"]        as? String ?? ""
        let userId       = obj["localId"]      as? String ?? ""
        var displayName  = obj["displayName"]  as? String ?? ""
        if displayName.isEmpty { displayName = email.components(separatedBy: "@").first ?? email }
        dlog("Google sign-in success: \(UserSession.maskEmail(email))", tag: "GOOGLE")
        return Result(success: true, idToken: idToken, refreshToken: refreshToken,
                      email: email, displayName: displayName, userId: userId, error: "")
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
