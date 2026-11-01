import Foundation

// Editorial policy for DJ talk. This does not render audio and does not schedule
// playback. `DJScriptWriter` speaks from these pools; `VoiceRenderer` and
// `DJBreakPreparer` are unchanged.

/// One host voice's phrase bank: every pool a break draws from. Placeholders are filled
/// only from track metadata (`{title}`/`{artist}` of the song that just played,
/// `{nextTitle}`/`{nextArtist}` of the next one) or the station display name (`{station}`).
/// Nothing here claims a genre, a year, a chart position, or weather.
/// A tone can be swapped by handing `DJScriptWriter` another bank; the engine does not change.
/// Lines use contractions and em dashes for pacing. No SSML: cloud voices get plain text.
public struct EditorialTone: Equatable, Sendable {
    /// Names the song that just played. Opens an ordinary break.
    public var backAnnounce: [String]
    /// The closing line: one short sentence naming the next song. It is the last cue of every
    /// break and is the line Fry's player may let land over the next song's intro.
    public var closing: [String]
    /// Occasional opener instead of a plain back-announce. Artist and title only.
    public var artistFocus: [String]
    /// Uses the station's display name only.
    public var stationID: [String]
    /// Time-of-day color. No facts.
    public var atmosphere: [DayPart: [String]]
    /// Presenter connectors with no facts and no names: they never mention a track.
    public var continuation: [String]
    /// Before approved briefing cues.
    public var briefingLead: [String]
    /// After approved briefing cues, before the closing line.
    public var briefingOutro: [String]
    /// The first break of a session.
    public var greetings: [DayPart: [String]]

    public init(backAnnounce: [String], closing: [String], artistFocus: [String], stationID: [String],
                atmosphere: [DayPart: [String]], continuation: [String], briefingLead: [String],
                briefingOutro: [String], greetings: [DayPart: [String]]) {
        self.backAnnounce = backAnnounce
        self.closing = closing
        self.artistFocus = artistFocus
        self.stationID = stationID
        self.atmosphere = atmosphere
        self.continuation = continuation
        self.briefingLead = briefingLead
        self.briefingOutro = briefingOutro
        self.greetings = greetings
    }

    /// Default: warm and conversational.
    public static let warm = EditorialTone(
        backAnnounce: [
            "That was {title}, from {artist}.",
            "{artist} there, with {title}.",
            "You just heard {title} from {artist}.",
            "That one was {title} by {artist}.",
            "{title}, from {artist}.",
            "Just had {title} there.",
        ],
        // Kept at five lines, in this order. `DJNarrationTests` cycles this pool.
        // One sentence of at most seven words, so it fits `DJCadence.maxClosingSeconds`.
        closing: [
            "Here's {nextArtist}, with {nextTitle}.",
            "Here's {nextTitle}, from {nextArtist}.",
            "Next up — {nextArtist}, {nextTitle}.",
            "Here's {nextTitle}.",
            "This is {nextTitle}.",
        ],
        artistFocus: [
            "That was {artist}.",
            "{artist}, with {title}.",
            "From {artist}: {title}.",
            "One from {artist}.",
        ],
        stationID: [
            "You're listening to {station} — just you, me, and the music.",
            "This is {station}.",
            "You're tuned to {station}.",
            "{station} — thanks for listening.",
        ],
        atmosphere: [
            .earlyMorning: ["Quiet start — the day's just getting going.", "Early one. Take it slow."],
            .morning: ["Hope the morning's going easy.", "A little while before midday."],
            .afternoon: ["Middle of the afternoon — hope it's going okay.", "The afternoon's moving along."],
            .evening: ["Evening's settling in.", "Winding the day down — no rush."],
            .lateNight: ["Late hours — a quiet stretch of the night.", "Still up this late? Glad you're here."],
        ],
        continuation: [
            "Wherever you're listening, thanks for spending a little time here.",
            "Plenty more on the way.",
            "Stay right where you are.",
            "We'll keep it rolling.",
            "Thanks for keeping me company.",
        ],
        briefingLead: [
            "Let me catch you up.",
            "A couple of things before the next song.",
            "While we're between songs.",
            "Quick one before the next song.",
        ],
        briefingOutro: [
            "That's it from me for now.",
            "Okay — back to the music.",
            "That's all for now.",
        ],
        greetings: [
            .earlyMorning: ["Early start today.", "Good morning, early riser."],
            .morning: ["Good morning.", "Morning."],
            .afternoon: ["Good afternoon.", "Afternoon."],
            .evening: ["Good evening.", "Evening."],
            .lateNight: ["Late one tonight.", "Still up? Good."],
        ]
    )

    /// Every line in every pool (for scans in tests).
    public var allLines: [String] {
        backAnnounce + closing + artistFocus + stationID + continuation + briefingLead + briefingOutro
            + atmosphere.values.flatMap { $0 } + greetings.values.flatMap { $0 }
    }
}

