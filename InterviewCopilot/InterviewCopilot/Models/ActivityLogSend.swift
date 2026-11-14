import Foundation
import CoreAudio

// The recording and sending half of ActivityLog (the pure half is ActivityLog.swift, which the regression suite compiles alone).
//
// record() may be called from any thread and only appends to memory on a private serial queue, so it never blocks the main thread
// or the answer path. Every 10 s the queue is written to the data folder (0600) and, when sending is allowed, one or more batches
// of at most 200 go out. At quit the rest is written and one batch is tried, for 1.5 s at most, side by side with the presence
// leave message.
extension ActivityLog {
    nonisolated private static let queue = DispatchQueue(label: "com.replysis.activity", qos: .utility)
    // Everything below is touched only on `queue`, except where said.
    nonisolated(unsafe) private static var pending: [[String: Any]] = []
    nonisolated(unsafe) private static var nextSeq = 1
    nonisolated(unsafe) private static var dirty = false
    nonisolated(unsafe) private static var fileURL: URL?
    nonisolated(unsafe) private static var userId = ""
    nonisolated(unsafe) private static var version = ""
    // Main thread only.
    nonisolated(unsafe) private static var testServer = false
    nonisolated(unsafe) private static var pausedUntil: Date?
    nonisolated(unsafe) private static var sending = false
    nonisolated(unsafe) private static var timer: Timer?
    nonisolated(unsafe) private static var lastSettings: [String: String]?
    /// Set when the app quits to install an update, so app_closed says why.
    nonisolated(unsafe) static var closingForUpdate = false

    /// One random id per launch, on every event.
    nonisolated static let sessionId = UUID().uuidString.lowercased()

    /// Record one event. Props are fixed names with numbers, booleans or short fixed values (see cleanProps); anything else is dropped.
    nonisolated static func record(_ event: String, _ props: [String: Any] = [:]) {
        let t = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        let clean = cleanProps(props)
        queue.async {
            guard var e = makeEvent(name: event, props: clean, t: t, uid: userId, sessionId: sessionId, version: version) else { return }
            e[seqKey] = nextSeq; nextSeq += 1
            pending = trimmed(pending + [e])
            dirty = true
        }
    }

    /// The signed-in person's id on the events from now on ("" when signed out).
    nonisolated static func setUser(_ uid: String) { queue.async { userId = uid } }

    /// Once at launch, on the main thread: load what an earlier run left, then write and send every 10 s.
    @MainActor static func start() {
        guard timer == nil else { return }
        #if DEBUG
        testServer = DeveloperOverrides.active
        #endif
        let url = SpeechmaticsEngine.shared.appDataFolder.appendingPathComponent(fileName)
        let v = AppIdentity.bundleVersion ?? ""
        let uid = UserSession.shared.isLoggedIn ? UserSession.shared.userId : ""
        queue.sync {
            fileURL = url; version = v; userId = uid
            let saved = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
            // Earlier events first, then whatever was recorded before this moment, numbered again in that order.
            var all = saved + pending
            for i in all.indices { all[i][seqKey] = i + 1 }
            nextSeq = all.count + 1
            pending = trimmed(all)
            // Version and session of the events recorded before start: this run's.
            for i in pending.indices where (pending[i]["session_id"] as? String) == sessionId { pending[i]["v"] = v }
            dirty = true
        }
        dlog("ACTIVITY: diary on, \(queue.sync { pending.count }) events queued, sending \(sendingEnabled || testServer ? "on" : "off")", tag: "ACTIVITY")
        timer = Timer.scheduledTimer(withTimeInterval: everySeconds, repeats: true) { _ in
            Task { @MainActor in await tick() }
        }
    }

    /// The fixed-choice settings as they are now. The first call only remembers them; later calls record each one that changed.
    @MainActor static func noteSettings(_ now: [String: String]) {
        defer { lastSettings = now }
        guard let old = lastSettings else { return }
        for change in changedSettings(old: old, new: now) { record("setting_changed", ["name": change.name, "value": change.value]) }
    }

    /// The OS, Mac model and processor, for app_opened.
    nonisolated static func machineProps() -> [String: Any] {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return ["os": "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)", "mac_model": String(cString: model), "cpu_arch": arch]
    }

