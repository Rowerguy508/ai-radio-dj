import Foundation
import AVFoundation
import MusicKit
import AeroDJCore

/// Owns the music -> spoken-DJ -> music transition.
///
/// On a scheduled interlude it pauses MusicKit, plays the spoken segment via
/// AVSpeechSynthesizer (never the protected MusicKit stream), then resumes.
/// The audio state machine reflects each phase. No capture/mixing of the
/// protected stream — playback is either MusicKit OR the local synthesizer,
/// never both at once.
@MainActor
final class InterludePlaybackAdapter: NSObject, ObservableObject {
    private let music: MusicKitService
    private let speech = AVSpeechSynthesizer()
    private var onResume: (() -> Void)?

    struct SpokenResult {
        let text: String
        let durationSeconds: Double
    }

    init(music: MusicKitService) {
        self.music = music
        super.init()
        speech.delegate = self
    }

    /// Play a DJ interlude: pause music, speak, then resume music.
    /// Returns when the spoken line is done (music already resumed).
    func playInterlude(_ segment: BriefingSegment) async -> SpokenResult? {
        guard !segment.text.isEmpty else { return nil }

        // Transition -> voice phase.
        music.pause()
        music.beginInterlude()

        // Speak locally (free, offline); MusicKit is paused so no mixing.
        let text = segment.text
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        let result = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            onResume = { cont.resume(returning: true) }
            speech.speak(utterance)
        }
        _ = result

        // Voice -> music.
        music.endInterlude()
        try? await music.resume()

        let seconds = Double(text.split(separator: " ").count) / 2.0
        return SpokenResult(text: text, durationSeconds: max(seconds, 1.0))
    }

    func stop() {
        speech.stopSpeaking(at: .immediate)
    }
}

extension InterludePlaybackAdapter: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onResume?()
        onResume = nil
    }
}