/// The default tone's pools, by their historical names.
public enum EditorialPhrasing {
    public static var backAnnounce: [String] { EditorialTone.warm.backAnnounce }
    /// The closing pool (the next song's intro).
    public static var songIntro: [String] { EditorialTone.warm.closing }
    public static var artistFocus: [String] { EditorialTone.warm.artistFocus }
    public static var stationID: [String] { EditorialTone.warm.stationID }
    public static var continuation: [String] { EditorialTone.warm.continuation }
    public static var atmosphere: [DayPart: [String]] { EditorialTone.warm.atmosphere }
    public static var atmosphereLines: [String] { atmosphere.values.flatMap { $0 } }

    /// Copy the host does not use. Tests scan scripts and these pools for them.
    public static let forbiddenHype = [
        "amazing", "incredible", "awesome", "legendary", "best song", "love this", "banger",
    ]
}

/// Station IDs speak this string and nothing else. A name that looks like an
/// instruction, or that could break a template, is not spoken.
public enum EditorialStationName {
    public static func usable(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...40).contains(name.count) else { return nil }
        guard !name.contains(where: { "{\n\r}".contains($0) }) else { return nil }
        guard !PromptInjectionSanitizer().isSuspicious(name) else { return nil }
        return name
    }
}

/// Word-count duration at `DefaultBriefingPlanner.wordsPerMinute` (150).
/// This is an estimate. It is not a measurement of synthesized audio.
public enum SpokenDurationEstimate {
    public static let wordsPerMinute = DefaultBriefingPlanner.wordsPerMinute

    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    public static func seconds(_ text: String) -> Int {
        DefaultBriefingPlanner.estimatedSpokenSeconds(for: text)
    }

    public static func seconds(of lines: [String]) -> Int {
        lines.reduce(0) { $0 + seconds($1) }
    }
}

/// What may be offered again after this show. Every unscheduled content cue
/// is in exactly one list. Time-sensitive cues are never in `eligibleNextShow`.
public struct EditorialCarryForward: Equatable, Sendable {
    public let eligibleNextShow: [NarrationCue]
    public let omittedTimeSensitive: [NarrationCue]
    /// Reported drops that are not a later-show candidate: instruction-shaped
    /// text, missing provenance, over budget, render failure, and similar.
    public let omittedOther: [NarrationCue]

    public init(report: NarrationScheduleReport) {
        var next: [NarrationCue] = []
        var timed: [NarrationCue] = []
        var other: [NarrationCue] = []
        for entry in report.entries where entry.cue.isContent {
            switch entry.outcome {
            case .scheduled:
                break
            case .deferred:
                if Self.isTimeSensitive(entry.cue) { timed.append(entry.cue) }
                else { next.append(entry.cue) }
            case .dropped(let reason):
                switch reason {
                case .rejectedAsInstruction, .unattributed:
                    other.append(entry.cue)
                case .notCarriedForward:
                    timed.append(entry.cue)
                default:
                    if Self.isTimeSensitive(entry.cue) { timed.append(entry.cue) }
                    else { other.append(entry.cue) }
                }
            }
        }
        eligibleNextShow = next
        omittedTimeSensitive = timed
        omittedOther = other
    }

    /// Calendar events and due tasks go stale. A later show must not inherit them.
    public static func isTimeSensitive(_ cue: NarrationCue) -> Bool {
        cue.kind == .upcomingEvent || cue.kind == .dueTask
    }
}

extension DJSessionPlan {
    public var carryForward: EditorialCarryForward { EditorialCarryForward(report: briefingReport) }
}

/// What `MusicSearch.live` passes to `DJBreakSession.queueStarted`.
/// A morning show may speak the approved handoff. A later show may speak
/// `carryForward.eligibleNextShow` and nothing else. Revoked or unapproved
/// input is nil, so the session plans music-only talk.
public struct ApprovedShowHandoff: Equatable, Sendable {
    /// True when this show may speak `approved`. Since #332 `LiveQueueBriefing` sets it at any
    /// time of day while the briefing is on (the name predates that).
    public var isMorningShow: Bool
    /// The handoff the listener approved for this morning. Nil if there is none.
    public var approved: NarrationHandoff?
    /// Set when the briefing was revoked or never approved.
    public var revokedOrUnapproved: Bool
    /// Previous show's carry-forward. Used only when `isMorningShow` is false.
    public var carryForward: EditorialCarryForward?
    /// Rows still shown in Connections. A cue is spoken only when the row with the
    /// same id has `state.mayBeNarrated` (that state is `.approved`).
    public var connectionItems: [ConnectionItem]
    /// Prepared cues whose row is approved and whose briefing section is off.
    /// `forQueue()` does not speak them. They are not copied into
    /// `carryForward.eligibleNextShow`, so a calendar event or due task omitted
    /// here cannot roll into a later show.
    public var omittedDisabledSection: [NarrationCue]
    /// Personal updates left out before scheduling (#332): `.dropped(.repeatLimit)` for an
    /// item that already aired today, `.dropped(.windowPassed)` for a row whose `expiresAt`
    /// passed. One entry per omitted update. `forQueue()` never speaks them, and they are not
    /// copied into `carryForward.eligibleNextShow`.
    public var omittedByLimit: NarrationScheduleReport

