#if canImport(AVFoundation)
import AVFoundation
import Foundation

/// The real voice list: every `AVSpeechSynthesisVoice` installed on this device, mapped onto
/// `OnDeviceVoice`. Reading it does not speak, render or download anything. Only compiled where
/// AVFoundation exists; Linux tests use `StaticOnDeviceVoiceProvider`.
public struct AVSpeechVoiceProvider: OnDeviceVoiceProviding {
    public init() {}

    public func installedVoices() -> [OnDeviceVoice] {
        AVSpeechSynthesisVoice.speechVoices().map { voice in
            OnDeviceVoice(identifier: voice.identifier, name: voice.name, language: voice.language,
                          tier: Self.tier(voice.quality),
                          isNovelty: voice.voiceTraits.contains(.isNoveltyVoice),
                          isPersonalVoice: voice.voiceTraits.contains(.isPersonalVoice))
        }
    }

    static func tier(_ quality: AVSpeechSynthesisVoiceQuality) -> VoiceQualityTier {
        switch quality {
        case .premium: .premium
        case .enhanced: .enhanced
        default: .standard
        }
    }
}
#endif
