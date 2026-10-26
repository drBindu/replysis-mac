import Foundation
import CoreAudio

/// Read the OS-selected input instead of persisting PortAudio indexes, which can change
/// when a headset is unplugged. Querying this does not open or record the microphone.
struct AudioInputRoute: Equatable {
    let deviceID: AudioDeviceID
    let sampleRate: Double

    static func current() -> AudioInputRoute? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                        0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        address.mSelector = kAudioDevicePropertyNominalSampleRate
        var rate: Double = 0
        size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr,
              rate > 0 else { return nil }
        return AudioInputRoute(deviceID: id, sampleRate: rate)
    }
}

// ── Inputs that are not a microphone ─────────────────────────────────────────────────────────
// Virtual devices that carry the computer's own sound (BlackHole, Soundflower, Loopback, Zoom's and Teams' audio devices). When one
// of them is the default input, the person speaks into nothing and the meeting is heard twice. Windows found the same with Stereo Mix
// as the default input on a desktop with no mic (2026-10-22). The engine is then told the name of a real microphone instead.
enum MicChoice {
    static let notAMic = ["blackhole", "soundflower", "loopback audio", "zoomaudiodevice", "zoom audio", "microsoft teams audio",
                          "ms teams audio", "teams audio", "background music", "eqmac", "audio hijack", "virtual desktop speakers"]

    static func isNotAMic(_ name: String) -> Bool {
        let low = name.lowercased()
        return notAMic.contains(where: { low.contains($0) })
    }

    /// The microphone to name to the engine: nil when the default input is a real microphone (the engine uses the default), else the
    /// first real input, in the system's order (the built-in mic is usually first).
    static func replacementForDefault(defaultName: String?, inputs: [String]) -> String? {
        guard let defaultName, isNotAMic(defaultName) else { return nil }
        return inputs.first(where: { !isNotAMic($0) })
    }

    static func deviceName(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr, let value = name?.takeRetainedValue() else { return nil }
        return value as String
    }

    /// Names of every device that has input channels. Reading this opens nothing.
    static func inputDeviceNames() -> [String] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id -> String? in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                     mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0 else { return nil }
            return deviceName(id)
        }
    }
}

/// Require two matching polls to let Bluetooth / USB settle before reconnecting.
/// Silence is never evidence that a different microphone should be selected.
struct AudioInputRouteTracker {
    private(set) var active: AudioInputRoute?
    private var pending: AudioInputRoute?

    mutating func reset(to route: AudioInputRoute?) {
        active = route
        pending = nil
    }

    mutating func shouldReconnect(to route: AudioInputRoute?) -> Bool {
        guard let route, route != active else { pending = nil; return false }
        guard pending == route else { pending = route; return false }
        active = route
        pending = nil
        return true
    }
}
