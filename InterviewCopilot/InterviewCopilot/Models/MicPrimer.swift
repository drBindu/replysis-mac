import AVFoundation

// ══════════════════════════════════════════════════════════════════════════
// MicPrimer — starts warming up the microphone hardware as early as physically
// possible in the app's life, independent of and BEFORE the Speechmatics engine
// spawns its own separate mic stream.
//
// WHY: on-device measurement showed the OS-level mic hardware wake-up takes a
// fixed ~18-20 SECONDS the first time any process opens+starts a mic input in a
// session — regardless of when that start is triggered. The engine's own
// warmup (Python's mic_stream.start_stream(), begun right after it spawns)
// still has to wait for sign-in, credits, and the speech-key fetch to finish
// first. Priming here — in the Swift app process itself, the moment mic
// permission is confirmed — starts the SAME underlying hardware wake-up
// several seconds earlier, while the user is still reading the sign-in/resume
// screen, buying the warmup more real time to finish in the background before
// Space is ever pressed.
//
// This is a genuine experiment: it is NOT confirmed whether CoreAudio's mic
// wake-up cost is shared system-wide across processes or paid separately per
// process. If it's shared, this materially shortens the wait the engine's own
// mic sees; if it's strictly per-process, this is a harmless no-op for the
// engine's timing (still fine to keep, since it doesn't slow anything down).
// ══════════════════════════════════════════════════════════════════════════

@MainActor
final class MicPrimer {
    static let shared = MicPrimer()
    private init() {}

    private var engine: AVAudioEngine?
    private var started = false

    /// Kick off the mic hardware warmup once. Safe to call multiple times — only the
    /// first call does anything. Runs the actual (blocking) engine start off the main
    /// thread so it can never freeze the UI while the hardware wakes up.
    func start() {
        guard !started else { return }
        started = true
        dlog("MicPrimer: starting early mic warmup (independent of the engine)", tag: "MICPRIME")

        let audioEngine = AVAudioEngine()
        self.engine = audioEngine
        let input = audioEngine.inputNode
        // Install a no-op tap so the engine has a real consumer on the input node —
        // required for AVAudioEngine to actually activate the hardware input path.
        input.installTap(onBus: 0, bufferSize: 1024, format: input.inputFormat(forBus: 0)) { _, _ in }

        DispatchQueue.global(qos: .utility).async {
            let startedAt = Date()
            do {
                try audioEngine.start()
                let elapsed = Date().timeIntervalSince(startedAt)
                Task { @MainActor in
                    dlog(String(format: "MicPrimer: hardware warm — AVAudioEngine.start() took %.1fs", elapsed), tag: "MICPRIME")
                }
            } catch {
                Task { @MainActor in
                    dlog("MicPrimer: AVAudioEngine.start() failed — \(error.localizedDescription)", tag: "MICPRIME")
                }
            }
        }
    }
}
