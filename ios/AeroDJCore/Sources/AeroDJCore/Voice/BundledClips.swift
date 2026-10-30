import Foundation

// Bundled pre-rendered presenter lines (plan: /radio-style/bundled-audio-plan-v1.md).
// Build 27 ships this playback path with an EMPTY manifest, so it is exercised by tests and on
// device while it can never change a break: an empty manifest resolves nothing and every cue
// takes today's path (proxy, then on-device, then skip the break). Clips arrive in a later build,
// rendered once for the one voice the owner picks. A clip is looked up only by the SHA-256 of
// the cue's normalized text, never by its `id`, so any change to the text, voice or render
// settings is a miss and falls back. -Fry

/// The app-bundle JSON resource listing the pre-rendered clips.
public struct BundledClipManifest: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        /// Readable label only (`tone.pool.index`); it shifts if a pool is reordered.
        public let id: String
        public let tone: String
        /// The exact line, before `SpeechDelivery.speakable`.
        public let text: String
        /// `BundledClipManifest.textHash(text)`: the clip's identity.
        public let textSHA256: String
        /// File name in the manifest's directory (the app bundle's resources). No path components.
        public let file: String
        /// Measured duration of the encoded clip. Feeds the break caps and talk-over as-is.
        public let seconds: Double

        public init(id: String, tone: String, text: String, textSHA256: String, file: String, seconds: Double) {
            self.id = id
            self.tone = tone
            self.text = text
            self.textSHA256 = textSHA256
            self.file = file
            self.seconds = seconds
        }
    }

    /// The ElevenLabs voice every clip was rendered in. Nil in an empty manifest.
    public var voiceID: String?
    /// Model and voice settings the clips were rendered with. Nil in an empty manifest.
    public var renderSettingsVersion: String?
    public var entries: [Entry]

    public init(voiceID: String?, renderSettingsVersion: String?, entries: [Entry]) {
        self.voiceID = voiceID
        self.renderSettingsVersion = renderSettingsVersion
        self.entries = entries
    }

    public static let empty = BundledClipManifest(voiceID: nil, renderSettingsVersion: nil, entries: [])

    /// `BundledClipsManifest.json` in the app target's resources.
    public static let resourceName = "BundledClipsManifest"
    public static let resourceExtension = "json"

    /// Model and settings the proxy renders with today (services/aerodj-tts/src/handler.ts:
    /// `DEFAULT_MODEL_ID`, `VOICE_SETTINGS`). A manifest rendered with anything else never plays.
    /// Bump this whenever the proxy's model or settings change.
    public static let currentRenderSettingsVersion = "eleven_flash_v2_5;stability=0.40;similarity=0.75;speed=1.0"

    private enum CodingKeys: String, CodingKey { case voiceID, renderSettingsVersion, entries }

    /// Missing keys decode as empty, so `{}` is an empty manifest.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        voiceID = try c.decodeIfPresent(String.self, forKey: .voiceID)
        renderSettingsVersion = try c.decodeIfPresent(String.self, forKey: .renderSettingsVersion)
        entries = try c.decodeIfPresent([Entry].self, forKey: .entries) ?? []
    }

    /// Tolerant: empty, whitespace-only or malformed data is an empty manifest (music never waits
    /// on a bad resource; every cue takes today's path).
    public static func decode(_ data: Data) -> BundledClipManifest {
        guard !data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) else { return .empty }
        return (try? JSONDecoder().decode(BundledClipManifest.self, from: data)) ?? .empty
    }

    /// Tolerant: a nil URL, or a missing or unreadable file, is an empty manifest.
    public static func load(contentsOf url: URL?) -> BundledClipManifest {
        guard let url, let data = try? Data(contentsOf: url) else { return .empty }
        return decode(data)
    }

    /// The hash a cue is looked up by: SHA-256 (hex) of the text the proxy would be sent.
    public static func textHash(_ text: String) -> String { SHA256Digest.hex(SpeechDelivery.speakable(text)) }

    public enum Problem: Equatable, Sendable {
        case missingVoiceID
        case missingRenderSettingsVersion
        case emptyText(id: String)
        /// `{` or `}` in the text: an unfilled or filled slot (`{nextTitle}`, `{station}`…).
        case slotMarker(id: String)
        case hashMismatch(id: String)
        case badFile(id: String)
        case badSeconds(id: String)
        case duplicateHash(id: String)
        /// Not a fixed presenter line from `BundledClipResolver.allowedTexts`.
        case notAConstantPresenterLine(id: String)
    }

    /// Problems with one entry on its own (no manifest-level or duplicate checks).
    public static func problems(of entry: Entry, allowedTexts: Set<String>?) -> [Problem] {
        var found: [Problem] = []
        if entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { found.append(.emptyText(id: entry.id)) }
        if entry.text.contains("{") || entry.text.contains("}") { found.append(.slotMarker(id: entry.id)) }
        if entry.textSHA256 != textHash(entry.text) { found.append(.hashMismatch(id: entry.id)) }
        let f = entry.file
        if f.isEmpty || f.hasPrefix(".") || f.contains("/") || f.contains("\\") || f.contains(":") {
            found.append(.badFile(id: entry.id))
        }
        if !entry.seconds.isFinite || entry.seconds <= 0 { found.append(.badSeconds(id: entry.id)) }
        if let allowedTexts, !allowedTexts.contains(entry.text) { found.append(.notAConstantPresenterLine(id: entry.id)) }
        return found
    }

    /// Every problem in the manifest. An empty manifest has none (its voice and version may be nil).
    public func problems(allowedTexts: Set<String>? = BundledClipResolver.allowedTexts) -> [Problem] {
        guard !entries.isEmpty else { return [] }
        var found: [Problem] = []
        if (voiceID ?? "").isEmpty { found.append(.missingVoiceID) }
        if (renderSettingsVersion ?? "").isEmpty { found.append(.missingRenderSettingsVersion) }
        var seen: Set<String> = []
        for entry in entries {
            found += Self.problems(of: entry, allowedTexts: allowedTexts)
            if !seen.insert(entry.textSHA256).inserted { found.append(.duplicateHash(id: entry.id)) }
        }
        return found
    }
}

