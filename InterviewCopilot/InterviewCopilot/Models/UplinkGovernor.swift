import Foundation

/// Decides whether a speculative upload, the screenshot sent ahead of any question, may use the
/// connection right now. Ported from the Windows UplinkGovernor so both apps treat a weak line the same way.
///
/// Found on a phone hotspot that uploads 20 to 50 KB a second: a 500 KB picture sent ahead every sixteen
/// seconds filled the line, the speech connection missed its keepalive, and answers waited behind the
/// picture. A picture sent ahead is only worth anything when it arrives quickly, and it must never get in
/// the way of what the person is waiting for. So a small throw-away test upload decides first; pictures go
/// ahead only after it came back in good time, a failure starts a pause that doubles each time, and a
/// changed network starts over.
struct UplinkGovernor {
    /// An upload that takes longer than this is not "ahead" of anything.
    static let maxUsefulUpload: TimeInterval = 6
    /// Gives up on one upload after this long, so a doomed upload holds the line as briefly as possible.
    static let uploadTimeout: TimeInterval = 8
    static let firstBackoff: TimeInterval = 60
    static let maxBackoff: TimeInterval = 10 * 60

    /// Size of the test upload. A mobile line lets the first 64 KB through in a burst and then slows
    /// down, so 64 KB passed on a line that could not finish a 480 KB picture; 160 KB runs past the burst.
    static let probeBytes = 160 * 1024
    /// A test upload still going after this is a slow line.
    static let probeTimeout: TimeInterval = 4
    /// The test must be done within this, round trip included.
    static let probePassWithin: TimeInterval = 1.2

    private(set) var verified = false
    private(set) var failureStreak = 0
    private(set) var quietUntil = Date.distantPast

    /// Pictures wait until a test has passed; true when one should be run now.
    func needsProbe(now: Date) -> Bool { !verified && now >= quietUntil }

    /// Whether to capture and send a picture ahead right now. After a quiet period ends this lets exactly
    /// one attempt through; its outcome decides what happens next.
    func mayUpload(now: Date) -> Bool { now >= quietUntil }

    /// Records how a test upload went. A pass trusts the line; anything else starts the growing pause
    /// and returns it.
    @discardableResult
    mutating func recordProbe(now: Date, succeeded: Bool, elapsed: TimeInterval) -> TimeInterval {
        if succeeded && elapsed <= Self.probePassWithin {
            trust()
            return 0
        }
        return startPause(now: now)
    }

    /// Records how a picture sent ahead went. Returns the quiet period it started, or zero.
    @discardableResult
    mutating func record(now: Date, succeeded: Bool, elapsed: TimeInterval) -> TimeInterval {
        if succeeded && elapsed <= Self.maxUsefulUpload {
            trust()
            return 0
        }
        return startPause(now: now)
    }

    /// Forget everything, for a new session or a changed network.
    mutating func reset() {
        verified = false
        failureStreak = 0
        quietUntil = .distantPast
    }

    private mutating func trust() {
        verified = true
        failureStreak = 0
        quietUntil = .distantPast
    }

    private mutating func startPause(now: Date) -> TimeInterval {
        // In doubt again: the next thing sent is a small test, not another full picture.
        verified = false
        failureStreak += 1
        let seconds = Self.firstBackoff * pow(2, Double(min(failureStreak - 1, 10)))
        let backoff = min(seconds, Self.maxBackoff)
        quietUntil = now.addingTimeInterval(backoff)
        return backoff
    }
}
