import Foundation
import Security

// MARK: - Keychain (secure storage for auth tokens — replaces plaintext session.json)
private enum Keychain {
    private static let service = "com.coopilotx.InterviewCopilot.session"

    static func save(_ data: Data, account: String) {
        let base: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)   // replace any existing item
        var add = base
        add[kSecValueData as String]      = data
        // ...ThisDeviceOnly: the auth token never leaves this Mac — it's excluded from
        // iCloud Keychain sync and from encrypted backups that could be restored onto a
        // different machine. For a login credential that's the correct, device-bound
        // choice; the app only ever reads it locally, so behavior is unchanged. Still
        // AfterFirstUnlock (not WhenUnlocked) so session restore works right after a
        // reboot even before the user re-unlocks.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

@MainActor
class UserSession {
    static let shared = UserSession()

    var isLoggedIn = false
    var email = ""
    var name = ""
    var idToken = ""
    var refreshToken = ""
    var userId = ""
    var credits = 0
    var plan = "free"
    var isUnlimited = false
    var speechmaticsKey = ""

    // True for the free-trial-without-sign-in path (see startGuestSession()) — isLoggedIn
    // is also true in this state so every existing `session.isLoggedIn` gate throughout
    // MainViewModel (Space handling, engine start, ask/analyze credit checks) works for
    // guests with zero changes to those call sites. This flag exists only so the UI can
    // show honest "free trial" messaging and so a real sign-in is never confused with it.
    var isGuestSession = false

    private let sessionFile: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("InterviewCopilot")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("session.json")
    }()

    private(set) var tokenSavedAt: Date = .distantPast
    private let tokenValidMinutes: Double = 55

    /// True when the token should be proactively refreshed (within 5 min of expiry).
    var tokenNeedsRefresh: Bool {
        Date().timeIntervalSince(tokenSavedAt) > (tokenValidMinutes - 5) * 60
    }

    private init() {}

    var initials: String {
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            return String(parts[0].prefix(1)) + String(parts[1].prefix(1))
        }
        return String(name.prefix(2)).uppercased()
    }

    var firstName: String { name.components(separatedBy: " ").first ?? name }

    // MARK: - Persistence

    func saveToDisk() {
        let data: [String: Any] = [
            "email": email, "name": name,
            "idToken": idToken, "refreshToken": refreshToken,
            "userId": userId, "savedAt": Date().timeIntervalSince1970
        ]
        guard let blob = try? JSONSerialization.data(withJSONObject: data) else { return }
        Keychain.save(blob, account: "session")
        // Remove any legacy plaintext copy.
        try? FileManager.default.removeItem(at: sessionFile)
    }

    func tryLoadFromDisk() -> Bool {
        dlog("Session: trying to load from Keychain", tag: "AUTH")
        var blob = Keychain.load(account: "session")
        // One-time migration: if there's an old plaintext session.json, import it then delete it.
        if blob == nil, let fileData = try? Data(contentsOf: sessionFile) {
            blob = fileData
            Keychain.save(fileData, account: "session")
            try? FileManager.default.removeItem(at: sessionFile)
            dlog("Session: migrated plaintext session.json → Keychain", tag: "AUTH")
        }
        guard let data = blob,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            dlog("Session: no saved session found", tag: "AUTH")
            return false
        }

        let savedAt = obj["savedAt"] as? Double ?? 0
        let ageMinutes = (Date().timeIntervalSince1970 - savedAt) / 60

        email        = obj["email"]        as? String ?? ""
        name         = obj["name"]         as? String ?? ""
        idToken      = obj["idToken"]      as? String ?? ""
        refreshToken = obj["refreshToken"] as? String ?? ""
        userId       = obj["userId"]       as? String ?? ""

        if ageMinutes > tokenValidMinutes {
            dlog("Session: token expired (\(Int(ageMinutes)) min old)", tag: "AUTH")
            return false
        }
        tokenSavedAt = Date(timeIntervalSince1970: savedAt)
        isLoggedIn = !idToken.isEmpty
        // Log a MASKED email, never the full address. The debug log is a file users are
        // actively told to Reveal and share for support (see DebugLogView) — a full email
        // in there leaks PII the moment it's forwarded or pasted. The mask still identifies
        // the account well enough to debug ("pk***@gmail.com").
        dlog("Session: loaded from disk — email=\(Self.maskEmail(email)), loggedIn=\(isLoggedIn), age=\(Int(ageMinutes))min", tag: "AUTH")
        return isLoggedIn
    }

    /// Mask an email for logging: keep the first 2 chars of the local part and the full
    /// domain, star out the rest — enough to recognize the account, not enough to expose it.
    static func maskEmail(_ email: String) -> String {
        let parts = email.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { return email.isEmpty ? "(none)" : "***" }
        let local = String(parts[0])
        let head = local.count <= 2 ? local : String(local.prefix(2))
        return "\(head)***@\(parts[1])"
    }

    func clear() {
        isLoggedIn = false
        isGuestSession = false
        email = ""; name = ""; idToken = ""; refreshToken = ""
        userId = ""; credits = 0; plan = "free"; isUnlimited = false
        speechmaticsKey = ""
        Keychain.delete(account: "session")
        try? FileManager.default.removeItem(at: sessionFile)
    }

    // MARK: - Token Refresh

    private var refreshTask: Task<Bool, Never>?

    func tryRefreshAsync() async -> Bool {
        // Coalesce concurrent callers — only one network round-trip per refresh cycle.
        // Without this, two simultaneous Space presses each consume the refresh token,
        // leaving the second response with an already-invalidated token.
        if let existing = refreshTask { return await existing.value }
        guard !refreshToken.isEmpty else { return false }
        let rt = refreshToken

        let task = Task<Bool, Never> { [weak self] in
            guard let self,
                  let url = URL(string: "https://securetoken.googleapis.com/v1/token?key=\(AppConfig.firebaseApiKey)")
            else { return false }

            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 10   // default 60 s would block Space for a full minute on bad networks
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body = ["grant_type": "refresh_token", "refresh_token": rt]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)

            do {
                let (data, _) = try await URLSession.shared.data(for: req)
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let newToken = obj["id_token"] as? String,
                      let newRefresh = obj["refresh_token"] as? String else { return false }
                self.idToken = newToken
                self.refreshToken = newRefresh
                self.tokenSavedAt = Date()
                self.isLoggedIn = true
                self.saveToDisk()
                return true
            } catch {
                return false
            }
        }
        refreshTask = task
        let result = await task.value
        refreshTask = nil
        return result
    }

    // MARK: - Guest (free trial without sign-in)

    // Tries to start a device-ID-based free trial when there's no real saved account to
    // restore. Fails harmlessly (returns false) if offline or this device's free credits
    // are already used up — callers fall back to the existing "not signed in" prompt.
    func startGuestSession() async -> Bool {
        guard let result = await NetworkClient.shared.fetchCredits(), result.credits > 0 else {
            dlog("Guest session: no free credits available for this device", tag: "AUTH")
            return false
        }
        isGuestSession = true
        isLoggedIn = true
        credits = result.credits
        plan = result.plan
        isUnlimited = result.isUnlimited
        name = "Guest"
        email = ""
        dlog("Guest session started — credits=\(result.credits)", tag: "AUTH")
        return true
    }

    // MARK: - Speechmatics Key

    func fetchSpeechmaticsKeyAsync() async -> Bool {
        guard !idToken.isEmpty || isGuestSession else {
            dlog("SM key fetch: no idToken and not a guest session — not logged in", tag: "AUTH")
            return false
        }
        let urlStr = "\(AppConfig.backendUrl)/api/v1/stt/key"
        dlog("SM key fetch: GET \(urlStr)", tag: "AUTH")
        guard let url = URL(string: urlStr) else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        req.setValue(DeviceIdentity.current, forHTTPHeaderField: "X-Device-Id")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let statusCode = (resp as? HTTPURLResponse)?.statusCode ?? 0
            dlog("SM key fetch: HTTP \(statusCode)", tag: "AUTH")
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let key = obj["key"] as? String, !key.isEmpty {
                self.speechmaticsKey = key
                dlog("SM key fetch: SUCCESS — key length=\(key.count)", tag: "AUTH")
                return true
            }
            let raw = String(data: data, encoding: .utf8) ?? "(empty)"
            dlog("SM key fetch: no key in response — \(raw)", tag: "AUTH")
        } catch {
            dlog("SM key fetch error: \(error.localizedDescription)", tag: "AUTH")
        }
        return false
    }
}

