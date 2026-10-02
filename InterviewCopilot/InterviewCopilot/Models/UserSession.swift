import Foundation
import Security

// MARK: - Keychain (secure storage for auth tokens — replaces plaintext session.json)
private enum Keychain {
    private static let service = "com.coopilotx.InterviewCopilot.session"

    /// What a refused delete leaves behind: one byte meaning "nothing here". An item this
    /// build may not delete can still be overwritten, and overwriting with an EMPTY value
    /// is silently ignored by the Keychain (measured), so the placeholder carries a byte.
    private static let tombstone = Data([0])

    /// Returns the Keychain status. It used to return nothing: both the delete and the add
    /// ignored their results, so a write macOS refused looked exactly like one that worked.
    /// Measured 2026-09-18: the speech-key item had not changed since the previous evening
    /// while the log said "cached — reusable for 60 minutes" after every fetch, so every
    /// launch read a day-old key, called it expired and spent a fresh one.
    @discardableResult
    static func save(_ data: Data, account: String) -> OSStatus {
        if DeveloperOverrides.active { return errSecSuccess }   // a test run never writes the real Keychain
        let base: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // Update in place first: it leaves no gap in which the item does not exist, and it
        // does not depend on being allowed to delete an item this build may not own.
        let updated = SecItemUpdate(base as CFDictionary,
                                    [kSecValueData as String: data] as CFDictionary)
        if updated != errSecItemNotFound { return updated }
        var add = base
        add[kSecValueData as String]      = data
        // ...ThisDeviceOnly: the auth token never leaves this Mac — it's excluded from
        // iCloud Keychain sync and from encrypted backups that could be restored onto a
        // different machine. For a login credential that's the correct, device-bound
        // choice; the app only ever reads it locally, so behavior is unchanged. Still
        // AfterFirstUnlock (not WhenUnlocked) so session restore works right after a
        // reboot even before the user re-unlocks.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil)
    }

    static func load(account: String) -> Data? {
        if DeveloperOverrides.active { return nil }             // ...and never reads it
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, !data.isEmpty, data != tombstone else { return nil }
        return data
    }

