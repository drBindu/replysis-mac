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

        // CRASH FIX: calling this again right after stop() (e.g. user flips the audio-
        // mode toggle off then back on) can catch Core Audio mid-teardown from the
        // previous engine instance. In that transitional state, inputFormat(forBus:)
        // can return an invalid (zero sample rate) format, and installTap with an
        // invalid format is an uncatchable AVFoundation crash — not a Swift `throws`,
        // so no do/catch here can save it. A short settle delay avoids hitting that
        // window in the first place; the format check below is the hard backstop.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.started else { return }   // re-toggled off during the delay

            let audioEngine = AVAudioEngine()
            let input = audioEngine.inputNode
            let format = input.inputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                // Hardware not settled yet — skip the warmup rather than risk the crash.
                // The engine's own mic-open later just pays the cold-start cost itself,
                // same as before this fix existed. Safe fallback, not a broken state.
                dlog("MicPrimer: input format not ready yet (sampleRate=\(format.sampleRate)) — skipping warmup safely", tag: "MICPRIME")
                self.started = false
                return
            }
            self.engine = audioEngine
            // Install a no-op tap so the engine has a real consumer on the input node —
            // required for AVAudioEngine to actually activate the hardware input path.
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { _, _ in }

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

    /// BUG FIX: start() had no counterpart — once primed, the mic (and the orange menu-bar
    /// indicator) stayed on for the rest of the session even if the user switched Settings
    /// to "System audio only" afterward. Confirmed live: settings.json correctly saved
    /// micCaptureEnabled=false, but the ALREADY-RUNNING AVAudioEngine from an earlier moment
    /// (when it was still true) had nothing telling it to stop. Called from
    /// MainViewModel.setMicCaptureEnabled(false) so switching modes actually releases the
    /// mic and clears the indicator, not just changes what the Python engine does with it.
    func stop() {
        guard started else { return }
        started = false
        dlog("MicPrimer: stopping — mic capture disabled, releasing hardware", tag: "MICPRIME")
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }
}
