import Foundation

/// The local listener Google sign-in redirects to (RFC 8252 loopback), and the rule for which request is the
/// answer.
///
/// The first connection used to be taken as the answer. A browser opens spare connections and asks for
/// /favicon.ico: a silent spare made sign-in time out and an icon request made it fail (Windows 1.0.30,
/// item 7). It now keeps listening, handles every connection on its own, and ignores anything that is not this
/// attempt's answer: no code or error in the request, or a state that is not the one this attempt sent.
enum OAuthLoopback {
    struct Callback {
        let code: String?
        let stateValid: Bool
        let error: String?
    }

    enum Classified {
        /// This attempt's answer: the code, or Google's refusal, carrying the state this attempt sent.
        case answer(Callback)
        /// Anything else a browser sends to a local port: an icon, a spare connection, another tab's answer.
        case ignore
    }

    static func classify(_ request: String, expectedState: String) -> Classified {
        guard let line = request.components(separatedBy: "\r\n").first,
              let qMark = line.range(of: "?"),
              let http = line.range(of: " HTTP"), qMark.upperBound <= http.lowerBound else { return .ignore }
        var params: [String: String] = [:]
        for pair in String(line[qMark.upperBound ..< http.lowerBound]).components(separatedBy: "&") {
            // Split on the FIRST '=' only: a value can itself contain '=' (base64).
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let key = String(pair[..<eq])
            let val = String(pair[pair.index(after: eq)...])
            params[key] = val.removingPercentEncoding ?? val
        }
        guard params["code"] != nil || params["error"] != nil else { return .ignore }
        guard (params["state"] ?? "") == expectedState else { return .ignore }
        return .answer(Callback(code: params["code"], stateValid: true,
                                error: params["error"] == nil ? nil : "Google sign-in was cancelled."))
    }

    /// A socket on 127.0.0.1 ONLY (not 0.0.0.0, which would expose the OAuth callback port to the network), on a
    /// port the system picks.
    static func bind() -> (fd: Int32, port: Int)? {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0 else { Darwin.close(sock); return nil }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(sock, $0, &len) }
        }
        // Room for the spare connections a browser opens next to the real one.
        listen(sock, 16)
        return (sock, Int(addr.sin_port.bigEndian))
    }

    private final class Result: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Callback?
        var callback: Callback? { lock.lock(); defer { lock.unlock() }; return value }
        /// The first answer wins.
        func set(_ cb: Callback) { lock.lock(); if value == nil { value = cb }; lock.unlock() }
    }

    /// Blocks until this attempt's answer arrives, or `timeout` passes. Closes the socket. Every accepted
    /// connection is read on its own thread, so a silent spare one never holds up the real one.
    static func waitForCallback(serverFd: Int32, expectedState: String, timeout: TimeInterval,
                                successHTML: String, failHTML: String, readTimeout: Int = 10) -> Callback? {
        defer { Darwin.close(serverFd) }
        let result = Result()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, result.callback == nil {
            var pfd = pollfd(fd: serverFd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 250) > 0 else { continue }
            let client = accept(serverFd, nil, nil)
            guard client >= 0 else { continue }
            DispatchQueue.global(qos: .userInitiated).async {
                defer { Darwin.close(client) }
                var tv = timeval(tv_sec: readTimeout, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                // The first line of the request is all that is needed; it can arrive in pieces.
                var data = [UInt8]()
                var buf = [UInt8](repeating: 0, count: 4096)
                while data.count < 16_384 {
                    let n = recv(client, &buf, buf.count, 0)
                    if n <= 0 { break }
                    data.append(contentsOf: buf.prefix(n))
                    if data.contains(10) { break }
                }
                guard !data.isEmpty else { return }          // a spare connection that never said anything
                let request = String(decoding: data, as: UTF8.self)
                switch classify(request, expectedState: expectedState) {
                case .ignore:
                    send(client, status: "404 Not Found", html: "")
                case .answer(let cb):
                    send(client, status: "200 OK", html: cb.code != nil ? successHTML : failHTML)
                    result.set(cb)
                }
            }
        }
        // A moment for the page that tells the person they can close the tab to be written.
        if result.callback != nil { Thread.sleep(forTimeInterval: 0.15) }
        return result.callback
    }

    private static func send(_ client: Int32, status: String, html: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        response.withCString { _ = Darwin.send(client, $0, strlen($0), 0) }
    }
}
