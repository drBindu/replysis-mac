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

    func start() {
        guard timer == nil else { return }
        firstBeatSent = false
        timer = Timer.scheduledTimer(withTimeInterval: DeveloperOverrides.presenceSeconds ?? PresencePing.everySeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.beat() }
        }
        Task { @MainActor [weak self] in await self?.beat() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        firstBeatSent = false
    }

    /// `POST /api/v1/presence`, answered 204. The platform and version labels are added on the way out (AppIdentity).
    private func pingServer(token: String) {
        guard let request = PresencePing.request(backendUrl: AppConfig.backendUrl, token: token) else { return }
        Task { @MainActor in
            do {
                let (_, response) = try await URLSession.shared.data(for: AppIdentity.label(request))
                if let http = response as? HTTPURLResponse { dlog("Presence: server ping answered \(http.statusCode)", tag: "PRESENCE") }
                if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                    // A stale token: refresh so the next ping lands, rather than going quiet.
                    _ = await UserSession.shared.tryRefreshAsync()
                }
            } catch {
                // A dropped ping is not worth a word to anyone; the next one is a minute away.
            }
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
