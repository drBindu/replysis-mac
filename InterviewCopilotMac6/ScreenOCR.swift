import Foundation
import ScreenCaptureKit
import Vision
import CoreImage
import CoreMedia

// One-shot screen capture + Vision OCR.
// Prints all extracted text to stdout, then exits.
// Used by Interview Copilot to read what the interviewer has on their screen.

class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    var sc: SCStream?
    var captured = false

    func run() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else {
                fputs("ERROR: no display\n", stderr)
                exit(1)
            }
            let filter = SCContentFilter(
                display: display,
                excludingApplications: [],
                exceptingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.capturesAudio            = false
            cfg.width                    = display.width
            cfg.height                   = display.height
            cfg.minimumFrameInterval     = CMTime(value: 1, timescale: 30)

            sc = SCStream(filter: filter, configuration: cfg, delegate: self)
            try sc?.addStreamOutput(
                self, type: .screen,
                sampleHandlerQueue: DispatchQueue(label: "ocr_q"))
            try await sc?.startCapture()
            fputs("CAPTURE_READY\n", stderr)
            // RunLoop.main.run() at the bottom keeps the process alive for the
            // first frame callback — do NOT call dispatchMain() here (SIGTRAP).
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
        guard type == .screen, !captured else { return }
        captured = true

        guard let imgBuf = CMSampleBufferGetImageBuffer(buf) else {
            fputs("ERROR: no image buffer\n", stderr)
            exit(1)
        }

        let ci  = CIImage(cvPixelBuffer: imgBuf)
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(ci, from: ci.extent) else {
            fputs("ERROR: CIContext failed\n", stderr)
            exit(1)
        }

        let req = VNRecognizeTextRequest()
        req.recognitionLevel      = .accurate
        req.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do {
            try handler.perform([req])
        } catch {
            fputs("OCR_ERR: \(error)\n", stderr)
            exit(1)
        }

        let obs  = req.results ?? []
        let text = obs
            .compactMap { $0.topCandidates(1).first?.string }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n")

        if text.isEmpty {
            print("[No text detected on screen]")
        } else {
            print(text)
        }

        Task {
            try? await stream.stopCapture()
            exit(0)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("STOPPED: \(error)\n", stderr)
    }
}

let cap = ScreenCapturer()
Task { await cap.run() }
RunLoop.main.run()
