import AVFoundation

/// Warm the input early. All AVAudioEngine operations run on one serial queue, so
/// disabling capture cannot race a start on another thread and leave the mic open.
@MainActor
final class MicPrimer {
    static let shared = MicPrimer()
    private init() {}

    private let worker = WarmupWorker()
    private var request: WarmupRequest?

    func start() {
        guard request == nil else { return }
        let request = WarmupRequest()
        self.request = request
        worker.start(request) { [weak self] succeeded in
            Task { @MainActor in
                guard let self, self.request === request else { return }
                if !succeeded { self.request = nil }
            }
        }
    }

    func stop() {
        request?.cancel()
        request = nil
        worker.stop()
    }
}

private final class WarmupRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

private final class WarmupWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.replysis.mic-warmup", qos: .utility)
    // Accessed exclusively on queue, including construction and teardown.
    private var engine: AVAudioEngine?

    func start(_ request: WarmupRequest, completion: @escaping @Sendable (Bool) -> Void) {
        queue.asyncAfter(deadline: .now() + 0.3) { [self] in
            guard !request.isCancelled else { completion(false); return }
            dispose()
            let candidate = AVAudioEngine()
            let input = candidate.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                completion(false); return
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { _, _ in }
            engine = candidate
            do {
                guard !request.isCancelled else { dispose(); completion(false); return }
                try candidate.start()
                guard !request.isCancelled else { dispose(); completion(false); return }
                completion(true)
            } catch {
                dispose()
                completion(false)
            }
        }
    }

    func stop() { queue.async { [self] in dispose() } }

    private func dispose() {
        guard let engine else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        self.engine = nil
    }
}