// MARK: - App Config
enum AppConfig {
    static let backendUrl         = "https://coopilotxai.com"   // Oracle Cloud — the only backend
    static let firebaseApiKey     = "AIzaSyAGGmuFpR0qkCHLI3q2cPv_o3cQlbIU8lE"
    static let googleClientId     = "745433477203-lvqmnnip9pb241vkfp628qmue8313cre.apps.googleusercontent.com"
    // Baked into Info.plist at build time from the GOOGLE_CLIENT_SECRET GitHub Actions
    // secret (see .github/workflows/build-mac-dmg.yml). Empty in local dev or when the
    // secret isn't configured → "Continue with Google" stays disabled and email/password
    // sign-in is completely unaffected. fetchRemoteConfig() can also fill this if a
    // backend ever serves it.
    static var googleClientSecret = (Bundle.main.infoDictionary?["GoogleClientSecret"] as? String) ?? ""

    // Fetches GoogleClientSecret (and optionally other keys) from the original backend.
    // Must be called once before Google sign-in.
    static func fetchRemoteConfig() async {
        // Optional config (e.g. GoogleClientSecret) from the Oracle backend. Until that
        // endpoint exists it 404s harmlessly and Google sign-in stays disabled — email/
        // password sign-in is completely independent of this.
        guard let url = URL(string: "\(backendUrl)/api/config/keys") else { return }
        var configReq = URLRequest(url: url)
        configReq.timeoutInterval = 8
        guard let (data, _) = try? await URLSession.shared.data(for: configReq) else {
            dlog("AppConfig: remote config fetch failed (network)", tag: "CONFIG")
            return
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            dlog("AppConfig: remote config bad JSON", tag: "CONFIG")
            return
        }
        if let secret = obj["GoogleClientSecret"] as? String, !secret.isEmpty {
            await MainActor.run { googleClientSecret = secret }
            dlog("AppConfig: got GoogleClientSecret (len=\(secret.count))", tag: "CONFIG")
        } else {
            dlog("AppConfig: GoogleClientSecret not in response — keys: \(obj.keys.joined(separator: ","))", tag: "CONFIG")
        }
        if let smKey = obj["SpeechmaticsKey"] as? String, !smKey.isEmpty {
            // BUG-15 FIX: only write the remote config key when the session hasn't already
            // fetched a user-specific key — prevents overwriting a valid per-user key with
            // a global fallback, which would trigger handleAuthError() mid-interview.
            await MainActor.run {
                if UserSession.shared.speechmaticsKey.isEmpty {
                    UserSession.shared.speechmaticsKey = smKey
                    dlog("AppConfig: got SpeechmaticsKey from remote config", tag: "CONFIG")
                } else {
                    dlog("AppConfig: remote SpeechmaticsKey ignored — user key already set", tag: "CONFIG")
                }
            }
        }
    }
}
