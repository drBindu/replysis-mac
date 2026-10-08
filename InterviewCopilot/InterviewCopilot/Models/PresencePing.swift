import Foundation

/// The once-a-minute "this app is open" ping to OUR server (Windows 1.0.31 item 29).
///
/// `POST /api/v1/presence` with the Firebase ID token as a Bearer, no body, answered `204`. The two labels of item 28
/// (X-App-Platform: mac, X-App-Version) are added by AppIdentity when the request is sent. The server writes `lastAppAt`
/// and the admin panel shows the Mac only while that is under 2.5 minutes old, so a closed or crashed app drops off by
/// itself with no "I am leaving" message. It touches no credits and nothing is decided from it.
///
/// Never for a signed-out person (the server answers 401), and never shown as an error: a failure just means the next
/// ping, a minute later, tries again.
nonisolated enum PresencePing {
    static let path = "/api/v1/presence"
    static let everySeconds: TimeInterval = 60

    /// The request, or nil when there is no token to send (a signed-out person sends nothing).
    static func request(backendUrl: String, token: String) -> URLRequest? {
        guard !token.isEmpty else { return nil }
        let base = backendUrl.hasSuffix("/") ? String(backendUrl.dropLast()) : backendUrl
        guard let url = URL(string: base + path) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
}