    /// Delete, and if macOS refuses, empty the item so it can never be read back.
    ///
    /// Measured 2026-09-18 on this Mac: SecItemDelete was refused for the speech-key item
    /// while SecItemUpdate on the same item succeeded. The result was ignored, so a "discarded"
    /// key was still there on the next lookup: a forced renewal reused the key it was meant
    /// to replace, and a key the service had REJECTED would have been presented again. Sign-
    /// out goes through here too, and a refused delete there would have left the login behind.
    @discardableResult
    static func delete(account: String) -> OSStatus {
        if DeveloperOverrides.active { return errSecSuccess }   // ...and never deletes from it
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status != errSecSuccess, status != errSecItemNotFound else { return status }
        // OVERWRITE WITH ONE BYTE, NOT WITH NOTHING. Measured on this Mac, 2026-09-21, by
        // signing out for real: SecItemDelete was refused (-25244, the item having been
        // created by a differently-signed build of this app), and the fallback that wrote
        // Data() returned errSecSuccess while the item still read back all 1,552 bytes of
        // the session — an empty write is accepted and ignored. The login survived a
        // sign-out and nothing said so. One byte is accepted AND replaces the data, and
        // load() treats it as absent, so the token is genuinely gone. Verified after the
        // change: session item unreadable, speech key unreadable, session file gone.
        let overwritten = SecItemUpdate(query as CFDictionary,
                                        [kSecValueData as String: tombstone] as CFDictionary)
        dlog("Keychain: delete of '\(account)' refused (status \(status)); overwrote it instead (status \(overwritten))", tag: "AUTH")
        return overwritten
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
    /// False until a balance has actually been fetched. `credits` starts at 0, and a count that
    /// was never fetched must not be read as a count of zero. See PlanFacts.mayAsk.
    var creditsKnown = false
    var plan = "free"
    var isUnlimited = false
    var speechmaticsKey = ""
    /// Deepgram's short-lived token, minted by /stt/key alongside the Speechmatics one when the
    /// server has Deepgram enabled. Empty means the engine runs Speechmatics exactly as before.
    /// Lives and dies with speechmaticsKey: cached with it, cleared everywhere it is cleared,
    /// because a token that outlives its sibling is how a correct server-side change ends up
    /// looking like it did nothing.
    var deepgramToken = ""

    // True for the free-trial-without-sign-in path (see startGuestSession()) — isLoggedIn
    // is also true in this state so every existing `session.isLoggedIn` gate throughout
    // MainViewModel (Space handling, engine start, ask/analyze credit checks) works for
    // guests with zero changes to those call sites. This flag exists only so the UI can
    // show honest "free trial" messaging and so a real sign-in is never confused with it.
    var isGuestSession = false

    /// Is this account already on a paid tier?
    ///
    /// NOT the same question as isUnlimited. Max is a paid plan that still meters credits,
    /// so isUnlimited is false on it — and the profile menu used that to decide whether to
    /// offer an upgrade, which showed "Upgrade to Pro · Unlimited answers" to somebody on
    /// the TOP plan. That is an offer to move down a tier, and it reads as the app not
    /// knowing what they bought.
    ///
    /// Matched on substrings because the server returns the plan as free text ("max",
    /// "Max plan", "teams"), and a plan nobody anticipated should not produce an upsell.
    var isPaidPlan: Bool {
        if isUnlimited { return true }
        let p = plan.lowercased()
        return ["pro", "max", "lifetime", "team", "enterprise", "unlimited"]
            .contains { p.contains($0) }
    }

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
        if let mode = DeveloperOverrides.testSession {
            // DEBUG + loopback only. A fake signed-in person, in memory, so the real app can be
            // run against a fake server. "stale" believes its token is fine and the server
            // does not; "expired" knows it is old and must refresh first.
            let who = DeveloperOverrides.testUser ?? "scenario"
            email = "\(who)@example.test"; name = who.capitalized; userId = "\(who)-user"
            idToken = "stale-token"; refreshToken = "refresh-1"
            tokenSavedAt = mode == "expired" ? Date(timeIntervalSinceNow: -3 * 3600) : Date()
            isLoggedIn = true
            dlog("Session: TEST session (\(mode)) against the fake server", tag: "AUTH")
            return true
        }
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
        userId = ""; credits = 0; creditsKnown = false; plan = "free"; isUnlimited = false
        speechmaticsKey = ""
        deepgramToken = ""
        Keychain.delete(account: "session")
        Keychain.delete(account: Self.speechKeyAccount)   // never outlive the session it belongs to
        // The debug log holds what was said in this account's interviews. Signing out must
        // not leave it on the machine for whoever signs in next.
        DebugLog.shared.purge()
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
                  let url = URL(string: DeveloperOverrides.tokenURL
                                ?? "https://securetoken.googleapis.com/v1/token?key=\(AppConfig.firebaseApiKey)")
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
        creditsKnown = true
        plan = result.plan
        isUnlimited = result.isUnlimited
        name = "Guest"
        email = ""
        dlog("Guest session started — credits=\(result.credits)", tag: "AUTH")
        return true
    }

    // MARK: - Speechmatics Key
    //
    // The token is good for about an hour and was kept in memory only, so every launch
    // spent a fresh one against a twelve-per-hour allowance. A dozen restarts locked the
    // account out — and the allowance is per ACCOUNT, not per app, so it took the Windows
    // app down at the same time. Persist it and reuse it until it genuinely expires.

    private static let speechKeyAccount = "speechmaticsKey"
    /// Renew this long before the real expiry, so a token cannot die mid-question.
    private static let speechKeyRenewMargin: TimeInterval = 300

    private struct CachedSpeechKey: Codable {
        let key: String
        let expiresAt: Date
        /// Which account minted it. Handing one user's token to another is both a leak and
        /// a miserable thing to debug, and switching accounts is exactly when it would happen.
        let owner: String
        /// nil  = written by a build that predated Deepgram: stale, refetch once.
        /// ""   = the server was asked and had no Deepgram token: valid, do NOT refetch.
        /// The distinction matters because a pre-Deepgram entry stays valid for up to an hour,
        /// so an upgrade would otherwise run Speechmatics-only for that hour with nothing to
        /// say why — while refetching on every empty value would spend the twelve-per-hour
        /// mint allowance on a server that simply has Deepgram switched off.
        let deepgramToken: String?
    }

    /// When the speech token in use stops working, or nil when there is no cached token for
    /// this account. Read by the in-session renewal: the engine is handed its token once, at
    /// launch, and holds it for the life of the process, so a long interview outlives it.
    ///
    /// Held in memory, set whenever a key is taken into use. It was read back from the
    /// Keychain, and when a write there failed silently it returned the previous day's key:
    /// the renewal saw "expires in 0 min" twenty-eight seconds after a fresh hour-long key
    /// was fetched, and would have renewed every five minutes — twelve mints an hour, the
    /// whole allowance. What the engine is actually using is what this must describe.
    var speechKeyExpiresAt: Date? { speechKeyExpiry }

