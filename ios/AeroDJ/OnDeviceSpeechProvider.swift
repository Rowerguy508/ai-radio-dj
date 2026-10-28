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

    /// Per `voice.id` render health, shared by every route that uses this provider.
    static let health = VoiceHealthLedger()

    private static func render(_ text: String, voiceID: String) async throws -> (Data, Double) {
        // The temp file is deleted on success, error and cancellation.
        try await SpeechTempFiles.shared.withFile { url in
            try await SpeechRenderJob(text: text, voiceID: voiceID, url: url).run()
        }
    }

    public func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        // A voice that just rendered nothing (a Premium voice still downloading, say) is skipped
        // for a while, so the renderer goes straight to the standard-voice route instead of
        // waiting out another timeout. Cancellation is never held against a voice.
        if Self.health.isSuspect(voice.id) { throw OnDeviceSpeechError.voiceRecentlyFailed }
        let (data, seconds): (Data, Double)
        do {
            (data, seconds) = try await Self.render(text, voiceID: voice.id)
        } catch {
            // Only a higher-tier voice is held off: the standard voice is the last route, and one
            // bad render must not silence the DJ for the whole hold-off.
            if !(error is CancellationError), !Task.isCancelled,
               let used = AVSpeechSynthesisVoice(identifier: voice.id), used.quality != .default {
                Self.health.recordFailure(voice.id)
            }
            throw error
        }
        Self.health.recordSuccess(voice.id)
        return VoiceArtifact(data: data, durationSeconds: seconds, billableUnits: 0,
                             provider: Self.providerID, cacheKey: nil)
    }
}

enum OnDeviceSpeechError: Error {
    case unexpectedBuffer
    case emptyAudio
    case voiceRecentlyFailed
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
        utterance.voice = AVSpeechSynthesisVoice(identifier: voiceID) ?? OnDeviceVoiceChoice.bestVoice()
        self.url = url
        super.init()
        // Build 9 P0 (-Atlas): this synthesizer only renders to a buffer, in the background,
        // right after a song tap (#115). With the default (true) it shares the app's audio
        // session, the one ApplicationMusicPlayer plays through, and the system may activate
        // or deactivate that session around the utterance. False gives it a separate,
        // system-managed session, so a render can never pause or deactivate the music.
        synthesizer.usesApplicationAudioSession = false
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

    private func hasFrames() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return frames > 0
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
        if pcm.frameLength == 0 {
            // Higher-tier voices can send an empty buffer before any audio. Only an empty
            // buffer after real audio ends the render; otherwise `didFinish` (or the
            // deadline) does, and a render with no frames still fails as `emptyAudio`.
            guard hasFrames() else { return }
            return finish(.finalBuffer)
        }
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
        onDevice(voiceID: OnDeviceVoiceChoice.bestVoice()?.identifier ?? "")
    }

    /// The best voice first, then a standard voice that ships with iOS. If the best voice
    /// fails, times out, or reads past the cue's cap, `VoiceRenderer` falls through to the
    /// standard route, as it does for any route, before the break is skipped.
    static func onDeviceRoutes() -> [VoiceRoute] {
        let primary = onDevice()
        guard let standard = OnDeviceVoiceChoice.standardVoice(), standard.identifier != primary.voice.id else {
            return [primary]
        }
        return [primary, onDevice(voiceID: standard.identifier)]
    }

    private static func onDevice(voiceID: String) -> VoiceRoute {
        VoiceRoute(providerID: OnDeviceSpeechProvider.providerID, provider: OnDeviceSpeechProvider(),
                   voice: VoiceProfile(id: voiceID, name: "Host"), timeout: .seconds(20), acceptsSSML: true)
    }
}

extension VoiceRenderer {
    /// Final beta default (owner-approved): on-device voice only, $0 paid spend,
    /// no network, narration cache retained at most 7 days. Cloud routes
    /// (`ProxyVoiceProvider`) need a deployed proxy and a new owner approval.
    ///
    /// Phonon is absent unless `AeroDJPhononEnabled` is true on an iOS 18 arm64
    /// device. AVSpeech stays the last route either way.
    static func onDeviceDefault() -> VoiceRenderer {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let cache = FileAudioCache(directory: support.appendingPathComponent("Voice/Cache"))
        // Live consent is not persisted, so personal clips from an earlier launch go first; then
        // the 7-day cap is swept hourly, not only when a clip is read.
        AudioCacheSweeper(cache: cache).start(purgingPersonalFirst: true)
        return VoiceRenderer(
            routes: PhononSpeechRoutes.make(),
            budget: VoiceBudget(dailyCapMicrodollars: VoiceBetaDefaults.paidDailyCapMicrodollars, file: support.appendingPathComponent("Voice/budget.json")),
            cache: cache)
    }
}

/// The DJ's on-device voice: the best installed English voice (premium, then enhanced),
/// not the compact default, which sounds robotic. Falls back to the default en-US voice.
/// Premium and enhanced voices are downloaded by the user in Settings; an app cannot fetch them.
enum OnDeviceVoiceChoice {
    private static let log = Logger(subsystem: "com.aerodj.app", category: "speech")

    static func bestVoice() -> AVSpeechSynthesisVoice? {
        let installed = AVSpeechSynthesisVoice.speechVoices()
        let candidates = installed.map { voice in
            VoiceCandidate(identifier: voice.identifier, language: voice.language, tier: tier(voice.quality),
                           isNovelty: voice.voiceTraits.contains(.isNoveltyVoice),
                           isPersonalVoice: voice.voiceTraits.contains(.isPersonalVoice))
        }
        guard let pick = VoiceQualitySelector.best(from: candidates),
              let voice = installed.first(where: { $0.identifier == pick.identifier }) else {
            log.info("voice selected tier=fallback")
            return AVSpeechSynthesisVoice(language: "en-US")
        }
        // Sanitized: the tier enum only, never the voice name, identifier or language.
        log.info("voice selected tier=\(pick.tier.rawValue, privacy: .public)")
        return voice
    }

    /// The best standard-tier English voice, the fallback route's voice. Nil when none is installed.
    static func standardVoice() -> AVSpeechSynthesisVoice? {
        let installed = AVSpeechSynthesisVoice.speechVoices()
        let candidates = installed.map { voice in
            VoiceCandidate(identifier: voice.identifier, language: voice.language, tier: tier(voice.quality),
                           isNovelty: voice.voiceTraits.contains(.isNoveltyVoice),
                           isPersonalVoice: voice.voiceTraits.contains(.isPersonalVoice))
        }
        guard let pick = VoiceQualitySelector.fallback(from: candidates) else { return nil }
        return installed.first { $0.identifier == pick.identifier }
    }

    private static func tier(_ quality: AVSpeechSynthesisVoiceQuality) -> VoiceQualityTier {
        switch quality {
        case .premium: .premium
        case .enhanced: .enhanced
        default: .standard
        }
    }
}
