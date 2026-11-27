#if canImport(AVFoundation)
import AVFoundation
import Foundation

extension PronunciationHintTable {
    /// The text as an attributed string for `AVSpeechUtterance(attributedString:)`: respellings
    /// substituted, IPA names tagged with `AVSpeechSynthesisIPANotationAttribute`. For the plain-text
    /// route; SSML goes through `applying(toSSML:)`. Only compiled where AVFoundation exists.
    public func attributedSpeech(for text: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for segment in segments(in: text) {
            switch segment {
            case .text(let s):
                out.append(NSAttributedString(string: s))
            case .ipa(let written, let ipa):
                out.append(NSAttributedString(string: written, attributes: [
                    NSAttributedString.Key(AVSpeechSynthesisIPANotationAttribute): ipa,
                ]))
            }
        }
        return out
    }
}
#endif