    /// The kind of the current default output device: speakers, headphones, bluetooth or other.
    nonisolated static func currentOutputType() -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr,
              dev != kAudioObjectUnknown else { return "other" }
        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        addr.mSelector = kAudioDevicePropertyTransportType
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &transport) == noErr else { return "other" }
        var source: UInt32 = 0
        addr.mSelector = kAudioDevicePropertyDataSource
        addr.mScope = kAudioDevicePropertyScopeOutput
        let hasSource = AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &source) == noErr
        return outputType(transport: transport, dataSource: hasSource ? source : nil)
    }

    // ── Writing and sending ──────────────────────────────────────────────────────────────────

    nonisolated private static func persistIfDirty() {   // on `queue`
        guard dirty, let url = fileURL, let data = try? JSONSerialization.data(withJSONObject: pending) else { return }
        do {
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            dirty = false
        } catch {}
    }

    /// Every 10 s: write the queue, then send what may be sent.
    @MainActor static func tick() async {
        let session = UserSession.shared
        let uid = session.isLoggedIn ? session.userId : ""
        queue.sync { userId = uid; persistIfDirty() }
        guard !sending, maySend(enabled: sendingEnabled, testServer: testServer, pausedUntil: pausedUntil, now: Date()),
              session.isLoggedIn, !session.userId.isEmpty, !session.isGuestSession else { return }
        sending = true
        defer { sending = false }
        if session.idToken.isEmpty || session.tokenNeedsRefresh { _ = await session.tryRefreshAsync() }
        for _ in 0..<5 {   // at most 1,000 events a tick; the rest go on the next one
            let (events, last) = queue.sync { (batch(pending), lastSeq(ofBatchIn: pending)) }
            guard let last, !events.isEmpty else { return }
            var status = await post(events, token: session.idToken)
            if outcome(status: status) == .refreshAndRetry, await session.tryRefreshAsync() {
                status = await post(events, token: session.idToken)
            }
            switch outcome(status: status) {
            case .sent:
                queue.sync { pending = removingSent(pending, upTo: last); dirty = true; persistIfDirty() }
                dlog("ACTIVITY: sent \(events.count) events (\(status ?? 0))", tag: "ACTIVITY")
            case .endpointMissing:
                pausedUntil = Date().addingTimeInterval(missingPauseSeconds)
                dlog("ACTIVITY: the server has no activity endpoint yet (404); kept on disk, trying again in 15 minutes", tag: "ACTIVITY")
                return
            case .refreshAndRetry, .keep:
                dlog("ACTIVITY: batch not taken (\(status.map(String.init) ?? "no answer")); kept on disk for the next tick", tag: "ACTIVITY")
                return
            }
        }
    }

    @MainActor private static func post(_ events: [[String: Any]], token: String) async -> Int? {
        guard let request = request(backendUrl: AppConfig.backendUrl, token: token, events: events) else { return nil }
        do {
            let (_, response) = try await URLSession.shared.data(for: AppIdentity.label(request))
            return (response as? HTTPURLResponse)?.statusCode
        } catch { return nil }
    }

    /// The app is quitting. Records app_closed, writes the queue and starts one last batch without waiting for it; `wait` on the
    /// result waits until the deadline at most (the presence leave message runs in between, so the two share the same 1.5 s).
    @MainActor static func beginQuitFlush() -> QuitFlush {
        let flush = QuitFlush()
        record("app_closed", ["reason": closingForUpdate ? "update" : "quit"])
        let session = UserSession.shared
        let uid = session.isLoggedIn ? session.userId : ""
        let (events, last): ([[String: Any]], Int?) = queue.sync {
            persistIfDirty()
            userId = uid
            return (batch(pending), lastSeq(ofBatchIn: pending))
        }
        guard maySend(enabled: sendingEnabled, testServer: testServer, pausedUntil: pausedUntil, now: Date()),
              session.isLoggedIn, !session.isGuestSession, !session.tokenNeedsRefresh, let last,
              let request = request(backendUrl: AppConfig.backendUrl, token: session.idToken, events: events) else { return flush }
        flush.started = true
        var timed = AppIdentity.label(request)
        timed.timeoutInterval = quitWaitSeconds
        URLSession.shared.dataTask(with: timed) { _, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode
            if outcome(status: status) == .sent {
                queue.sync { pending = removingSent(pending, upTo: last); dirty = true; persistIfDirty() }
            }
            flush.status = status ?? 0
            flush.done.signal()
        }.resume()
        return flush
    }

    final class QuitFlush: @unchecked Sendable {
        fileprivate var started = false
        fileprivate var status = 0
        fileprivate let done = DispatchSemaphore(value: 0)
        /// Blocks until the last batch is answered or the deadline passes. Says in the log which.
        nonisolated func wait(until deadline: Date) {
            guard started else { return }
            let ok = done.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .success
            dlog(ok ? "ACTIVITY: last batch at quit answered \(status)" : "ACTIVITY: last batch at quit not answered in time; it stays on disk", tag: "ACTIVITY")
        }
    }
}
