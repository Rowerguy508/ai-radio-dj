import Foundation

// Editorial policy for DJ talk. This does not render audio and does not schedule
// playback. `DJScriptWriter` speaks from these pools; `VoiceRenderer` and
// `DJBreakPreparer` are unchanged.

/// Fixed host lines. Placeholders are filled only from track metadata or the
/// station name. Nothing here claims a genre, a year, a chart position, or weather.
public enum EditorialPhrasing {
    public static let backAnnounce = [
        "That was {title} by {artist}.",
        "{artist} there, with {title}.",
        "You just heard {title} from {artist}.",
        "{title}, from {artist}.",
        "{title} by {artist}.",
        "Just had {title}.",
    ]

    /// Kept at five lines, in this order. `DJNarrationTests` cycles this pool.
    public static let songIntro = [
        "Up next, {nextTitle} by {nextArtist}.",
        "Here's {nextArtist} with {nextTitle}.",
        "Coming up: {nextArtist}, {nextTitle}.",
        "Next, {nextTitle}.",
        "Here's {nextTitle}.",
    ]

    /// Occasional, instead of a plain back-announce. Artist and title only.
    public static let artistFocus = [
        "That was {artist}.",
        "{artist}, with {title}.",
        "From {artist}: {title}.",
        "One from {artist}.",
    ]

    public static let stationID = [
        "You're listening to {station}.",
        "This is {station}.",
        "{station}.",
    ]

    public static let atmosphere: [DayPart: [String]] = [
        .earlyMorning: ["Quiet start.", "The day's just getting going."],
        .morning: ["Hope the morning's going easy.", "A little while before midday."],
        .afternoon: ["Middle of the afternoon.", "The afternoon's moving along."],
        .evening: ["Evening's settling in.", "Winding the day down."],
        .lateNight: ["Late hours.", "Quiet stretch of the night."],
    ]

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

    public init(isMorningShow: Bool, approved: NarrationHandoff?, revokedOrUnapproved: Bool,
                carryForward: EditorialCarryForward? = nil, connectionItems: [ConnectionItem] = [],
                omittedDisabledSection: [NarrationCue] = []) {
        self.isMorningShow = isMorningShow
        self.approved = approved
        self.revokedOrUnapproved = revokedOrUnapproved
        self.carryForward = carryForward
        self.connectionItems = connectionItems
        self.omittedDisabledSection = omittedDisabledSection
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
