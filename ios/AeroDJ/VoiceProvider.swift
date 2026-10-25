import Foundation
import AVFoundation
import AeroDJCore

/// Apple AVSpeechSynthesizer — $0 network bill, offline, no keys.
/// Writes synthesized speech to a playable audio file.
public struct AVSpeechVoiceProvider: VoiceProvider {
    public let voiceID: String
    private let sampleRate: Double

    public init(voiceID: String = "com.apple.Speech.Synthesis.voice.Alex", sampleRate: Double = 22_050) {
        self.voiceID = voiceID
        self.sampleRate = sampleRate
    }

    public func synthesize(_ text: String, voice: VoiceProfile,
                           context: RequestContext) async throws -> VoiceArtifact {
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        // Prefer the requested profile identifier extension; default to the provider voice.
        let identifier = voice.id.isEmpty ? voiceID : voice.id
        if let avVoice = AVSpeechSynthesisVoice(identifier: identifier) ?? AVSpeechSynthesisVoice(language: "en-US") {
            utterance.voice = avVoice
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        // Render to a WAV file.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aerodj-voice", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(UUID().uuidString).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let audioFile = try AVAudioFile(forWriting: file, settings: format.settings)

        // Stream into the file and wait for completion.
        let done = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            synthesizer.write(utterance) { buffer in
                if let buffer = buffer {
                    try? audioFile.write(from: buffer)
                } else {
                    cont.resume(returning: true)
                }
            }
        }
        _ = done
        try? audioFile.close()

        let duration = estimateDuration(text)
        let bytes = (try? Data(contentsOf: file)) ?? Data()
        return VoiceArtifact(
            data: bytes,
            durationSeconds: duration,
            billableUnits: text.count,
            provider: "avspeech",
            cacheKey: nil
        )
    }

    /// AVSpeech has no exact duration API; estimate ~15 wpm slower than written.
    private func estimateDuration(_ text: String) -> Double {
        let words = Double(text.split(separator: " ").count)
        return max(words / 2.0, 1.0) // ~120 wpm, floor 1s
    }
}

/// Errors for provider selection.
public enum VoiceRoutingError: Error, Equatable, Sendable {
    case noProviderConfigured
}

/// Routes to Cartesia when a backend endpoint + key are configured, else
/// falls back to native AVSpeech. Cartesia is deliberately a stub — no
/// invented API. Default (no keys) → AVSpeech.
public struct RoutingVoiceProvider: VoiceProvider {
    private let cartesiaEndpoint: URL?
    private let fallback: any VoiceProvider

    /// Routes to native AVSpeech. `cartesiaEndpoint` must be a real backend
    /// route; nil/absent disables Cartesia without inventing one.
    public init(cartesiaEndpoint: URL? = nil, fallback: any VoiceProvider = AVSpeechVoiceProvider()) {
        self.cartesiaEndpoint = cartesiaEndpoint
        self.fallback = fallback
    }

    public func synthesize(_ text: String, voice: VoiceProfile,
                           context: RequestContext) async throws -> VoiceArtifact {
        if let endpoint = cartesiaEndpoint {
            return try await cartesiaSynthesize(text, voice: voice, context: context, endpoint: endpoint)
        }
        return try await fallback.synthesize(text, voice: voice, context: context)
    }

    /// Cartesia via secure backend. Requires a real endpoint + server-side key;
    /// the backend proxies so the key never ships to the client.
    private func cartesiaSynthesize(_ text: String, voice: VoiceProfile,
                                    context: RequestContext, endpoint: URL) async throws -> VoiceArtifact {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "text": text,
            "voiceId": voice.id,
            "stationId": context.stationID,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw VoiceError.providerFailed(underlying: "cartesia backend returned \(String(describing: (response as? HTTPURLResponse)?.statusCode))")
        }
        // Backend returns raw audio bytes; duration from the X-Duration header.
        let duration = (http.value(forHTTPHeaderField: "X-Duration") as NSString?)?.doubleValue
            ?? min(Double(text.count) / 15.0, 300)
        return VoiceArtifact(
            data: data, durationSeconds: duration,
            billableUnits: text.count, provider: "cartesia", cacheKey: nil)
    }
}