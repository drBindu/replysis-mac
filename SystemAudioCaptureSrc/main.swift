// ══════════════════════════════════════════════════════════════════════════
// SystemAudioCapture — Core Audio process-tap edition
//
// Captures ALL system output audio and writes it to stdout as raw PCM:
//     16 kHz · mono · signed 16-bit little-endian · interleaved
// (exactly what speechmatics_engine.py reads via stdout.read(CHUNK*2)).
//
// WHY THIS EXISTS (the whole point):
//   The previous SystemAudioCapture used ScreenCaptureKit. macOS shows a
//   non-removable purple "Currently Sharing" indicator in the menu bar for
//   ANY ScreenCaptureKit use — a hard OS privacy guarantee. Core Audio
//   process taps (macOS 14.4+) capture system audio WITHOUT that indicator,
//   because they are audio-only and never touch the screen-capture path.
//
// PROTOCOL (unchanged, so this is a drop-in replacement):
//   • stdout → raw PCM stream (16 kHz mono s16le)
//   • stderr → status lines. Prints "SYSTEM_AUDIO_READY" once audio flows;
//              "ERROR: …" / "PERMISSION_DENIED" on failure (both make the
//              Python engine fall back to mic-only — zero interview risk).
// ══════════════════════════════════════════════════════════════════════════

import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

// ── stderr status protocol ────────────────────────────────────────────────
@inline(__always) func status(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}
@inline(__always) func die(_ s: String) -> Never {
    status(s)
    exit(1)
}

let TARGET_RATE: Double = 16000   // Speechmatics ingest rate

// ── Core Audio property helpers ───────────────────────────────────────────
func sysObjectID(_ selector: AudioObjectPropertySelector) -> AudioObjectID {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var devID = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                   &addr, 0, nil, &size, &devID)
    return devID
}

func deviceUID(_ devID: AudioObjectID) -> String? {
    guard devID != kAudioObjectUnknown else { return nil }
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var uid: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let st = withUnsafeMutablePointer(to: &uid) {
        AudioObjectGetPropertyData(devID, &addr, 0, nil, &size, $0)
    }
    return st == noErr ? (uid as String) : nil
}

// ── 1. Create the process tap (all processes, mono, playback stays audible) ─
let tapDesc = CATapDescription(monoGlobalTapButExcludeProcesses: [])
tapDesc.isPrivate = true                 // visible only to us — never listed elsewhere
tapDesc.muteBehavior = .unmuted          // DO NOT mute the user's real audio

var tapID = AudioObjectID(kAudioObjectUnknown)
let tapStatus = AudioHardwareCreateProcessTap(tapDesc, &tapID)
guard tapStatus == noErr, tapID != kAudioObjectUnknown else {
    // A permission/entitlement problem lands here on some macOS builds.
    status("PERMISSION_DENIED")
    die("ERROR: AudioHardwareCreateProcessTap failed (status=\(tapStatus))")
}

// ── 2. Read the tap's native stream format (usually 48 kHz float, mono) ─────
var tapASBD = AudioStreamBasicDescription()
var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
var fmtAddr = AudioObjectPropertyAddress(
    mSelector: kAudioTapPropertyFormat,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
guard AudioObjectGetPropertyData(tapID, &fmtAddr, 0, nil, &asbdSize, &tapASBD) == noErr,
      tapASBD.mSampleRate > 0 else {
    AudioHardwareDestroyProcessTap(tapID)
    die("ERROR: could not read tap stream format")
}
status(">>> Tap format: \(tapASBD.mSampleRate) Hz, \(tapASBD.mChannelsPerFrame) ch")

// ── 3. Build a PRIVATE aggregate device that includes the tap ───────────────
// A default-output sub-device provides a stable clock; the tap provides the
// captured audio. Private + auto-start so nothing appears in Sound settings.
let outputDevID = sysObjectID(kAudioHardwarePropertyDefaultOutputDevice)
guard let outputUID = deviceUID(outputDevID) else {
    AudioHardwareDestroyProcessTap(tapID)
    die("ERROR: no default output device")
}

let aggUID = "com.bindualekhya.InterviewCopilot.systemaudio.\(UUID().uuidString)"
let aggDesc: [String: Any] = [
    kAudioAggregateDeviceNameKey as String:          "Interview Copilot Audio",
    kAudioAggregateDeviceUIDKey as String:           aggUID,
    kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
    kAudioAggregateDeviceIsPrivateKey as String:     true,
    kAudioAggregateDeviceIsStackedKey as String:     false,
    kAudioAggregateDeviceTapAutoStartKey as String:  true,
    kAudioAggregateDeviceSubDeviceListKey as String: [
        [ kAudioSubDeviceUIDKey as String: outputUID ]
    ],
    kAudioAggregateDeviceTapListKey as String: [
        [
            kAudioSubTapDriftCompensationKey as String: true,
            kAudioSubTapUIDKey as String:               tapDesc.uuid.uuidString,
        ]
    ],
]

var aggID = AudioObjectID(kAudioObjectUnknown)
let aggStatus = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
guard aggStatus == noErr, aggID != kAudioObjectUnknown else {
    AudioHardwareDestroyProcessTap(tapID)
    die("ERROR: AudioHardwareCreateAggregateDevice failed (status=\(aggStatus))")
}

// ── 4. Format conversion: tap (float @ 48k) → 16 kHz mono s16le ─────────────
guard let inFormat = AVAudioFormat(streamDescription: &tapASBD),
      let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                    sampleRate: TARGET_RATE,
                                    channels: 1,
                                    interleaved: true),
      let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
    AudioHardwareDestroyAggregateDevice(aggID)
    AudioHardwareDestroyProcessTap(tapID)
    die("ERROR: could not create audio converter")
}

