import Foundation
import IOKit

// Hardware-tied identifier so the backend can grant a free trial (see UserSession.
// startGuestSession()) without an account, while capping it per physical Mac instead
// of per app-install — deleting the app or its saved data can't reset the counter,
// since this doesn't come from anything the app itself writes to disk.
enum DeviceIdentity {
    static let current: String = {
        let platformExpert = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard platformExpert != 0 else { return persistedFallbackId() }
        defer { IOObjectRelease(platformExpert) }
        guard let uuid = IORegistryEntryCreateCFProperty(
            platformExpert, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? String else {
            return persistedFallbackId()
        }
        return uuid
    }()

    // Should never be hit on a real Mac, but falls back to a locally-persisted random ID
    // rather than crash — worst case a rare edge machine gets a second free trial, which
    // is a far better failure mode than the app being unusable.
    private static func persistedFallbackId() -> String {
        let key = "com.coopilotxai.InterviewCopilot.fallbackDeviceId"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: key)
        return new
    }
}