    public init(isMorningShow: Bool, approved: NarrationHandoff?, revokedOrUnapproved: Bool,
                carryForward: EditorialCarryForward? = nil, connectionItems: [ConnectionItem] = [],
                omittedDisabledSection: [NarrationCue] = [],
                omittedByLimit: NarrationScheduleReport = NarrationScheduleReport(entries: [])) {
        self.isMorningShow = isMorningShow
        self.approved = approved
        self.revokedOrUnapproved = revokedOrUnapproved
        self.carryForward = carryForward
        self.connectionItems = connectionItems
        self.omittedDisabledSection = omittedDisabledSection
        self.omittedByLimit = omittedByLimit
    }

    /// No briefing. `queueStarted` receives nil.
    public static var unapproved: ApprovedShowHandoff {
        ApprovedShowHandoff(isMorningShow: false, approved: nil, revokedOrUnapproved: true)
    }

    /// The handoff argument for `queueStarted`, or nil when nothing may air.
    /// Content cues stay only when their Connections row passes `mayBeNarrated`.
    public func forQueue() -> NarrationHandoff? {
        guard !revokedOrUnapproved else { return nil }
        let candidate: NarrationHandoff?
        if isMorningShow {
            candidate = approved
        } else {
            let cues = carryForward?.eligibleNextShow ?? []
            guard !cues.isEmpty else { return nil }
            candidate = NarrationHandoff(cues: cues,
                                        maxSpokenSeconds: approved?.maxSpokenSeconds ?? 150,
                                        experienceSeconds: approved?.experienceSeconds ?? 300)
        }
        guard let candidate else { return nil }
        return Self.narratable(candidate, items: connectionItems)
    }

    /// Drops every content cue whose Connections row is not `.approved`.
    /// Every other `ConnectionItemState` stays in `connectionItems`.
    /// `ConsentState.notRequested` is not an item state; `resolve` maps it to
    /// `.pendingApproval`, or `.flaggedForReview` when the row is flagged.
    static func narratable(_ handoff: NarrationHandoff, items: [ConnectionItem]) -> NarrationHandoff? {
        let allowed = Set(items.filter { $0.state.mayBeNarrated }.map(\.id))
        let cues = handoff.cues.filter { cue in
            guard let id = cue.sourceItemID else { return true }
            return allowed.contains(id)
        }
        guard cues.contains(where: \.isContent) else { return nil }
        return NarrationHandoff(cues: cues, maxSpokenSeconds: handoff.maxSpokenSeconds,
                                experienceSeconds: handoff.experienceSeconds)
    }
}

extension NarrationScheduleReport {
    /// For a scheduler other than `DJScriptWriter`. Deferred calendar events and
    /// due tasks become `.dropped(.notCarriedForward)`.
    public func withoutRollingTimeSensitiveCuesForward() -> NarrationScheduleReport {
        NarrationScheduleReport(entries: entries.map { entry in
            guard case .deferred = entry.outcome, EditorialCarryForward.isTimeSensitive(entry.cue) else { return entry }
            return NarrationScheduleEntry(cue: entry.cue, outcome: .dropped(.notCarriedForward))
        }, unexpectedSegmentIDs: unexpectedSegmentIDs)
    }
}

/// Beta voice rules. Production audio still comes from `VoiceRenderer.onDeviceDefault()`
/// in the app target (on-device, $0 cap, 7-day cache). This type does not synthesize
/// and does not add a route. Cartesia, Dessa, and ElevenLabs stay named and off.
public enum BetaVoicePolicy {
    public static let paidProvidersEnabled = false
    public static let paidSpendAllowedMicrodollars = 0
    public static let cacheMaxAge: TimeInterval = AudioCacheRetention.maximum
    public static let disabledProviderIDs = ["cartesia", "dessa", "elevenlabs"]

    public static func onDeviceRoute(provider: any VoiceProvider, voice: VoiceProfile) -> VoiceRoute {
        VoiceRoute(providerID: "device", provider: provider, voice: voice, microdollarsPerThousandCharacters: 0)
    }

    /// Empty when the configuration matches beta: no paid route, no disabled provider, $0 cap.
    public static func problems(routes: [VoiceRoute], dailyCapMicrodollars: Int) -> [String] {
        var found: [String] = []
        if paidProvidersEnabled { found.append("paid providers are enabled") }
        if dailyCapMicrodollars != paidSpendAllowedMicrodollars {
            found.append("daily cap is \(dailyCapMicrodollars) microdollars; beta allows \(paidSpendAllowedMicrodollars)")
        }
        if routes.isEmpty { found.append("no voice route") }
        for route in routes {
            if route.isPaid { found.append("paid route \(route.providerID) is configured") }
            if disabledProviderIDs.contains(route.providerID) {
                found.append("disabled provider \(route.providerID) is configured")
            }
        }
        return found
    }
}
