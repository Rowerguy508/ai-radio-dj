import AVFoundation
import AeroDJCore
import Foundation

/// Free, offline Apple TTS: the last route in the voice fallback chain.
///
/// Renders with `AVSpeechSynthesizer.write`, which signals completion with a
/// zero-frame buffer. Buffers are written in their own format (no forced
/// sample rate), write errors fail the render, and the duration is measured
/// from rendered frames, not estimated.
public struct OnDeviceSpeechProvider: VoiceProvider {
    public static let providerID = "avspeech"

    public init() {}

    public func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        let job = SpeechRenderJob(text: text, voiceID: voice.id)
        let (data, seconds) = try await job.run()
        return VoiceArtifact(data: data, durationSeconds: seconds, billableUnits: 0,
                             provider: Self.providerID, cacheKey: nil)
    }
}

enum OnDeviceSpeechError: Error {
    case unexpectedBuffer
    case emptyAudio
}

private final class SpeechRenderJob: @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private let utterance: AVSpeechUtterance
    private let url: URL
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var file: AVAudioFile?
    private var frames: AVAudioFramePosition = 0
    private var sampleRate: Double = 0
    private var finished = false

    init(text: String, voiceID: String) {
        let ssml = text.hasPrefix("<speak>") ? AVSpeechUtterance(ssmlRepresentation: text) : nil
        utterance = ssml ?? AVSpeechUtterance(string: SpeechDelivery.plainText(fromSSML: text))
        utterance.voice = AVSpeechSynthesisVoice(identifier: voiceID) ?? AVSpeechSynthesisVoice(language: "en-US")
        url = FileManager.default.temporaryDirectory.appendingPathComponent("aerodj-tts-\(UUID().uuidString).caf")
    }

    func run() async throws -> (Data, Double) {
        defer { try? FileManager.default.removeItem(at: url) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if finished {  // cancelled before we started
                    lock.unlock()
                    return continuation.resume(throwing: CancellationError())
                }
                self.continuation = continuation
                lock.unlock()
                synthesizer.write(utterance) { [self] buffer in handle(buffer) }
            }
        } onCancel: { [self] in
            synthesizer.stopSpeaking(at: .immediate)
            finish(CancellationError())
        }
        let (rendered, rate) = closeFile()
        guard rendered > 0, rate > 0 else { throw OnDeviceSpeechError.emptyAudio }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { throw OnDeviceSpeechError.emptyAudio }
        return (data, Double(rendered) / rate)
    }

    /// Synchronous so NSLock is never held across (or called from) an async context.
    private func closeFile() -> (AVAudioFramePosition, Double) {
        lock.lock()
        defer { lock.unlock() }
        file = nil  // closes the file
        return (frames, sampleRate)
    }

    private func handle(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return finish(OnDeviceSpeechError.unexpectedBuffer) }
        if pcm.frameLength == 0 { return finish(nil) }
        do {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            if file == nil {
                file = try AVAudioFile(forWriting: url, settings: pcm.format.settings,
                                       commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
                sampleRate = pcm.format.sampleRate
            }
            try file?.write(from: pcm)
            frames += AVAudioFramePosition(pcm.frameLength)
        } catch {
            finish(error)
        }
    }

    private func finish(_ error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let c = continuation
        continuation = nil
        lock.unlock()
        if let error { c?.resume(throwing: error) } else { c?.resume() }
    }
}

extension VoiceRenderer {
    /// Final beta default (owner-approved): on-device voice only, $0 paid spend,
    /// no network, narration cache retained at most 7 days. Cloud routes
    /// (`ProxyVoiceProvider`) need a deployed proxy and a new owner approval.
    static func onDeviceDefault() -> VoiceRenderer {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let voice = VoiceProfile(id: AVSpeechSynthesisVoice(language: "en-US")?.identifier ?? "", name: "Host")
        let cache = FileAudioCache(directory: support.appendingPathComponent("Voice/Cache"))
        Task { await cache.purgeExpired() }
        return VoiceRenderer(
            routes: [VoiceRoute(providerID: OnDeviceSpeechProvider.providerID, provider: OnDeviceSpeechProvider(),
                                voice: voice, timeout: .seconds(20), acceptsSSML: true)],
            budget: VoiceBudget(dailyCapMicrodollars: 0, file: support.appendingPathComponent("Voice/budget.json")),
            cache: cache)
    }
}