// ── 5. Decouple the realtime audio thread from stdout via a small queue ─────
// The IO proc runs on a realtime thread; writing to a pipe there could block
// if Python stalls. We append converted bytes under a tiny lock and drain to
// stdout from a dedicated thread.
final class PCMQueue {
    private var buf = Data()
    private var lock = os_unfair_lock()
    func push(_ d: Data) { os_unfair_lock_lock(&lock); buf.append(d); os_unfair_lock_unlock(&lock) }
    func drain() -> Data {
        os_unfair_lock_lock(&lock); let d = buf; buf = Data(); os_unfair_lock_unlock(&lock); return d
    }
}
let pcmQueue = PCMQueue()

Thread.detachNewThread {
    let out = FileHandle.standardOutput
    while true {
        let chunk = pcmQueue.drain()
        if chunk.isEmpty { usleep(5_000); continue }   // 5 ms idle
        out.write(chunk)
    }
}

// ── 6. IO proc: convert each callback's audio and enqueue it ────────────────
let ioBlock: AudioDeviceIOBlock = { (_, inInputData, _, _, _) in
    let abl = inInputData.pointee
    guard abl.mNumberBuffers > 0 else { return }
    let firstBuf = abl.mBuffers   // first AudioBuffer
    guard firstBuf.mData != nil, firstBuf.mDataByteSize > 0 else { return }

    let bytesPerInFrame = max(1, Int(tapASBD.mBytesPerFrame))
    let inFrames = Int(firstBuf.mDataByteSize) / bytesPerInFrame
    if inFrames == 0 { return }

    guard let inPCM = AVAudioPCMBuffer(pcmFormat: inFormat,
                                       frameCapacity: AVAudioFrameCount(inFrames)) else { return }
    inPCM.frameLength = AVAudioFrameCount(inFrames)

    // Copy the raw callback bytes into the AVAudioPCMBuffer's backing store.
    let dstABL = inPCM.mutableAudioBufferList
    let srcABL = inInputData
    let n = min(Int(dstABL.pointee.mNumberBuffers), Int(srcABL.pointee.mNumberBuffers))
    let dstBufs = UnsafeMutableAudioBufferListPointer(dstABL)
    let srcBufs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: srcABL))
    for i in 0..<n {
        if let s = srcBufs[i].mData, let d = dstBufs[i].mData {
            let count = min(Int(srcBufs[i].mDataByteSize), Int(dstBufs[i].mDataByteSize))
            memcpy(d, s, count)
        }
    }

    // Rate/format-convert into a 16 kHz mono int16 buffer.
    let outCap = AVAudioFrameCount((Double(inFrames) * TARGET_RATE / tapASBD.mSampleRate).rounded(.up) + 16)
    guard let outPCM = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCap) else { return }

    var fed = false
    var convErr: NSError?
    let st = converter.convert(to: outPCM, error: &convErr) { _, outStatus in
        if fed { outStatus.pointee = .noDataNow; return nil }
        fed = true; outStatus.pointee = .haveData; return inPCM
    }
    guard st != .error, outPCM.frameLength > 0,
          let ch = outPCM.int16ChannelData else { return }

    let byteCount = Int(outPCM.frameLength) * MemoryLayout<Int16>.size
    pcmQueue.push(Data(bytes: ch[0], count: byteCount))
}

var procID: AudioDeviceIOProcID?
let procStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil, ioBlock)
guard procStatus == noErr, let proc = procID else {
    AudioHardwareDestroyAggregateDevice(aggID)
    AudioHardwareDestroyProcessTap(tapID)
    die("ERROR: AudioDeviceCreateIOProcIDWithBlock failed (status=\(procStatus))")
}

// ── 7. Clean teardown on SIGTERM/SIGINT (app quit) ──────────────────────────
// coreaudiod reclaims a private tap/aggregate when the creator dies, but we
// tear down explicitly for immediate cleanliness. DispatchSourceSignal (not
// signal()) is used so the handler can capture our device IDs.
func teardown() {
    AudioDeviceStop(aggID, proc)
    AudioDeviceDestroyIOProcID(aggID, proc)
    AudioHardwareDestroyAggregateDevice(aggID)
    AudioHardwareDestroyProcessTap(tapID)
}
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)   // disable default handler; route through the dispatch source
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { teardown(); exit(0) }
    src.resume()
    signalSources.append(src)
}

// ── 8. Go ───────────────────────────────────────────────────────────────────
let startStatus = AudioDeviceStart(aggID, proc)
guard startStatus == noErr else {
    teardown()
    die("ERROR: AudioDeviceStart failed (status=\(startStatus))")
}
status(">>> Core Audio tap started — capturing system output (no screen-recording indicator)")

// The capture pipeline is now live. Announce READY immediately — the tap
// delivers continuous callbacks (zero-filled during silence), so waiting for
// the first non-silent audio would only risk tripping Python's 6 s fallback.
status("SYSTEM_AUDIO_READY")

RunLoop.main.run()