    // ── Why the speech key could not be had ───────────────────────────────────────────
    //
    // Until 2026-09-30 a failed key request left nothing behind but "false", so the app
    // could only show a bare NO MIC and had no way to say WHY. A Free tester on Windows with
    // no listening time spoke to a silent app for minutes and decided her laptop was broken.
    // These are what ListeningProblems reads to say it in words.
    private(set) var speechKeyLastStatus = 0
    /// A 402 because the fair use guard on listening was reached (credits are fine).
    private(set) var speechOutOfListeningTime = false
    /// A 402 because the answers are used up.
    private(set) var speechOutOfAnswers = false
    /// Earliest time the AUTOMATIC paths may ask again. A definite refusal is remembered.
    private(set) var speechRetryAfter = Date.distantPast
    private var keyNoConnectionFailures = 0

    /// How long a definite refusal (402) is remembered. Windows measured why: the server
    /// allows a signed-in account 12 key requests an hour, and retrying every 30 seconds
    /// used them all in six minutes, after which every reply was a rate limit that hid the
    /// real reason from the person. The badge and the mic ask again on demand.
    static let refusalMemory: TimeInterval = 300

    /// Someone who just upgraded must not be stuck behind a remembered refusal.
    func forgetRefusal() {
        speechRetryAfter = .distantPast
        speechOutOfAnswers = false; speechOutOfListeningTime = false; speechKeyLastStatus = 0
    }
    private var speechKeyExpiry: Date?

    private var speechKeyOwner: String {
        isGuestSession ? "guest:\(DeviceIdentity.current)" : (userId.isEmpty ? email : userId)
    }

    private func loadCachedSpeechKey() -> String? {
        guard let data = Keychain.load(account: Self.speechKeyAccount),
              let cached = try? JSONDecoder().decode(CachedSpeechKey.self, from: data) else { return nil }
        guard discardedSpeechKey.isEmpty || cached.key != discardedSpeechKey else {
            dlog("SM key cache: still holds the key just thrown away — fetching a fresh one", tag: "AUTH")
            return nil
        }
        guard cached.owner == speechKeyOwner else {
            dlog("SM key cache: minted for a different account — discarding", tag: "AUTH")
            discardCachedSpeechKey(); return nil
        }
        guard cached.expiresAt.timeIntervalSinceNow > Self.speechKeyRenewMargin else {
            dlog("SM key cache: expired, or close enough — fetching a fresh one", tag: "AUTH")
            discardCachedSpeechKey(); return nil
        }
        guard let dgCached = cached.deepgramToken else {
            dlog("SM key cache: written before Deepgram support — fetching a fresh pair once", tag: "AUTH")
            discardCachedSpeechKey(); return nil
        }
        deepgramToken = dgCached
        speechKeyExpiry = cached.expiresAt
        return cached.key
    }

