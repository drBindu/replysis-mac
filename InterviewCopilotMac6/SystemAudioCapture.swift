import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

let RATE: Double = 16000
let CH: AVAudioChannelCount = 1

class Cap: NSObject, SCStreamOutput, SCStreamDelegate {
    var sc: SCStream?
    var conv: AVAudioConverter?
    var outFmt: AVAudioFormat?

    func start() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            guard let display = content.displays.first else {
                fputs("ERROR: no display\n", stderr)
                exit(1)
            }
            let filter = SCContentFilter(
                display: display,
                excludingApplications: [],
                exceptingWindows: []
            )
            let cfg = SCStreamConfiguration()
            cfg.capturesAudio              = true
            cfg.excludesCurrentProcessAudio = true
            cfg.sampleRate                 = Int(RATE)
            cfg.channelCount               = Int(CH)
            cfg.width                      = 2
            cfg.height                     = 2
            cfg.minimumFrameInterval       = CMTime(value: 1, timescale: 1)

            sc = SCStream(filter: filter, configuration: cfg, delegate: self)
            try sc?.addStreamOutput(
                self,
                type: .audio,
                sampleHandlerQueue: DispatchQueue(label: "aq")
            )
            try await sc?.startCapture()
            fputs("SYSTEM_AUDIO_READY\n", stderr)
            // NOTE: do NOT call dispatchMain() here — RunLoop.main.run() at the
            // bottom of the file already keeps this process alive and drives the
            // main queue. Calling dispatchMain() from inside a Task (which runs on
            // the main actor) while RunLoop.main is already running causes SIGTRAP.
        } catch {
            let m = error.localizedDescription.lowercased()
            fputs("ERROR: \(error.localizedDescription)\n", stderr)
            if m.contains("permission") || m.contains("denied") {
                fputs("PERMISSION_DENIED\n", stderr)
            }
            exit(1)
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer buf: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else { return }

        // ── Build converter on first buffer using the REAL format from ScreenCaptureKit ──
        // BUG FIX: Use AVAudioFormat(cmAudioFormatDescription:) so we get the correct
        // interleaved/non-interleaved flag. The old code used interleaved:true but
        // ScreenCaptureKit delivers non-interleaved Float32, so floatChannelData?[0]
        // returned nil and the input buffer was never filled → all-zeros → garbage STT.
        if conv == nil {
            guard let fmtDesc = buf.formatDescription,
                  let dstFmt = AVAudioFormat(
                      commonFormat: .pcmFormatInt16,
                      sampleRate: RATE,
                      channels: CH,
                      interleaved: true
                  )
            else { return }

            let srcFmt = AVAudioFormat(cmAudioFormatDescription: fmtDesc)
            outFmt = dstFmt
            conv   = AVAudioConverter(from: srcFmt, to: dstFmt)
            fputs("CONVERTER: \(srcFmt.sampleRate)Hz \(srcFmt.channelCount)ch → \(Int(RATE))Hz 1ch int16\n", stderr)
        }

        guard let c = conv, let oFmt = outFmt else { return }

        let n = CMSampleBufferGetNumSamples(buf)
        guard n > 0 else { return }

        // ── Copy audio data properly using CMSampleBufferCopyPCMDataIntoAudioBufferList ──
        guard let srcBuf = AVAudioPCMBuffer(
            pcmFormat: c.inputFormat,
            frameCapacity: AVAudioFrameCount(n)
        ) else { return }
        srcBuf.frameLength = AVAudioFrameCount(n)

        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            buf,
            at: 0,
            frameCount: Int32(n),
            into: srcBuf.mutableAudioBufferList
        )
        guard copyStatus == noErr else {
            fputs("COPY_ERR: \(copyStatus)\n", stderr)
            return
        }

        // ── Convert to mono 16kHz int16 ──
        let ratio   = RATE / c.inputFormat.sampleRate
        let outCap  = AVAudioFrameCount(Double(n) * ratio + 1)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: oFmt, frameCapacity: outCap)
        else { return }

        var convErr: NSError?
        var inputGiven = false
        c.convert(to: outBuf, error: &convErr) { _, status in
            if inputGiven {
                status.pointee = .noDataNow
                return nil
            }
            inputGiven     = true
            status.pointee = .haveData
            return srcBuf
        }
        guard convErr == nil, outBuf.frameLength > 0 else { return }

        guard let p16 = outBuf.int16ChannelData?[0] else { return }
        let byteCount = Int(outBuf.frameLength) * 2
        let data      = Data(bytes: p16, count: byteCount)
        // Use the throwing write API — avoids SIGTRAP on broken pipe or closed fd
        do {
            try FileHandle.standardOutput.write(contentsOf: data)
        } catch {
            fputs("WRITE_ERR: \(error.localizedDescription)\n", stderr)
            exit(0)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("STOPPED: \(error)\n", stderr)
        exit(1)
    }
}

let cap = Cap()
Task { await cap.start() }
RunLoop.main.run()
