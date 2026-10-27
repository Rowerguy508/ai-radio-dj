import AVFoundation
import AeroDJCore
import Foundation
import os

/// Free, offline Apple TTS: the last route in the voice fallback chain.
///
/// Renders with `AVSpeechSynthesizer.write`. Completion is whichever comes first:
/// a zero-frame buffer or the delegate's `didFinish` (iOS may skip the empty
/// buffer); `SpeechRenderCompletion` resumes exactly once. Buffers are written in their own format (no forced
/// sample rate), write errors fail the render, and the duration is measured
/// from rendered frames, not estimated.
public struct OnDeviceSpeechProvider: VoiceProvider {
    public static let providerID = "avspeech"

    /// Once per launch: remove temp audio a crash or kill left in tmp/aerodj-speech/.
    private static let launchSweep: Void = { SpeechTempFiles.shared.sweep() }()

    public init() { _ = Self.launchSweep }

    public func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        // The temp file is deleted on success, error and cancellation.
        let (data, seconds) = try await SpeechTempFiles.shared.withFile { url in
            try await SpeechRenderJob(text: text, voiceID: voice.id, url: url).run()
        }
        return VoiceArtifact(data: data, durationSeconds: seconds, billableUnits: 0,
                             provider: Self.providerID, cacheKey: nil)
    }
}

enum OnDeviceSpeechError: Error {
    case unexpectedBuffer
    case emptyAudio
}

private final class SpeechRenderJob: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private let utterance: AVSpeechUtterance
    private let url: URL
    private let lock = NSLock()
    private let completion = SpeechRenderCompletion()
    private var file: AVAudioFile?
    private var frames: AVAudioFramePosition = 0
    private var sampleRate: Double = 0
    private var closed = false  // set before the temp file is deleted; blocks late writes

    init(text: String, voiceID: String, url: URL) {
        let ssml = text.hasPrefix("<speak>") ? AVSpeechUtterance(ssmlRepresentation: text) : nil
        utterance = ssml ?? AVSpeechUtterance(string: SpeechDelivery.plainText(fromSSML: text))
        utterance.voice = AVSpeechSynthesisVoice(identifier: voiceID) ?? AVSpeechSynthesisVoice(language: "en-US")
        self.url = url
        super.init()
        // Buffer-only write. False keeps this synthesizer off the shared session
        // that ApplicationMusicPlayer uses. No setCategory or setActive here.
        // Single resume, 20 s deadline, and temp-file cleanup are unchanged.
        synthesizer.usesApplicationAudioSession = SpeechPrepSession.usesApplicationAudioSession
        synthesizer.delegate = self
    }

    private static let log = Logger(subsystem: "com.aerodj.app", category: "speech")

    func run() async throws -> (Data, Double) {
        defer {
            // every path: no write can (re)create the file after deletion
            let (frames, _) = closeFile()
            // Sanitized: an enum and an integer only, never text or voice. `cancelled` = deadline or caller cancel.
            let signal = completion.winner?.rawValue ?? "none"
            Self.log.info("speech render complete signal=\(signal, privacy: .public) frames=\(Int(frames), privacy: .public)")
        }
        try await completion.wait(start: { [self] in
            synthesizer.write(utterance) { [self] buffer in handle(buffer) }
        }, onCancel: { [self] in
            synthesizer.stopSpeaking(at: .immediate)
        })
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
        closed = true
        return (frames, sampleRate)
    }

    private func handle(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return finish(.failed, OnDeviceSpeechError.unexpectedBuffer) }
        if pcm.frameLength == 0 { return finish(.finalBuffer) }
        do {
            lock.lock()
            defer { lock.unlock() }
            guard !completion.isFinished, !closed else { return }
            if file == nil {
                file = try AVAudioFile(forWriting: url, settings: pcm.format.settings,
                                       commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
                sampleRate = pcm.format.sampleRate
            }
            try file?.write(from: pcm)
            frames += AVAudioFramePosition(pcm.frameLength)
        } catch {
            finish(.failed, error)
        }
    }

    /// Some iOS versions never send the empty final buffer; finishing also completes the render.
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finish(.didFinish)
    }

    /// Idempotent: only the first signal resumes the render.
    private func finish(_ signal: SpeechRenderCompletion.Signal, _ error: Error? = nil) {
        completion.signal(signal, error: error)
    }
}

extension VoiceRoute {
    /// The one on-device voice route (AVSpeechSynthesizer). Shared by the live app
    /// and the test station so voice settings have a single source.
    static func onDevice() -> VoiceRoute {
        let voice = VoiceProfile(id: AVSpeechSynthesisVoice(language: "en-US")?.identifier ?? "", name: "Host")
        return VoiceRoute(providerID: OnDeviceSpeechProvider.providerID, provider: OnDeviceSpeechProvider(),
                          voice: voice, timeout: .seconds(20), acceptsSSML: true)
    }
}

extension VoiceRenderer {
    /// Final beta default (owner-approved): on-device voice only, $0 paid spend,
    /// no network, narration cache retained at most 7 days. Cloud routes
    /// (`ProxyVoiceProvider`) need a deployed proxy and a new owner approval.
    static func onDeviceDefault() -> VoiceRenderer {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let cache = FileAudioCache(directory: support.appendingPathComponent("Voice/Cache"))
        // Live consent is not persisted, so personal clips from an earlier launch go first; then
        // the 7-day cap is swept hourly, not only when a clip is read.
        AudioCacheSweeper(cache: cache).start(purgingPersonalFirst: true)
        return VoiceRenderer(
            routes: [VoiceRoute.onDevice()],
            budget: VoiceBudget(dailyCapMicrodollars: VoiceBetaDefaults.paidDailyCapMicrodollars, file: support.appendingPathComponent("Voice/budget.json")),
            cache: cache)
    }
}
