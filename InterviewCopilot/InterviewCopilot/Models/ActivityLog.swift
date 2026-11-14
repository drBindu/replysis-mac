import Foundation
import CoreAudio

// ══════════════════════════════════════════════════════════════════════════
// The activity diary (CHANNEL 2026-11-14, "activity diary"): a short record of what the app did, so the admin Activity view can
// show Mac and Windows in one place. One event is {t, uid, session_id, app, v, event, props}. Events are kept in a file in the
// app's data folder (0600, at most 5,000, the oldest dropped) and posted in batches of at most 200 to POST /api/v1/activity every
// 10 s and at quit (1.5 s at most).
//
// SENDING IS OFF for real users (`sendingEnabled`) until the owner approves the Trust Center wording; the diary is still written
// to disk. A DEBUG build against the fake server of a test run sends, so the scenario test can see it.
//
// PRIVACY, a hard rule: nothing anyone said, no answer or question text, nothing from the screen, no resume or job text, no
// keystrokes, no file names, no other apps' window titles, no emails. Props are fixed names, numbers, booleans and short fixed
// values only: `cleanProps` drops any string with a space in it, any long string and any prop whose name looks like text.
// run-regressions.sh also scans every ActivityLog.record( call site for text variables.
//
// This is the pure half, compiled alone by the regression suite. The recording, the disk queue and the sending are in
// ActivityLogSend.swift.
// ══════════════════════════════════════════════════════════════════════════
nonisolated enum ActivityLog {
    static let path = "/api/v1/activity"
    static let everySeconds: TimeInterval = 10
    static let maxPerRequest = 200
    static let maxQueued = 5_000
    static let quitWaitSeconds: TimeInterval = 1.5
    static let fileName = "activity_queue.json"
    static let app = "mac"
    /// After a 404 the endpoint is not there yet: sending pauses this long, then tries again.
    static let missingPauseSeconds: TimeInterval = 15 * 60
    /// The internal order number each queued event carries on disk. Never sent.
    static let seqKey = "_n"

    /// ON (owner approved 2026-11-14, Trust Center updated; endpoint live, Windows f000fbe). Only to see and fix the problems
    /// users meet: never what anyone says, answers, screens, resumes, passwords or keystrokes (see forbiddenNameParts).
    nonisolated(unsafe) static var sendingEnabled = true

    // ── What may be in props ─────────────────────────────────────────────────────────────────
    /// A prop name containing any of these is dropped, whatever its value.
    static let forbiddenNameParts = ["transcript", "text", "resume", "email", "title", "question", "file", "path", "keystroke",
                                     "url", "token", "said", "prompt", "content", "job", "body", "message"]
    static let maxStringLength = 40

    static func isEventName(_ name: String) -> Bool {
        name.range(of: "^[a-z][a-z0-9_]{0,47}$", options: .regularExpression) != nil
    }
    static func isPropName(_ name: String) -> Bool {
        guard name.range(of: "^[a-z][a-z0-9_]{0,31}$", options: .regularExpression) != nil else { return false }
        return !forbiddenNameParts.contains(where: { name.contains($0) })
    }
    /// A short fixed value: letters, digits and . , : _ - only, no spaces, at most 40 characters ("auto", "en", "Mac14,2", "1.0.255").
    static func isFixedValue(_ value: String) -> Bool {
        value.count <= maxStringLength && value.range(of: "^[A-Za-z0-9_.,:\\-]*$", options: .regularExpression) != nil
    }

    /// Only fixed names, numbers, booleans and short fixed values survive.
    static func cleanProps(_ props: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (name, value) in props where isPropName(name) {
            switch value {
            case let b as Bool: out[name] = b
            case let i as Int: out[name] = i
            case let i as Int64: out[name] = i
            case let d as Double where d.isFinite: out[name] = (d * 1000).rounded() / 1000
            case let s as String where isFixedValue(s): out[name] = s
            default: continue
            }
        }
        return out
    }

    /// One event as it is queued, or nil for a name that is not a fixed event name.
    static func makeEvent(name: String, props: [String: Any], t: Int64, uid: String, sessionId: String, version: String) -> [String: Any]? {
        guard isEventName(name) else { return nil }
        return ["t": t, "uid": uid, "session_id": sessionId, "app": app, "v": version, "event": name, "props": cleanProps(props)]
    }

    /// The queue with the oldest dropped past `max`.
    static func trimmed(_ queue: [[String: Any]], max: Int = maxQueued) -> [[String: Any]] {
        queue.count > max ? Array(queue.suffix(max)) : queue
    }

    /// The next batch: at most 200 events, the internal order number taken off.
    static func batch(_ queue: [[String: Any]]) -> [[String: Any]] {
        queue.prefix(maxPerRequest).map { e in var e = e; e.removeValue(forKey: seqKey); return e }
    }

    /// The order number of the last event in the next batch, so exactly those are removed once sent.
    static func lastSeq(ofBatchIn queue: [[String: Any]]) -> Int? {
        guard !queue.isEmpty else { return nil }
        return queue.prefix(maxPerRequest).last?[seqKey] as? Int
    }

    /// The queue with every event up to and including `seq` removed.
    static func removingSent(_ queue: [[String: Any]], upTo seq: Int) -> [[String: Any]] {
        queue.filter { (($0[seqKey] as? Int) ?? Int.max) > seq }
    }

    /// POST /api/v1/activity with {"events":[...]} and the Bearer token. The platform and version labels are added on the way out
    /// (AppIdentity.label), as for presence. Nil with no token or no events.
    static func request(backendUrl: String, token: String, events: [[String: Any]]) -> URLRequest? {
        guard !token.isEmpty, !events.isEmpty, events.count <= maxPerRequest else { return nil }
        let base = backendUrl.hasSuffix("/") ? String(backendUrl.dropLast()) : backendUrl
        guard let url = URL(string: base + path),
              let body = try? JSONSerialization.data(withJSONObject: ["events": events]) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    enum Outcome: Equatable { case sent, refreshAndRetry, endpointMissing, keep }

    /// What an answer means. 200/204 sent; 401 refresh the token and try once more; 404 the endpoint is not there yet (sending
    /// pauses); anything else, or no answer at all (nil), keeps the batch on disk for the next tick.
    static func outcome(status: Int?) -> Outcome {
        switch status {
        case 200, 204: return .sent
        case 401: return .refreshAndRetry
        case 404: return .endpointMissing
        default: return .keep
        }
    }

    /// Whether a batch may go out now.
    static func maySend(enabled: Bool, testServer: Bool, pausedUntil: Date?, now: Date) -> Bool {
        guard enabled || testServer else { return false }
        if let pausedUntil, now < pausedUntil { return false }
        return true
    }

    // ── Fixed values ─────────────────────────────────────────────────────────────────────────
    /// The kind of output the computer's sound now plays on, from the device's transport type (kAudioDevicePropertyTransportType)
    /// and, for the built-in device, its data source (headphones in the jack read 'hdpn').
    static func outputType(transport: UInt32, dataSource: UInt32? = nil) -> String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            return dataSource == 0x6864_706E ? "headphones" : "speakers"     // 'hdpn'
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "bluetooth"
        case kAudioDeviceTransportTypeUSB: return "headphones"
        default: return "other"
        }
    }

    /// Words in a piece of text, counted on this Mac. Only the number is recorded.
    static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// The fixed-choice settings that changed between two snapshots, as (name, value), sorted by name.
    static func changedSettings(old: [String: String], new: [String: String]) -> [(name: String, value: String)] {
        new.keys.sorted().compactMap { k in
            guard let v = new[k], old[k] != v, isPropName(k), isFixedValue(v) else { return nil }
            return (k, v)
        }
    }
}
