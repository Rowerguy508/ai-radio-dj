import Foundation
import AVFoundation
import AeroDJCore

/// Plays one DJ break between two songs.
///
/// Two sources, one lifecycle:
/// - `play(clip:line:)`: a clip rendered before the show. Exact length, cost known.
///   This is the normal path.
/// - `play(line:)`: the live voice, used only when no clip exists or the clip
///   cannot be decoded. Never silence.
///
/// Both run `transition -> voice -> music`. Music is paused for the line and
/// resumed afterwards, whether the line finishes, is cancelled, fails, or times
/// out. Playback never stays paused because a callback was missed.
@MainActor
final class InterludePlaybackAdapter: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    private let music: MusicKitService
    private let speech = AVSpeechSynthesizer()
    private var clipPlayer: AVAudioPlayer?
    private var finish: CheckedContinuation<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var outcome: Outcome = .cancelled

    /// How a break ended. Only `.finished` means the whole line was heard.
    private enum Outcome { case finished, cancelled }

    init(music: MusicKitService) {
        self.music = music
        super.init()
        speech.delegate = self
    }

    var isSpeaking: Bool { finish != nil }

    /// Plays a pre-rendered clip. Falls back to the live voice if the clip won't decode.
    func play(clip: Data, line: String) async {
        guard !isSpeaking, !line.isEmpty else {
            music.skipInterlude()
            return
        }
        // A clip that won't decode skips the break. Live speech is not measured, so it
        // would delay the next song; the show goes on and the UI is told.
        guard let player = try? AVAudioPlayer(data: clip), player.duration > 0 else {
            music.reportSpeechError("A DJ line could not be played and was skipped.")
            music.skipInterlude()
            return
        }
        player.delegate = self
        clipPlayer = player
        await runBreak(line: line, timeout: player.duration + 2) {
            player.play()
        }
        clipPlayer = nil
    }

    /// Speaks a line live. Used only when no rendered clip is available.
    func play(line: String) async {
        guard !isSpeaking, !line.isEmpty else {
            music.skipInterlude()
            return
        }
        let utterance = AVSpeechUtterance(string: line)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        let seconds = Double(line.split(separator: " ").count) / 2.0 + 5
        await runBreak(line: line, timeout: seconds) {
            speech.speak(utterance)
        }
    }

    func stop() {
        speech.stopSpeaking(at: .immediate)
        clipPlayer?.stop()
        finishBreak(.cancelled)
    }

    /// The one break lifecycle. `start` begins audio; completion comes from the
    /// delegate, or from the timeout if no callback arrives.
    private func runBreak(line: String, timeout seconds: Double, start: () -> Void) async {
        music.pausePlayerForBreak()
        music.beginInterlude() // transition -> voice
        outcome = .cancelled
        music.djStarted(line)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            finish = continuation
            timeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { return }
                self?.finishBreak(.cancelled)
            }
            start()
        }

        music.endInterlude() // voice -> music
        if outcome == .finished { music.djFinished() } else { music.djCancelled() }
        // Music returns only if the user still wants it and the system is not holding it.
        await music.resumeIfAllowed()
    }

    private func finishBreak(_ result: Outcome) {
        timeout?.cancel()
        timeout = nil
        guard let continuation = finish else { return }
        finish = nil
        outcome = result
        continuation.resume()
    }

    // MARK: AVSpeechSynthesizerDelegate. Callbacks arrive on an arbitrary queue; hop to the main actor.

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finishBreak(.finished) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finishBreak(.cancelled) }
    }

    // MARK: AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.finishBreak(flag ? .finished : .cancelled) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in self?.finishBreak(.cancelled) }
    }
}
