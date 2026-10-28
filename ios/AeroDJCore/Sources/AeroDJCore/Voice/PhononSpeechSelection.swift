import Foundation

/// Pins for the Phonon 31m on-device prototype. Selection and these checks live in
/// AeroDJCore so Linux CI can run them. The iOS 18 runtime is not imported here.
///
/// The Core ML zip is not a file in `gradium/phonon-31m-en` at the export commit
/// (that tree is weights, tokenizer, and the model card). The bytes AeroDJ downloads
/// are the v0.5.0 release asset the Swift guide names, which `source.json` inside
/// the zip says was exported from the 31m commit below. A 40m model is refused.
public enum PhononModelPin {
    public static let providerID = "phonon"
    public static let fallbackProviderID = "avspeech"
    /// Catalog voice packed in the 31m Core ML bundle. Not a paid voice.
    public static let voiceID = "Everly"

    public static let weightsRepository = "gradium/phonon-31m-en"
    /// Commit recorded in the bundle's `source.json`. Not `main`.
    public static let weightsCommit = "8acf8881a96315724c72ed3aad2a0900d1b230ba"
    /// Model card at `weightsCommit`: YAML `license: apache-2.0`. 40m models are CC BY-NC.
    public static let weightsLicense = "apache-2.0"
    public static let sourceModel = "hf://gradium/phonon-31m-en@8acf8881a96315724c72ed3aad2a0900d1b230ba"
    public static let voicesRepository = "gradium/phonon-voices"
    public static let voicesCommit = "da6c9ec0d47be8df5c87c730a3aa97187f3229c3"
    public static let voicesSource = "hf://gradium/phonon-voices@da6c9ec0d47be8df5c87c730a3aa97187f3229c3"
    public static let sourceWeights = "model.safetensors"

    public static let runtimeTag = "v0.5.0"
    public static let runtimeCommit = "e851445158f07061f063e3edff0080f9426c0da2"

    /// SHA-256 and size of `phonon-31m-en-coreml.zip` on the v0.5.0 release
    /// (the v0.4.0 bundle, unchanged). Verified against the downloaded asset.
    public static let bundleSHA256 = "10f3a99fd39256db44f826267ef21d78cca959b16c0554926344c09fde27b436"
    public static let bundleByteCount = 137_096_081

    public static let bundleURLString = "https://github.com/gradium-ai/xn-ptts/releases/download/v0.5.0/phonon-31m-en-coreml.zip"

    /// Same ids `BetaVoicePolicy` keeps off. Phonon must not route to them.
    public static let paidProviderIDs = ["cartesia", "dessa", "elevenlabs"]

    public static var bundleURL: URL { URL(string: bundleURLString)! }

    /// License page for the weights commit. Not a download URL.
    public static var weightsRevisionURL: URL {
        URL(string: "https://huggingface.co/\(weightsRepository)/tree/\(weightsCommit)")!
    }

    /// The only URL the app may request. No query, fragment, user, or token.
    public static func allowsDownload(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil else { return false }
        guard url.query == nil, url.fragment == nil else { return false }
        guard url.absoluteString == bundleURLString else { return false }
        return !namesForbiddenModel(url.absoluteString)
    }

    /// True when `source.json` is the 31m export and not a 40m or `main` revision.
    public static func acceptsSourceJSON(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8), !namesForbiddenModel(text) else { return false }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        guard object["model"] as? String == sourceModel else { return false }
        guard object["voices"] as? String == voicesSource else { return false }
        guard object["weights"] as? String == sourceWeights else { return false }
        return true
    }

    public static func namesForbiddenModel(_ text: String) -> Bool {
        let folded = text.lowercased()
        return folded.contains("40m") || folded.contains("by-nc") || folded.contains("@main") || folded.contains("/main")
    }
}

public enum PhononBundleDigest {
    public enum Verdict: String, Equatable, Sendable {
        case match
        case missing
        case mismatch
    }

    /// Both the byte count and the SHA-256 must match the pin. A missing file is `.missing`.
    public static func verdict(byteCount: Int?, sha256: String?) -> Verdict {
        guard let byteCount, let sha256 else { return .missing }
        guard byteCount == PhononModelPin.bundleByteCount else { return .mismatch }
        guard sha256.lowercased() == PhononModelPin.bundleSHA256 else { return .mismatch }
        return .match
    }

    public static func sha256Hex(ofFile url: URL) throws -> String {
        try SHA256Digest.hex(contentsOf: url)
    }
}

public enum PhononBundlePath {
    public static let rootPrefix = "phonon-31m-en-coreml/"

    /// Path relative to the extracted bundle, or nil when the entry must not be written.
    /// An empty string is the archive's root directory.
    public static func relativePath(forZipEntry entry: String) -> String? {
        if entry.contains("\\") || entry.contains(":") { return nil }
        if entry.hasPrefix("/") || entry.hasPrefix("~") { return nil }
        let parts = entry.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.contains("..") || parts.contains(".") { return nil }
        if PhononModelPin.namesForbiddenModel(entry) { return nil }
        if entry == "phonon-31m-en-coreml" || entry == rootPrefix { return "" }
        guard entry.hasPrefix(rootPrefix) else { return nil }
        let rest = String(entry.dropFirst(rootPrefix.count))
        if rest.isEmpty || rest.hasPrefix("/") { return nil }
        return rest
    }
}

/// Why Phonon is or is not the provider that will be tried.
public enum PhononModelStatus: String, Equatable, Sendable {
    case disabled
    case unsupportedRuntime
    case missing
    case downloadFailed
    case hashMismatch
    case rejectedBundle
    case loadFailed
    case voiceMissing
    case ready
}

public struct PhononSpeechDecision: Equatable, Sendable {
    public let status: PhononModelStatus
    /// Preference order. The last id is always on-device AVSpeech. Paid ids are never included.
    public let providerIDs: [String]

    public var attemptsPhonon: Bool { providerIDs.first == PhononModelPin.providerID }

    public init(status: PhononModelStatus, providerIDs: [String]) {
        self.status = status
        self.providerIDs = providerIDs
    }
}

/// Flag, runtime, and model readiness decide the voice routes. The flag defaults off.
/// AVSpeech stays in the chain. Paid providers are never added.
public enum PhononSpeechSelection {
    public static let flagDefaultsKey = "AeroDJPhononEnabled"

    public static func isFlagEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: flagDefaultsKey)
    }

    public static func isPaidProvider(_ id: String) -> Bool {
        id == "paid" || PhononModelPin.paidProviderIDs.contains(id)
    }

    public static func decide(flagEnabled: Bool, runtimeAvailable: Bool, model: PhononModelStatus) -> PhononSpeechDecision {
        let av = [PhononModelPin.fallbackProviderID]
        if !flagEnabled {
            return PhononSpeechDecision(status: .disabled, providerIDs: av)
        }
        if !runtimeAvailable {
            return PhononSpeechDecision(status: .unsupportedRuntime, providerIDs: av)
        }
        let modelStatus: PhononModelStatus
        switch model {
        case .disabled, .unsupportedRuntime: modelStatus = .missing
        default: modelStatus = model
        }
        return PhononSpeechDecision(status: modelStatus, providerIDs: [PhononModelPin.providerID, PhononModelPin.fallbackProviderID])
    }
}
