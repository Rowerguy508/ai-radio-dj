import Foundation
import AVFoundation
import AeroDJCore

/// Owns the music -> spoken-DJ -> music transition.
///
/// On a scheduled interlude it pauses MusicKit, plays the spoken segment via
/// AVSpeechSynthesizer (never the protected stream), then resumes. The audio
/// state machine reflects each phase. No capture/mixing of the protected
/// stream — playback is either MusicKit OR the local synthesizer, never both.
@MainActor
final class InterludePlaybackAdapter: ObservableObject {
    private let music: MusicKitService
    private let speech = AVSpeechSynthesizer()

    init(music: MusicKitService) {
        self.music = music
        super.init()
    }

    /// Play a DJ interlude: pause music, speak, wait the estimated duration,
    /// then resume music. Returns the segment's metadata.
    func playInterlude(_ segment: BriefingSegment) async -> SpokenResult? {
        guard !segment.text.isEmpty else { return nil }

        music.pause()
        music.beginInterlude() // transition -> voice

        // Speak locally (free, offline); MusicKit is paused so nothing mixes.
        let utterance = AVSpeechUtterance(string: segment.text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        let duration = Double(segment.text.split(separator: " ").count) / 2.0
        speech.speak(utterance)

        // Wait ~the spoken length so we don't cut off the line, then resume.
        try? await Task.sleep(nanoseconds: UInt64(max(duration, 1.0) * 1_000_000_000))

        music.endInterlude() // voice -> music
        try? await music.resume()
        return SpokenResult(text: segment.text, durationSeconds: max(duration, 1.0))
    }

    func stop() {
        speech.stopSpeaking(at: .immediate)
    }

    struct SpokenResult {
        let text: String
        let durationSeconds: Double
    }
}