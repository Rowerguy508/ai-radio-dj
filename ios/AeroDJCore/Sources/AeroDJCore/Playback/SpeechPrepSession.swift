import Foundation

/// How offline speech rendering may touch the audio session.
///
/// Break prep writes buffers while a song is playing. It must not attach to the
/// app session `ApplicationMusicPlayer` uses, and it must not call `setCategory`
/// or `setActive`. Playback of a prepared clip is a later step, on `AVAudioPlayer`,
/// after music has been paused.
public enum SpeechPrepSession {
    /// `AVSpeechSynthesizer.usesApplicationAudioSession` for buffer-only `write`.
    /// False keeps the synthesizer off the shared session. The 20 s deadline, the
    /// single resume, and temp-file cleanup are unchanged.
    public static let usesApplicationAudioSession = false

    public static func activatesSharedSession(
        usesApplicationAudioSession: Bool,
        setsCategory: Bool,
        setsActive: Bool
    ) -> Bool {
        usesApplicationAudioSession || setsCategory || setsActive
    }
}
