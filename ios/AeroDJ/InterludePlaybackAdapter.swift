import Foundation
import AVFoundation
import AeroDJCore

/// Plays one spoken DJ break between two songs, using the device's offline voice.
///
/// The caller moves the state machine to `transition` at a natural boundary.
/// `play` then runs `transition -> voice -> music`. Music is paused for the
/// line and resumed afterwards, whether the voice finishes, is cancelled, or
/// the timeout fires. Playback never stays paused because a callback was missed.
/// No protected stream is captured or mixed: MusicKit and the voice never run together.
@MainActor
final class InterludePlaybackAdapter: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    private let music: MusicKitService
    private let speech = AVSpeechSynthesizer()
    private var finish: CheckedContinuation<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var outcome: SpeechOutcome = .cancelled

    /// How a spoken break ended. Only `.finished` means the whole line was heard.
    private enum SpeechOutcome { case finished, cancelled }

    init(music: MusicKitService) {
        self.music = music
        super.init()
        speech.delegate = self
    }

    var isSpeaking: Bool { finish != nil }

    /// Speaks one break. Call only after a natural boundary, in the `transition` state.
    func play(_ text: String) async {
        guard !isSpeaking, !text.isEmpty else {
            music.skipInterlude()
            return
        }
        music.pause()
        music.beginInterlude() // transition -> voice
        outcome = .cancelled
        music.djStarted(text)

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            finish = continuation
            // Upper bound on the line so a missed delegate callback cannot hold playback.
            let seconds = Double(text.split(separator: " ").count) / 2.0 + 5
            timeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { return }
                self?.finishSpeech(.cancelled)
            }
            speech.speak(utterance)
        }

        music.endInterlude() // voice -> music
        if outcome == .finished { music.djFinished() } else { music.djCancelled() }
        do {
            try await music.resume()
        } catch {
            music.reportError("Could not resume music after the DJ break: \(error.localizedDescription)")
        }
    }

    func stop() {
        speech.stopSpeaking(at: .immediate)
    }

    private func finishSpeech(_ result: SpeechOutcome) {
        timeout?.cancel()
        timeout = nil
        guard let continuation = finish else { return }
        finish = nil
        outcome = result
        continuation.resume()
    }

    // AVSpeechSynthesizer calls these on an arbitrary queue; hop back to the main actor.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finishSpeech(.finished) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finishSpeech(.cancelled) }
    }
}
