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
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
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

    private let sessionFile: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("InterviewCopilot")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("session.json")
    }()

    private var tokenSavedAt: Date = .distantPast
    private let tokenValidMinutes: Double = 55

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

    func saveToDisK() {
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
        dlog("Session: loaded from disk — email=\(email), loggedIn=\(isLoggedIn), age=\(Int(ageMinutes))min", tag: "AUTH")
        return isLoggedIn
    }

    func clear() {
        isLoggedIn = false
        email = ""; name = ""; idToken = ""; refreshToken = ""
        userId = ""; credits = 0; plan = "free"; isUnlimited = false
        speechmaticsKey = ""
        Keychain.delete(account: "session")
        try? FileManager.default.removeItem(at: sessionFile)
    }

    // MARK: - Token Refresh

    func tryRefreshAsync() async -> Bool {
        guard !refreshToken.isEmpty else { return false }
        let rt = refreshToken

        guard let url = URL(string: "https://securetoken.googleapis.com/v1/token?key=\(AppConfig.firebaseApiKey)") else {
            return false
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
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
            self.saveToDisK()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Speechmatics Key

    func fetchSpeechmaticsKeyAsync() async -> Bool {
        // Use hardcoded key immediately — no network call needed
        if !AppConfig.speechmaticsApiKey.isEmpty {
            self.speechmaticsKey = AppConfig.speechmaticsApiKey
            dlog("SM key: using built-in key", tag: "AUTH")
            return true
        }
        guard !idToken.isEmpty else {
            dlog("SM key fetch: no idToken — not logged in", tag: "AUTH")
            return false
        }
        let urlStr = "\(AppConfig.backendUrl)/api/v1/stt/key"
        dlog("SM key fetch: GET \(urlStr)", tag: "AUTH")
        guard let url = URL(string: urlStr) else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
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
    static let backendUrl         = "https://coopilotxai.com"
    static let dotnetBackendUrl   = "https://ai-powered-developer-assistance-platform.onrender.com"
    static let firebaseApiKey     = "AIzaSyAGGmuFpR0qkCHLI3q2cPv_o3cQlbIU8lE"
    static let googleClientId     = "745433477203-lvqmnnip9pb241vkfp628qmue8313cre.apps.googleusercontent.com"
    static var googleClientSecret  = ""   // fetched from backend via fetchRemoteConfig()
    static let speechmaticsApiKey  = ""   // fetched from backend

    // Fetches GoogleClientSecret (and optionally other keys) from the original backend.
    // Must be called once before Google sign-in.
    static func fetchRemoteConfig() async {
        guard let url = URL(string: "\(dotnetBackendUrl)/api/config/keys") else { return }
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
            googleClientSecret = secret
            dlog("AppConfig: got GoogleClientSecret (len=\(secret.count))", tag: "CONFIG")
        } else {
            dlog("AppConfig: GoogleClientSecret not in response — keys: \(obj.keys.joined(separator: ","))", tag: "CONFIG")
        }
        if let smKey = obj["SpeechmaticsKey"] as? String, !smKey.isEmpty {
            await MainActor.run { UserSession.shared.speechmaticsKey = smKey }
            dlog("AppConfig: got SpeechmaticsKey from remote config", tag: "CONFIG")
        }
    }
}
