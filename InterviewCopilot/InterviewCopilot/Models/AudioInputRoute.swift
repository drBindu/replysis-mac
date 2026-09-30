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