/// Finds a bundled clip for a whole cue. Every gate must hold, else nil and the cue takes
/// today's path unchanged. The bundle is not a `VoiceRoute`: `lastRouteOnly` and `onDeviceOnly`
/// views never see it, and a hit is never written to the listener's audio cache.
public struct BundledClipResolver: Sendable {
    /// `providerID` on a bundled clip (the voice is the manifest's ElevenLabs voice).
    public static let providerID = "elevenlabs-bundled"

    /// Pools that may be bundled in v1: fixed presenter lines with no slot (greetings,
    /// time-of-day atmosphere, continuations). Station IDs (`{station}`) wait for the OnAirly
    /// rename batch; briefing lead-ins and outros are cut (plan v1, decisions 1-2).
    /// Add `.classic` and `.lateNight` when #227 lands.
    public static let bundleableTones: [EditorialTone] = [.warm]

    public static var allowedTexts: Set<String> {
        var lines: Set<String> = []
        for tone in bundleableTones {
            let pools = tone.continuation + tone.atmosphere.values.flatMap { $0 } + tone.greetings.values.flatMap { $0 }
            for line in pools where !line.contains("{") && !line.contains("}") { lines.insert(line) }
        }
        return lines
    }

    public let manifest: BundledClipManifest
    public let directory: URL
    public let activeRenderSettingsVersion: String
    /// Only entries with no problem, by `textSHA256`. Empty when the manifest-level fields are bad.
    private let byHash: [String: BundledClipManifest.Entry]
    private let readData: @Sendable (URL) -> Data?

    public init(manifest: BundledClipManifest, directory: URL,
                activeRenderSettingsVersion: String = BundledClipManifest.currentRenderSettingsVersion,
                allowedTexts: Set<String>? = BundledClipResolver.allowedTexts,
                readData: @escaping @Sendable (URL) -> Data? = { try? Data(contentsOf: $0) }) {
        self.manifest = manifest
        self.directory = directory
        self.activeRenderSettingsVersion = activeRenderSettingsVersion
        self.readData = readData
        var table: [String: BundledClipManifest.Entry] = [:]
        var duplicates: Set<String> = []
        if !(manifest.voiceID ?? "").isEmpty, !(manifest.renderSettingsVersion ?? "").isEmpty {
            for entry in manifest.entries where BundledClipManifest.problems(of: entry, allowedTexts: allowedTexts).isEmpty {
                if table.updateValue(entry, forKey: entry.textSHA256) != nil { duplicates.insert(entry.textSHA256) }
            }
        }
        for hash in duplicates { table[hash] = nil }   // ambiguous: neither plays
        byHash = table
    }

    /// Number of entries that can ever resolve.
    public var usableCount: Int { byHash.count }

    /// The clip for `cue`, or nil. Hits only when all hold:
    /// - attribution is exactly `.presenter` (never `.stationName`, track metadata, personal
    ///   context or missing attribution), and `VoiceRenderer.mayLeaveDevice` would allow it;
    /// - the renderer's first route is the ElevenLabs route in the manifest's voice (so an
    ///   `onDeviceOnly` or `lastRouteOnly` view, or the on-device default, never uses the bundle);
    /// - the manifest's render settings match the active ones;
    /// - SHA-256 of the normalized cue text equals the entry's hash (and the texts agree);
    /// - the clip fits the cue's `maxSeconds` and its file reads as non-empty data.
    public func clip(for cue: NarrationCue, attribution: SpokenAttribution?, renderer: VoiceRenderer) -> RenderedClip? {
        guard !byHash.isEmpty else { return nil }
        guard case .presenter? = attribution, VoiceRenderer.mayLeaveDevice(cue, attribution: attribution) else { return nil }
        guard let route = renderer.routes.first, route.providerID == PremiumVoiceRoutes.providerID, route.leavesDevice,
              let voiceID = manifest.voiceID, route.voice.id == voiceID else { return nil }
        guard manifest.renderSettingsVersion == activeRenderSettingsVersion else { return nil }
        let normalized = SpeechDelivery.speakable(cue.text)
        guard let entry = byHash[SHA256Digest.hex(normalized)], SpeechDelivery.speakable(entry.text) == normalized,
              entry.seconds <= Double(cue.maxSeconds) else { return nil }
        guard let data = readData(directory.appendingPathComponent(entry.file)), !data.isEmpty else { return nil }
        let audio = CachedAudio(data: data, seconds: entry.seconds, providerID: Self.providerID, voiceID: voiceID)
        let key = SHA256Digest.hex([VoiceRenderer.cacheFormatVersion, Self.providerID, voiceID, activeRenderSettingsVersion,
                                    "text", normalized].joined(separator: "\u{1F}"))
        return RenderedClip(cueID: cue.id, audio: audio, cacheKey: key,
                            attempts: [VoiceAttempt(providerID: Self.providerID, result: .cacheHit)])
    }
}