    /// Report the plan limits the token itself carries.
    ///
    /// The account's ceiling was found this way and not from the portal — the server key
    /// belonged to an account nobody here could sign into, so the token was the only source
    /// of truth available. It costs nothing to read, needs no dependency, and answers the
    /// question that otherwise gets answered by a customer discovering it mid-interview.
    /// Ported from Windows (e21902b).
    private func logSpeechKeyLimits(_ token: String) {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+")
                                  .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }        // JWT strips base64 padding
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let type = obj["account_type"] as? String ?? "?"
        // Accept whatever shape the claim arrives in. The first version read it as Int only
        // and logged "connection_quota=?" against a token that carries it — so the warning
        // at two or below could never fire, and the instrumentation added to answer this
        // exact question quietly answered nothing. JSON numbers decode as NSNumber, String
        // or Double depending on how the minting service wrote them.
        let raw = obj["connection_quota"] ?? obj["connectionQuota"] ?? obj["concurrency"]
        let quota = (raw as? Int)
            ?? (raw as? NSNumber)?.intValue
            ?? (raw as? Double).map(Int.init)
            ?? (raw as? String).flatMap(Int.init)
        if quota == nil {
            // Names only, never values — enough to find the right claim next time without
            // putting any of the token in the log.
            dlog("SM plan: no recognised quota claim. Claims present: \(obj.keys.sorted().joined(separator: ", "))",
                 tag: "AUTH")
        }
        dlog("SM plan: account_type=\(type) connection_quota=\(quota.map(String.init) ?? "?")",
             tag: "AUTH")
        if let q = quota, q <= 2 {
            dlog("SM plan: WARNING — only \(q) simultaneous session\(q == 1 ? "" : "s") allowed "
                 + "on this account. A second person transcribing at the same moment gets "
                 + "silence, and one leaked session is half the capacity.", tag: "AUTH")
        }
    }

    private func cacheSpeechKey(_ key: String, ttl: TimeInterval) {
        let cached = CachedSpeechKey(key: key,
                                     expiresAt: Date().addingTimeInterval(ttl),
                                     owner: speechKeyOwner,
                                     deepgramToken: deepgramToken)
        speechKeyExpiry = cached.expiresAt
        guard let data = try? JSONEncoder().encode(cached) else { return }
        let status = Keychain.save(data, account: Self.speechKeyAccount)
        if status == errSecSuccess {
            dlog("SM key cached — reusable for \(Int(ttl / 60)) minutes", tag: "AUTH")
        } else {
            dlog("SM key NOT cached — the Keychain refused the write (status \(status)); this session is fine, the next launch will fetch again", tag: "AUTH")
        }
    }

    /// Throw the cached token away.
    ///
    /// MUST be called the moment a token is rejected. Otherwise one minted by a dead or
    /// blocked account survives on disk for its full hour, the app keeps presenting it, and
    /// nothing on screen explains why transcription stopped.
    /// The key most recently thrown away. Checked on every cache lookup, because the Keychain
    /// cannot be relied on to forget it: measured 2026-09-18, a lookup three seconds after the
    /// discard still returned the key the service had just rejected, and the recovery started
    /// the engine with it again. Held in memory for the life of the process — it is only ever
    /// compared, never presented.
    private var discardedSpeechKey = ""

    func discardCachedSpeechKey() {
        if !speechmaticsKey.isEmpty { discardedSpeechKey = speechmaticsKey }
        speechKeyExpiry = nil
        speechmaticsKey = ""
        deepgramToken = ""
        Keychain.delete(account: Self.speechKeyAccount)
    }

    /// - Parameter forceRefresh: skip the cache and mint a new token. Only for a deliberate
    ///   user retry, never for the automatic paths — that is what spends the allowance.
    /// - Parameter userInitiated: the person asked (clicked the mic or the answers badge), so
    ///   a remembered refusal does not apply. Automatic paths wait it out.
    func fetchSpeechmaticsKeyAsync(forceRefresh: Bool = false, userInitiated: Bool = false) async -> Bool {
        guard !idToken.isEmpty || isGuestSession else {
            dlog("SM key fetch: no idToken and not a guest session — not logged in", tag: "AUTH")
            return false
        }
        if userInitiated { forgetRefusal() }
        if !userInitiated, Date() < speechRetryAfter, loadCachedSpeechKey() == nil {
            dlog("SM key fetch: holding off \(Int(speechRetryAfter.timeIntervalSinceNow))s more (last answer HTTP \(speechKeyLastStatus))", tag: "AUTH")
            return false
        }
        if forceRefresh { discardCachedSpeechKey() }
        // Never consult the cache on a forced refresh. It used to rely on the discard above
        // having worked, and when the Keychain refused it the "renewal" restarted the engine
        // with the very key it was meant to replace: "reusing the cached token" logged a
        // second after "renewing it". Measured 2026-09-18.
        if !forceRefresh, let cached = loadCachedSpeechKey() {
            speechmaticsKey = cached
            // Also on the cached path. Reporting the plan only when a token is freshly
            // minted means it is silent for the whole hour a cached one is reused — which
            // is most of a session, and exactly when someone is wondering why a second
            // device cannot connect.
            logSpeechKeyLimits(cached)
            dlog("SM key: reusing the cached token — no new one spent", tag: "AUTH")
            return true
        }
        let urlStr = "\(AppConfig.backendUrl)/api/v1/stt/key"
        dlog("SM key fetch: GET \(urlStr)", tag: "AUTH")
        guard let url = URL(string: urlStr) else { return false }
        // REFRESH THE SIGN-IN FIRST. The answer path always did; this one sent whatever was
        // stored. A laptop that slept two hours woke, asked for a speech key with a token an
        // hour past expiry, was told 401, and the 401 was read as "signed out" — the plan
        // gone and no answer, in the middle of an interview (Windows, 2026-09-29).
        if !isGuestSession, !refreshToken.isEmpty, tokenNeedsRefresh {
            _ = await tryRefreshAsync()
        }
        func makeRequest() -> URLRequest {
            var r = URLRequest(url: url)
            r.timeoutInterval = 10
            r.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
            r.setValue(DeviceIdentity.current, forHTTPHeaderField: "X-Device-Id")
            return r
        }
        do {
            var (data, resp) = try await URLSession.shared.data(for: makeRequest())
            var statusCode = (resp as? HTTPURLResponse)?.statusCode ?? 0
            // The stored timestamp is only a guess at "still valid": wrong after a long sleep,
            // a clock change, or a session revoked elsewhere. A 401 for someone signed in is
            // worth ONE forced refresh and ONE more try before it is called a sign-out.
            if statusCode == 401, !isGuestSession, !refreshToken.isEmpty, await tryRefreshAsync() {
                dlog("SM key fetch: 401 on a stale sign-in — refreshed it and asked again", tag: "AUTH")
                (data, resp) = try await URLSession.shared.data(for: makeRequest())
                statusCode = (resp as? HTTPURLResponse)?.statusCode ?? 0
            }
            keyNoConnectionFailures = 0        // an answer of any kind means the connection is back
            dlog("SM key fetch: HTTP \(statusCode)", tag: "AUTH")
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let key = obj["key"] as? String, !key.isEmpty {
                self.speechmaticsKey = key
                self.logSpeechKeyLimits(key)
                // Absent when the server has no DEEPGRAM_API_KEY, or Deepgram refused the
                // grant — in both cases the response is otherwise identical and the engine
                // runs Speechmatics. Length only, never the token.
                self.deepgramToken = (obj["deepgramToken"] as? String) ?? ""
                dlog(self.deepgramToken.isEmpty
                     ? "STT key: no Deepgram token in the response — Speechmatics only"
                     : "STT key: Deepgram token received (length \(self.deepgramToken.count))",
                     tag: "AUTH")
                // The server says how long it is good for; Windows clamps the same way.
                let ttl = TimeInterval(min(max(obj["expiresIn"] as? Int ?? 3600, 60), 86_400))
                self.cacheSpeechKey(key, ttl: ttl)
                forgetRefusal()
                dlog("SM key fetch: SUCCESS — key length=\(key.count)", tag: "AUTH")
                return true
            }
            if !(200...299).contains(statusCode) {
                speechKeyLastStatus = statusCode
                if statusCode == 402 {
                    // The server names which limit was hit; anything else is the answers.
                    let body = (String(data: data, encoding: .utf8) ?? "").lowercased()
                    let listeningLimit = body.contains("audio-limit") || body.contains("listening time")
                    speechOutOfListeningTime = listeningLimit
                    speechOutOfAnswers = !listeningLimit
                    dlog(listeningLimit ? "SM key: 402, fair use limit on listening reached" : "SM key: 402, no answers left", tag: "AUTH")
                    speechRetryAfter = Date().addingTimeInterval(Self.refusalMemory)
                } else if statusCode == 429 {
                    let hinted = TimeInterval((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
                    speechRetryAfter = Date().addingTimeInterval(min(max(hinted, 15), 300))
                } else {
                    speechRetryAfter = Date().addingTimeInterval(30)
                }
                // Status code only. The body of a refusal can carry account detail.
                dlog("SM key fetch: refused, HTTP \(statusCode)", tag: "AUTH")
            } else {
                speechRetryAfter = Date().addingTimeInterval(30)
                dlog("SM key fetch: 200 but no key in the response", tag: "AUTH")
            }
        } catch {
            // Could not even ask: no network, no DNS (a laptop waking, Wi-Fi switching). Try
            // again within seconds, not half a minute, and drop any earlier refusal from the
            // screen: it is no longer the latest thing that happened. Nothing reached the
            // server, so nothing counts against its limits.
            keyNoConnectionFailures += 1
            let wait = RecoveryPolicy.keyRetryAfterNoConnection(keyNoConnectionFailures)
            speechRetryAfter = Date().addingTimeInterval(wait)
            speechKeyLastStatus = 0
            dlog("SM key fetch: no connection (\(error.localizedDescription)) — trying again in \(Int(wait))s", tag: "AUTH")
        }
        return false
    }
}

// MARK: - App Config
enum AppConfig {
    static let backendUrl         = DeveloperOverrides.backendURL ?? "https://replysis.com"   // the only backend (coopilotxai.com retired)
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
        guard let (data, response) = try? await URLSession.shared.data(for: configReq) else {
            dlog("AppConfig: remote config fetch failed (network)", tag: "CONFIG")
            return
        }
        // The server has no such page (it answers 404 with its 18 KB "not found" web page), and every
        // launch downloaded that and logged it as "bad JSON". Nothing to read means nothing to say.
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            dlog("AppConfig: remote config was not JSON", tag: "CONFIG")
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
