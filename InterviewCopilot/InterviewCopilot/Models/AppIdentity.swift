import Foundation

/// Tells our own server which app this is (Windows 1.0.31 item 28).
///
/// Two labels, `X-App-Platform: mac` and `X-App-Version: 1.0.247`, on every request whose host is OUR backend and on no
/// other: not GitHub (updates), not Google (sign-in), not anyone else. They are labels only; the server grants, charges
/// and limits nothing from them. The admin page uses them to show who has the Mac app open and which version.
nonisolated enum AppIdentity {
    static let platformHeader = "X-App-Platform"
    static let versionHeader = "X-App-Version"
    static let platform = "mac"

    /// The plain version of this build, digits and dots ("1.0.247"), or nil when the bundle has nothing usable.
    static var bundleVersion: String? {
        plainVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
    }

    /// Digits and dots only, so a label can never carry anything else to the server.
    static func plainVersion(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty,
              raw.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              !raw.hasPrefix("."), !raw.hasSuffix(".") else { return nil }
        return raw
    }

    /// Whether this URL is on our own backend's host.
    static func isOurHost(_ url: URL?, backendHost: String?) -> Bool {
        guard let host = url?.host?.lowercased(), let backendHost = backendHost?.lowercased(), !backendHost.isEmpty else { return false }
        return host == backendHost
    }

    /// The request with the two labels added when it goes to our backend, and unchanged for any other host.
    static func label(_ request: URLRequest, backendHost: String?, version: String?) -> URLRequest {
        guard isOurHost(request.url, backendHost: backendHost) else { return request }
        var labelled = request
        labelled.setValue(platform, forHTTPHeaderField: platformHeader)
        if let version = plainVersion(version) { labelled.setValue(version, forHTTPHeaderField: versionHeader) }
        return labelled
    }

    /// The host of the backend this app talks to. Set once at launch from AppConfig (a developer build can point it at a fake
    /// server); until then it is the real one, so no request can go out unlabelled by a race.
    nonisolated(unsafe) static var ourBackendHost: String? = "replysis.com"

    /// The same for this app: our backend's host is the one the app is configured to talk to.
    static func label(_ request: URLRequest) -> URLRequest {
        label(request, backendHost: ourBackendHost, version: bundleVersion)
    }
}
