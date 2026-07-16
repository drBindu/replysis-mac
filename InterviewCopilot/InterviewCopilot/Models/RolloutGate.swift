import Foundation
import CryptoKit

// ══════════════════════════════════════════════════════════════════════════
// RolloutGate — turn a risky change on for a small slice of devices first,
// verify it's actually safe, then widen it — instead of switching everyone
// over to something new and unverified all at once.
//
// WHY THIS EXISTS: the Google Sign-In backend-proxy incident (2026-07-16) went
// from "just activated" to "affecting every user's sign-in" instantly, because
// there was no way to try it on a small slice first. This exists so that never
// has to happen again for any future risky change — not just this one.
//
// HOW TO USE IT: wrap a new/risky code path with a percentage. Start at 0
// (fully off) while building, raise to a small number (5, 10) once you're
// ready for real-world testing, watch for problems, then raise further.
//
//   if RolloutGate.isEnabled("backend_google_exchange", percent: 10) {
//       // new/risky path — only 10% of devices take this branch
//   } else {
//       // proven/existing path — everyone else
//   }
//
// Same device always gets the same answer for a given key + percentage, so a
// feature doesn't flip on and off between launches — it's a stable rollout,
// not a coin flip every time.
// ══════════════════════════════════════════════════════════════════════════

enum RolloutGate {
    static func isEnabled(_ featureKey: String, percent: Int) -> Bool {
        guard percent > 0 else { return false }
        guard percent < 100 else { return true }
        let seed = "\(featureKey)-\(DeviceIdentity.current)"
        // BUG FIX: String.hashValue is explicitly randomized per process launch in
        // Swift (documented behavior, not a guarantee — it's randomized for security,
        // to resist hash-flooding attacks). Using it here would mean the same device
        // could get a DIFFERENT rollout answer every single app launch — exactly the
        // "flip on and off between launches" this was built to prevent, silently
        // broken from day one. SHA256 is stable across launches, processes, and
        // devices — the same input always produces the same output.
        let digestBytes = Array(SHA256.hash(data: Data(seed.utf8)))
        let firstByte = digestBytes.first ?? 0   // 0-255, uniform distribution
        let bucket = Int(firstByte) % 100
        return bucket < percent
    }
}
