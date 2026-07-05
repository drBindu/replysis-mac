import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

// ══════════════════════════════════════════════════════════════════════════
// SystemAudioTapper — Core Audio process tap, running INSIDE the app process.
//
// WHY IN-APP: a separate helper process (the old SystemAudioCapture grandchild)
// does not inherit the app's audio-recording TCC grant, so macOS feeds its tap
// pure silence (peak=0.000 in the debug log even with audio playing). Running
// the tap in the app itself uses the permission the user actually granted, so
// it captures real audio. It's audio-only (no ScreenCaptureKit) → no purple
// icon; it never opens the mic → no orange dot.
//
// Output: 16 kHz mono s16le PCM written to a FIFO the Python engine reads.
// ══════════════════════════════════════════════════════════════════════════

@available(macOS 14.2, *)
nonisolated final class SystemAudioTapper {
    static let shared = SystemAudioTapper()
    private init() {}

    private let TARGET_RATE: Double = 16000

    // Core Audio object ids (only touched on start/stop from the main actor).
    nonisolated(unsafe) private var tapID = AudioObjectID(kAudioObjectUnknown)
    nonisolated(unsafe) private var aggID = AudioObjectID(kAudioObjectUnknown)
    nonisolated(unsafe) private var procID: AudioDeviceIOProcID?
    nonisolated(unsafe) private var running = false
    nonisolated(unsafe) private var fifoPath = ""

    // Stop flag shared with the writer thread.
    private let stateLock = NSLock()
    nonisolated(unsafe) private var _stop = false
    private func setStop(_ v: Bool) { stateLock.lock(); _stop = v; stateLock.unlock() }
    private func shouldStop() -> Bool { stateLock.lock(); let v = _stop; stateLock.unlock(); return v }

    // Thread-safe PCM hand-off from the realtime IO proc to the FIFO writer thread.
    private final class PCMQueue {
        nonisolated(unsafe) private var buf = Data()
        private var lock = os_unfair_lock()
        func push(_ d: Data) { os_unfair_lock_lock(&lock); buf.append(d); os_unfair_lock_unlock(&lock) }
        func drain() -> Data { os_unfair_lock_lock(&lock); let d = buf; buf = Data(); os_unfair_lock_unlock(&lock); return d }
        func clear() { os_unfair_lock_lock(&lock); buf = Data(); os_unfair_lock_unlock(&lock) }
    }
    private let pcmQueue = PCMQueue()

    // MARK: - Core Audio helpers
    private static func sysObjectID(_ selector: AudioObjectPropertySelector) -> AudioObjectID {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var devID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devID)
        return devID
    }
    private static func deviceUID(_ devID: AudioObjectID) -> String? {
        guard devID != kAudioObjectUnknown else { return nil }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let st = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(devID, &addr, 0, nil, &size, $0)
        }
        return st == noErr ? (uid as String) : nil
    }

    // MARK: - Start / Stop

    /// Begin capturing system audio into the FIFO at `path`. Returns true on success.
    @discardableResult
    func start(fifoPath path: String) -> Bool {
        guard !running else { return true }
        fifoPath = path
        setStop(false)

        // (Re)create the FIFO so the engine can open it for reading.
        unlink(path)
        if mkfifo(path, 0o600) != 0 && errno != EEXIST {
            dlog("in-app tap: mkfifo failed errno=\(errno)", tag: "TAP"); return false
        }

        // 1. Global mono process tap; keep playback audible.
        let tapDesc = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        tapDesc.isPrivate = true
        tapDesc.muteBehavior = .unmuted
        var tid = AudioObjectID(kAudioObjectUnknown)
        let ts = AudioHardwareCreateProcessTap(tapDesc, &tid)
        guard ts == noErr, tid != kAudioObjectUnknown else {
            dlog("in-app tap: create failed status=\(ts) (audio permission?)", tag: "TAP"); return false
        }
        tapID = tid

        // 2. Tap stream format (typically 48 kHz float mono).
        var asbd = AudioStreamBasicDescription()
        var asz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var fmtAddr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(tid, &fmtAddr, 0, nil, &asz, &asbd) == noErr, asbd.mSampleRate > 0 else {
            dlog("in-app tap: read format failed", tag: "TAP"); teardown(); return false
        }
        dlog("in-app tap: format \(Int(asbd.mSampleRate))Hz \(asbd.mChannelsPerFrame)ch", tag: "TAP")

        // 3. Private aggregate device (output device provides the clock, tap the audio).
        let outDev = Self.sysObjectID(kAudioHardwarePropertyDefaultOutputDevice)
        guard let outUID = Self.deviceUID(outDev) else {
            dlog("in-app tap: no default output device", tag: "TAP"); teardown(); return false
        }
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Interview Copilot Audio",
            kAudioAggregateDeviceUIDKey as String: "com.bindualekhya.InterviewCopilot.sysaudio.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey as String: outUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [[kAudioSubDeviceUIDKey as String: outUID]],
            kAudioAggregateDeviceTapListKey as String: [[
                kAudioSubTapDriftCompensationKey as String: true,
                kAudioSubTapUIDKey as String: tapDesc.uuid.uuidString,
            ]],
        ]
        var aid = AudioObjectID(kAudioObjectUnknown)
        let ags = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &aid)
        guard ags == noErr, aid != kAudioObjectUnknown else {
            dlog("in-app tap: aggregate failed status=\(ags)", tag: "TAP"); teardown(); return false
        }
        aggID = aid

        // 4. Converter: tap float @ 48k → 16 kHz mono s16le.
        var asbdVar = asbd
        guard let inFmt = AVAudioFormat(streamDescription: &asbdVar),
              let outFmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: TARGET_RATE, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inFmt, to: outFmt) else {
            dlog("in-app tap: converter failed", tag: "TAP"); teardown(); return false
        }

        // 5. FIFO writer thread.
        startWriter()

        // 6. IO proc (runs on Core Audio's realtime thread; keep it lean).
        let q = pcmQueue
        let tRate = asbd.mSampleRate
        let bpf = max(1, Int(asbd.mBytesPerFrame))
        let ioBlock: AudioDeviceIOBlock = { (_, inData, _, _, _) in
            let abl = inData.pointee
            guard abl.mNumberBuffers > 0 else { return }
            let fb = abl.mBuffers
            guard fb.mData != nil, fb.mDataByteSize > 0 else { return }
            let inFrames = Int(fb.mDataByteSize) / bpf
            if inFrames == 0 { return }
            guard let inPCM = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(inFrames)) else { return }
            inPCM.frameLength = AVAudioFrameCount(inFrames)
            let dstABL = inPCM.mutableAudioBufferList
            let dstBufs = UnsafeMutableAudioBufferListPointer(dstABL)
            let srcBufs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            let n = min(Int(dstABL.pointee.mNumberBuffers), Int(inData.pointee.mNumberBuffers))
            for i in 0..<n {
                if let s = srcBufs[i].mData, let d = dstBufs[i].mData {
                    memcpy(d, s, min(Int(srcBufs[i].mDataByteSize), Int(dstBufs[i].mDataByteSize)))
                }
            }
            let outCap = AVAudioFrameCount((Double(inFrames) * 16000.0 / tRate).rounded(.up) + 16)
            guard let outPCM = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCap) else { return }
            var fed = false
            var e: NSError?
            let cst = converter.convert(to: outPCM, error: &e) { _, s in
                if fed { s.pointee = .noDataNow; return nil }
                fed = true; s.pointee = .haveData; return inPCM
            }
            guard cst != .error, outPCM.frameLength > 0, let ch = outPCM.int16ChannelData else { return }
            q.push(Data(bytes: ch[0], count: Int(outPCM.frameLength) * MemoryLayout<Int16>.size))
        }
        var pid: AudioDeviceIOProcID?
        let ps = AudioDeviceCreateIOProcIDWithBlock(&pid, aid, nil, ioBlock)
        guard ps == noErr, let proc = pid else {
            dlog("in-app tap: IOProc failed status=\(ps)", tag: "TAP"); teardown(); return false
        }
        procID = proc
        let ss = AudioDeviceStart(aid, proc)
        guard ss == noErr else {
            dlog("in-app tap: AudioDeviceStart failed status=\(ss)", tag: "TAP"); teardown(); return false
        }
        running = true
        dlog("in-app tap: STARTED — capturing system audio → \(path)", tag: "TAP")
        return true
    }

    func stop() {
        setStop(true)
        teardown()
        dlog("in-app tap: stopped", tag: "TAP")
    }

    private func teardown() {
        if let proc = procID, aggID != kAudioObjectUnknown {
            AudioDeviceStop(aggID, proc)
            AudioDeviceDestroyIOProcID(aggID, proc)
        }
        if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID); aggID = kAudioObjectUnknown }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = kAudioObjectUnknown }
        procID = nil
        running = false
        pcmQueue.clear()
    }

    // MARK: - FIFO writer

    private func startWriter() {
        let path = fifoPath
        let q = pcmQueue
        let t = Thread { [weak self] in
            guard let self else { return }
            var bytesThisSec = 0
            var peakThisSec: Int32 = 0
            var lastLog = Date()
            while !self.shouldStop() {
                // Blocks until the engine opens the FIFO for reading.
                let fd = open(path, O_WRONLY)
                if fd < 0 { usleep(100_000); continue }
                writeLoop: while !self.shouldStop() {
                    let chunk = q.drain()
                    if chunk.isEmpty { usleep(5_000) } else {
                        var ok = true
                        chunk.withUnsafeBytes { raw in
                            let base = raw.baseAddress!
                            let total = raw.count
                            var off = 0
                            while off < total {
                                let w = write(fd, base + off, total - off)
                                if w <= 0 { ok = false; break }
                                off += w
                            }
                        }
                        if !ok { break writeLoop }   // reader gone → reopen
                        bytesThisSec += chunk.count
                        chunk.withUnsafeBytes { raw in
                            let s = raw.bindMemory(to: Int16.self)
                            let step = max(1, s.count / 256)
                            var i = 0
                            while i < s.count { let a = abs(Int32(s[i])); if a > peakThisSec { peakThisSec = a }; i += step }
                        }
                    }
                    let now = Date(); let el = now.timeIntervalSince(lastLog)
                    if el >= 2.0 {
                        dlog(String(format: "in-app tap: peak=%.3f  rate=%.0fB/s",
                                    Double(peakThisSec) / 32768.0, Double(bytesThisSec) / el), tag: "TAP")
                        bytesThisSec = 0; peakThisSec = 0; lastLog = now
                    }
                }
                close(fd)
            }
        }
        t.stackSize = 512 * 1024
        t.start()
    }
}
