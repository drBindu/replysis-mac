import Foundation

// ══════════════════════════════════════════════════════════════════════════
// Reports the signed-in user's presence, so the admin dashboard shows them as "Live"
// with an accurate last-seen. Ported from Windows PresenceTracker.cs, which had it from
// the start: without this, every Mac user looked permanently offline to the dashboard.
//
// Writes lastActive every 60s (plus lastLogin on the first beat) to the users/{uid}
// document through the Firestore REST API, with the current Firebase ID token. Both
// fields are whitelisted by the Firestore security rules, and currentDocument.exists
// means this can only ever update a user document that already exists — it never
// creates one.
//
// Fire and forget: never blocks anything, never surfaces an error to the user. A missed
// beat only means the dashboard is a minute stale.
// ══════════════════════════════════════════════════════════════════════════
@MainActor
final class PresenceTracker {
    static let shared = PresenceTracker()

    private static let projectId = "copilotx-ai"
    private var timer: Timer?
    private var firstBeatSent = false
    private var beating = false
    /// Whether the first "this app is open" ping of this run has gone out.
    private var pingSent = false
    /// Whether an interview session is running. Rides on every ping as ?listening=1.
    private var listening = false

    func start() {
        guard timer == nil else { return }
        firstBeatSent = false
        timer = Timer.scheduledTimer(withTimeInterval: DeveloperOverrides.presenceSeconds ?? PresencePing.everySeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.beat() }
        }
        Task { @MainActor [weak self] in await self?.beat() }
        // The sign-in is usually not restored yet at the instant the app starts, so that first beat finds nobody signed in and the
        // next one is a minute away: an app opened for under a minute never showed as open. Try again at the pace of a person
        // starting the app until the first ping has really gone out.
        for delay in [2.0, 4.0, 8.0, 15.0, 30.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.timer != nil, !self.pingSent else { return }
                    await self.beat()
                }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        firstBeatSent = false
        pingSent = false
    }

    /// `POST /api/v1/presence`, answered 204. The platform and version labels are added on the way out (AppIdentity).
    private func pingServer(token: String) {
        guard let request = PresencePing.request(backendUrl: AppConfig.backendUrl, token: token, listening: listening) else { return }
        Task { @MainActor in
            do {
                let (_, response) = try await URLSession.shared.data(for: AppIdentity.label(request))
                if let http = response as? HTTPURLResponse { dlog("Presence: server ping answered \(http.statusCode)\(request.url?.query == nil ? "" : " (listening)")", tag: "PRESENCE") }
                else { dlog("Presence: server ping got no HTTP answer", tag: "PRESENCE") }
                if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                    // A stale token: refresh so the next ping lands, rather than going quiet.
                    _ = await UserSession.shared.tryRefreshAsync()
                }
            } catch {
                // A dropped ping is not worth a word to anyone; the next one is a minute away. (Said in the log only.)
                dlog("Presence: server ping failed: \(error.localizedDescription)", tag: "PRESENCE")
            }
        }
    }

    /// A session started or stopped: say so now, not at the next minute. Called every tick with the current state; acts only on a change.
    func setListening(_ running: Bool) {
        guard running != listening else { return }
        listening = running
        guard timer != nil else { return }                        // not started yet: the first ping carries the flag
        let session = UserSession.shared
        guard session.isLoggedIn, !session.userId.isEmpty, !session.idToken.isEmpty else { return }
        pingServer(token: session.idToken)
    }

    /// The app is quitting: tell the server so the panel drops the Mac at once. Waits for the answer for at most
    /// PresencePing.leaveWaitSeconds and never longer, so a bad connection cannot hold the quit. Nothing is shown if it fails.
    func leave() {
        let session = UserSession.shared
        guard session.isLoggedIn, !session.userId.isEmpty, !session.idToken.isEmpty,
              let request = PresencePing.leaveRequest(backendUrl: AppConfig.backendUrl, token: session.idToken) else { return }
        let done = DispatchSemaphore(value: 0)
        let started = Date()
        URLSession.shared.dataTask(with: AppIdentity.label(request)) { _, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            dlog("Presence: leave message answered \(status) in \(Int(Date().timeIntervalSince(started) * 1000)) ms", tag: "PRESENCE")
            done.signal()
        }.resume()
        if done.wait(timeout: .now() + PresencePing.leaveWaitSeconds) == .timedOut {
            dlog("Presence: leave message not answered in \(PresencePing.leaveWaitSeconds) s; quitting anyway", tag: "PRESENCE")
        }
    }

    private func beat() async {
        guard !beating else { return }
        beating = true
        defer { beating = false }

        let session = UserSession.shared
        guard session.isLoggedIn, !session.userId.isEmpty else { return }

        // Firebase ID tokens last an hour; refresh before writing rather than after a 401.
        if session.idToken.isEmpty { _ = await session.tryRefreshAsync() }
        let token = session.idToken
        guard !token.isEmpty else { return }

        // Tell OUR server this app is open (Windows 1.0.31 item 29), next to the write below and independent of it: a failed
        // Firestore write must not stop this, nor this the write. Fire and forget; nothing is shown if it fails.
        pingSent = true
        pingServer(token: token)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let nowIso = formatter.string(from: Date())

        let includeLogin = !firstBeatSent
        var fields = "\"lastActive\":{\"timestampValue\":\"\(nowIso)\"}"
        var mask = "updateMask.fieldPaths=lastActive"
        if includeLogin {
            fields += ",\"lastLogin\":{\"timestampValue\":\"\(nowIso)\"}"
            mask += "&updateMask.fieldPaths=lastLogin"
        }

        let urlString = "https://firestore.googleapis.com/v1/projects/\(Self.projectId)"
            + "/databases/(default)/documents/users/\(session.userId)"
            + "?currentDocument.exists=true&\(mask)"
        guard let url = URL(string: urlString) else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = Data(("{\"fields\":{" + fields + "}}").utf8)

        do {
            let (_, response) = try await URLSession.shared.data(for: AppIdentity.label(req))
            guard let http = response as? HTTPURLResponse else { return }
            if (200...299).contains(http.statusCode) {
                if includeLogin { dlog("Presence: first beat sent (lastLogin + lastActive)", tag: "PRESENCE") }
                firstBeatSent = true
            } else if http.statusCode == 401 {
                // A stale token is the one failure worth acting on: refresh so the next
                // beat lands, rather than going quiet for the rest of the session.
                _ = await session.tryRefreshAsync()
            }
        } catch {
            // A dropped beat is not worth a word to anyone.
        }
    }
}
