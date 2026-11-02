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
/// The style rules every line follows are on `warm`.
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
    /// The show opener's station and mood lines (`DJShowOpener.swift`), after the greeting.
    public var opener: DJOpenerPhrases
    /// One breath that names both songs: "that was X, here's Y" (lane 2's combined shape).
    /// `{title}`/`{artist}` are the song that just played, `{nextTitle}`/`{nextArtist}` the next
    /// one; every line names both. Never `{station}`. Empty: the combined shape falls back to
    /// the closing line.
    public var combined: [String]
    /// Spoken time checks (#347's `timeCheckIntro` shape), one pool per rounding relation, the
    /// same number of templates in each and slot-aligned (slot i of `on`, `comingUp` and
    /// `justAfter` is one phrasing). `{time}` only; one sentence, seven words or fewer, ending in
    /// a period. The time itself always comes from `DJTimeCheck`, never from the copy.
    public var timeChecks: DJTimeCheckPhrases

    public init(backAnnounce: [String], closing: [String], artistFocus: [String], stationID: [String],
                opener: DJOpenerPhrases = .warm,
                atmosphere: [DayPart: [String]], continuation: [String], briefingLead: [String],
                briefingOutro: [String], greetings: [DayPart: [String]], combined: [String] = [],
                timeChecks: DJTimeCheckPhrases = DJTimeCheckPhrases()) {
        self.backAnnounce = backAnnounce
        self.closing = closing
        self.artistFocus = artistFocus
        self.stationID = stationID
        self.opener = opener
        self.atmosphere = atmosphere
        self.continuation = continuation
        self.briefingLead = briefingLead
        self.briefingOutro = briefingOutro
        self.greetings = greetings
        self.combined = combined
        self.timeChecks = timeChecks
    }

    /// Default: warm and conversational, in the house style below.
    ///
    /// House style (the contract `SpokenScriptLintTests` enforces on every rendered line):
    /// - Sound like a radio host, not an assistant. Contractions always. Short spoken sentences
    ///   (12 words at most), fragments welcome ("{artist}. {title}.").
    /// - Talk up the intro: the closing line is one sentence of seven words or fewer.
    /// - No assistant phrasing ("Here is", "Let me", "I hope you enjoy", "As an AI"), no
    ///   list-speak ("First", "Additionally", "Here are"), no hype (`forbiddenHype`).
    /// - Plain text only: no markdown, emoji, URLs, tags or leftover braces. Titles are spoken
    ///   through `SpokenTitle`, so catalog suffixes never reach a voice.
    /// - No facts of our own: no genres, years, chart claims, weather, or clock times.
    /// - Casual, like a DJ hanging out with a friend (build 34 owner note): no announcer
    ///   boilerplate or spelled-out forms ("Welcome to", "it is", "you are"), and contractions in
    ///   at least half of the regular-break lines (`WarmCasualCopyTests`). Slots stay put.
    public static let warm = EditorialTone(
        backAnnounce: [
            "So that's {title} from {artist}.",
            "{artist} there. That's {title}.",
            "That's {artist}, with {title}.",
            "{artist}. {title}.",
            "There you go, {title} from {artist}.",
            "That one's {title}, by {artist}.",
            "That's {artist} you just heard. {title}.",
            "Okay, that's {title}. {artist}.",
            "Just had {artist} on. {title}.",
            "{title}. That's {artist}, by the way.",
        ],
        // Ten lines, one sentence each, at most seven words, so it fits `DJCadence.maxClosingSeconds`
        // and lands before the vocal. Every line names the next title. `DJNarrationTests` and
        // `RadioStyleBreakTests` cycle this pool, so its size is a multiple of five.
        closing: [
            "Let's hear {nextTitle} by {nextArtist}.",
            "Here's one from {nextArtist}, {nextTitle}.",
            "We're going with {nextArtist}, {nextTitle}.",
            "And this one's {nextTitle}.",
            "Now we've got {nextArtist}, {nextTitle}.",
            "Alright, {nextTitle} from {nextArtist}.",
            "Here comes {nextTitle}.",
            "Here's {nextArtist} now, {nextTitle}.",
            "Got {nextTitle} for you now.",
            "Next up, it's {nextTitle}.",
        ],
        artistFocus: [
            "That's {artist}, if you were wondering.",
            "Yep, {artist}. That's {title}.",
            "A little {artist} for you.",
            "There's {artist} for you. {title}.",
            "Yeah, that's {artist}.",
            "{artist}, right there.",
            "Got one from {artist} there.",
            "Bit of {artist} there.",
        ],
        stationID: [
            "{station}. Stick around a while.",
            "You're on {station}.",
            "Still hanging out on {station}.",
            "You've got {station} on.",
            "{station}. Good to have you.",
            "It's {station}, just so you know.",
            "{station}'s got you covered.",
            "Right here on {station}.",
        ],
        opener: .warm,
        atmosphere: [
            .earlyMorning: ["Quiet start. No rush at all.", "Early one, huh? We'll take it slow.",
                            "It's still pretty early out there.", "Day's just getting going."],
            .morning: ["It's a nice steady morning.", "Morning's rolling along.", "Take your time, there's no rush.",
                       "We'll keep the morning moving."],
            .afternoon: ["Ah, the afternoon stretch.", "Afternoon's cruising along.", "We'll keep the afternoon going.",
                         "It's the afternoon. Keep it easy."],
            .evening: ["Evening's settling in.", "We're winding down now. No rush.", "Kick back, it's evening.",
                       "Evening. Go ahead and take a breath."],
            .lateNight: ["It's late. Quiet stretch now.", "Still up? Glad you're here.", "Night owls, this one's yours.",
                         "Late one. We'll keep it low."],
        ],
        continuation: [
            "There's more on the way.",
            "Stay right there.",
            "We'll keep it rolling.",
            "Thanks for hanging out.",
            "Okay, let's keep going.",
            "We've got plenty more.",
            "Don't go anywhere.",
            "Lots more music ahead.",
        ],
        briefingLead: [
            "Quick heads-up before the next one.",
            "A couple of things before the next song.",
            "While we're between songs.",
            "Quick one before the next song.",
            "Real quick, before the music.",
            "Before we keep going.",
            "One sec before the next one.",
            "Something for your day.",
        ],
        briefingOutro: [
            "That's it for now.",
            "Okay — back to the music.",
            "That's all from me.",
            "Alright, more music.",
            "That's the rundown.",
            "Done. Back to the tunes.",
            "Back to the music.",
            "Okay, on we go.",
        ],
        greetings: [
            .earlyMorning: ["Early start today.", "Morning, early riser.", "Up early? Good."],
            .morning: ["Good morning.", "Morning — let's ease into it.", "Hey, good morning."],
            .afternoon: ["Good afternoon.", "Afternoon. Pull up a chair.", "Hey there, good afternoon."],
            .evening: ["Good evening.", "Evening. Glad you found us.", "Hey, good evening."],
            .lateNight: ["Late one tonight.", "Still up? Good.", "Hey, night owl."],
        ],
        combined: [
            "That was {title}. Now here's {nextTitle}.",
            "{artist} there. Now let's hear {nextArtist}.",
            "That's {title}. We'll go to {nextTitle} next.",
            "{title}, from {artist}. Next it's {nextTitle}.",
            "Okay, that's {artist}. Here comes {nextArtist}.",
            "{artist}, {title}. And this one's {nextArtist}.",
            "We're going from {artist} to {nextArtist}.",
            "{title} there. Up next, it's {nextArtist}.",
        ],
        // Fry's #347 copy, verbatim: `DJTimeCheckPhrases`' defaults are warm's bank.
        timeChecks: DJTimeCheckPhrases()
    )

    /// Brighter and forward-selling, still in the house style: no hype words, no claims about the
    /// music, and every lint rule on `warm` applies.
    public static let upbeat = EditorialTone(
        backAnnounce: [
            "Straight from {artist}, that's {title}.",
            "There it is — {title}, from {artist}.",
            "{artist} with {title}. Good one.",
            "Nice. That's {title} from {artist}.",
            "That's been {artist}, with {title}.",
            "{title} from {artist}, right there.",
            "{artist}, everybody. That was {title}.",
            "{artist} just now. That's {title}.",
            "You just caught {title} from {artist}.",
            "Yes — {title}, {artist}.",
        ],
        closing: [
            "Here comes {nextArtist} with {nextTitle}.",
            "Let's go — {nextTitle}, {nextArtist}.",
            "Up next, {nextArtist} with {nextTitle}.",
            "Turn it up for {nextTitle}.",
            "Rolling right into {nextTitle}.",
            "Straight into {nextTitle} from {nextArtist}.",
            "Now it's {nextArtist}, {nextTitle}.",
            "Keep it going with {nextTitle}.",
            "This one's {nextTitle}, from {nextArtist}.",
            "Here we go, it's {nextTitle}.",
        ],
        artistFocus: [
            "There's {artist} for you.",
            "Can't go wrong with {artist}.",
            "That's {artist}. {title}.",
            "More {artist}, anytime.",
            "{artist} — {title}. Nice.",
            "Some {artist} to keep it moving.",
            "That was all {artist}.",
            "Here's to {artist}. That was {title}.",
        ],
        stationID: [
            "{station}. Keep it here.",
            "You've got {station}.",
            "Stay with {station}.",
            "Locked in on {station}.",
            "{station}. Let's keep going.",
            "It's {station}, and we're rolling.",
            "Right where you should be, {station}.",
            "This is {station}. Here we go.",
        ],
        opener: .upbeat,
        atmosphere: [
            .earlyMorning: ["Early start. Let's get moving.", "Up and at it.", "Fresh start out there.",
                            "Early crew, this one's for you."],
            .morning: ["Morning's in motion.", "Good morning energy.", "Let's get this morning going.",
                       "Morning's picking up."],
            .afternoon: ["Afternoon's rolling.", "Afternoon pick-me-up.", "Let's keep the afternoon up.",
                         "Afternoon run, here we go."],
            .evening: ["Evening's on.", "Evening, and we're still rolling.", "Into the evening we go.",
                       "Evening lift, right here."],
            .lateNight: ["Late, but we're still going.", "Night crew, keep it up.", "Late one, still moving.",
                         "Night owls, stay with it."],
        ],
        continuation: [
            "Lots more where that came from.",
            "Keep it right here.",
            "We're on a roll.",
            "Plenty more on the way.",
            "Stick with me.",
            "Don't touch that dial.",
            "Okay, onward.",
            "More coming your way.",
        ],
        briefingLead: [
            "Quick update, then more music.",
            "Couple of things for you.",
            "Real quick before the next one.",
            "Heads-up time.",
            "Here's what's up.",
            "Fast one before we roll on.",
            "Let's catch you up quick.",
            "Quick check-in.",
        ],
        briefingOutro: [
            "That's the update. Let's roll.",
            "Done — back to it.",
            "Alright, music's back.",
            "That's all for now. Here we go.",
            "Okay, back to the good stuff.",
            "And we're back to the music.",
            "That's that. On we go.",
            "Wrapped. Let's keep rolling.",
        ],
        greetings: [
            .earlyMorning: ["Morning, early crew.", "Up early? Let's do this.", "Early start — let's get rolling."],
            .morning: ["Good morning, let's go.", "Hey, morning. Let's get into it.", "Morning, everybody."],
            .afternoon: ["Hey there, afternoon crew.", "Good afternoon — let's pick it up.", "Afternoon, everybody."],
            .evening: ["Evening, all.", "Hey, good evening. Let's roll.", "Evening — glad you're in."],
            .lateNight: ["Hey, late crew.", "Night owls, let's go.", "Still up? Let's keep it going."],
        ],
        combined: [
            "{title} from {artist}. Now let's go, {nextTitle}.",
            "That's {artist}. Straight on to {nextArtist}.",
            "{artist} done, {nextArtist} up. Let's roll.",
            "Out with {title}, in with {nextTitle}.",
            "{title}, nice. Up next, {nextArtist}.",
            "Keep it moving — {artist}, then {nextArtist}.",
            "From {artist} to {nextArtist}, no stopping.",
            "Here's {nextTitle}, right after {title}.",
            "{artist} with {title}. Rolling on, {nextTitle}.",
            "That was {title}. Let's hit {nextTitle}.",
        ],
        timeChecks: DJTimeCheckPhrases(
            on: ["It's {time} right now.", "Quick time check, it's {time}.", "Clock says {time}."],
            comingUp: ["Coming right up on {time}.", "Quick time check, almost {time}.", "Clock says nearly {time}."],
            justAfter: ["Just past {time} right now.", "Quick time check, just past {time}.", "Clock says just after {time}."]
        )
    )

    /// Soft and easy: slower words, no rush. Same contract as `warm`; mood only, no claims
    /// about a song's tempo or sound.
    public static let laidBack = EditorialTone(
        backAnnounce: [
            "That was {title}, by {artist}.",
            "Easy one from {artist}. {title}.",
            "{artist} there, with {title}.",
            "Just heard {title}. That's {artist}.",
            "A little {title} from {artist}.",
            "That's {artist}. {title}, just there.",
            "{title}. {artist}. Nice.",
            "Hope that one sat well. {title}, {artist}.",
            "There was {artist}, with {title}.",
            "{artist}, with {title}. Lovely.",
        ],
        closing: [
            "And now, it's {nextTitle}.",
            "Easing into {nextTitle}.",
            "Over to {nextArtist}, {nextTitle}.",
            "Let's slip into {nextTitle}.",
            "Something from {nextArtist} now, {nextTitle}.",
            "Let's settle into {nextTitle}.",
            "Now a little {nextArtist}, {nextTitle}.",
            "This is {nextTitle}, from {nextArtist}.",
            "Let's have {nextTitle} next.",
            "Up now, {nextArtist} and {nextTitle}.",
        ],
        artistFocus: [
            "{artist}. Good company.",
            "That's {artist}. Lovely.",
            "A little moment with {artist}.",
            "Just {artist}, and {title}.",
            "That one's {artist}.",
            "{artist}, there. {title}.",
            "Some {artist} to sit with.",
            "Nice one from {artist}.",
        ],
        stationID: [
            "{station}. Stay a while.",
            "You're with {station}.",
            "{station}, nice and easy.",
            "It's {station}. No rush.",
            "Just {station}, and you.",
            "Hanging out on {station}.",
            "{station}. Make yourself at home.",
            "This is {station}. Take your time.",
        ],
        opener: .laidBack,
        atmosphere: [
            .earlyMorning: ["Soft start this morning.", "Early and easy.", "Slow start, nothing to chase.",
                            "Early hours. Breathe easy."],
            .morning: ["It's a gentle morning.", "Morning, at your own pace.", "No hurry this morning.",
                       "Easy morning stretch."],
            .afternoon: ["Slow afternoon.", "Afternoon, taking it easy.", "Let the afternoon drift.",
                         "Lazy afternoon stretch."],
            .evening: ["Soft evening.", "Evening. Feet up.", "It's an easy evening.", "Let the evening unwind."],
            .lateNight: ["Quiet hours now.", "Late and low.", "Night's slow and easy.",
                         "Just us and the late hours."],
        ],
        continuation: [
            "No hurry. More soon.",
            "Stay as long as you like.",
            "We'll keep it easy.",
            "Plenty more, no rush.",
            "Just sit back. We've got you.",
            "Kick back. There's more.",
            "Right here with you.",
            "We're not going anywhere.",
        ],
        briefingLead: [
            "A couple of quiet things before the next one.",
            "Just a few things, then more music.",
            "Gentle heads-up before the next song.",
            "While we've got a moment.",
            "I've got a few things for you.",
            "Before the next one, real easy.",
            "Quick, quiet word.",
            "Let's take a sec before the music.",
        ],
        briefingOutro: [
            "That's everything. Easy now.",
            "Okay, back to the songs.",
            "And that's it. Settle back in.",
            "Alright, that's all for now.",
            "Nothing else. Back to it.",
            "There we go. Here's more music.",
            "That's the lot.",
            "Okay. Easing back into the music.",
        ],
        greetings: [
            .earlyMorning: ["Morning. Take it slow.", "Early one, huh? Easy now.", "Hey there. Quiet start."],
            .morning: ["Morning. No rush.", "Hi there, good morning.", "Morning. Make yourself comfy."],
            .afternoon: ["Hey, afternoon. Kick back.", "Afternoon, friend.", "Hi there. Easy afternoon."],
            .evening: ["Evening, friend.", "Hey there, good evening.", "Evening. Get comfy."],
            .lateNight: ["Hey, still awake?", "Late one. Hi there.", "Night owl? Get cozy."],
        ],
        combined: [
            "That was {title}. Now let's drift into {nextTitle}.",
            "{artist} there. We'll slide over to {nextArtist}.",
            "That's {title}. Here's {nextTitle}, no rush.",
            "{title}, from {artist}. Now we'll take {nextTitle}.",
            "That's been {artist}. Next, a little {nextArtist}.",
            "Easy now. {title} there, {nextTitle} next.",
            "There's {artist}. We'll let {nextArtist} take it from here.",
            "{title} just went by. Now it's {nextTitle}.",
            "So that's {artist}. Let's hang with {nextArtist}.",
            "{artist}, {title}. And now, {nextTitle}. Easy.",
        ],
        timeChecks: DJTimeCheckPhrases(
            on: ["It's {time} now.", "For the record, it's {time}.", "Clock reads {time}."],
            comingUp: ["Creeping up on {time}.", "For the record, almost {time}.", "Clock reads nearly {time}."],
            justAfter: ["A touch past {time}.", "For the record, just past {time}.", "Clock reads just after {time}."]
        )
    )

    /// Names, mostly. Short, flat and informational: "{artist}. {title}." Pairs with
    /// `DJPersonality.minimal`'s 6 s main-segment cap.
    public static let minimal = EditorialTone(
        backAnnounce: [
            "{title}. {artist}.",
            "{artist}, {title}.",
            "{title}, {artist}.",
            "That's {title}.",
            "{title}, from {artist}.",
            "{artist} — {title}.",
            "That's {artist}, {title}.",
            "{title}. That was {artist}.",
            "{artist}. That's {title}.",
            "{title} — {artist}.",
        ],
        closing: [
            "{nextTitle}.",
            "{nextArtist}, {nextTitle}.",
            "{nextTitle}, {nextArtist}.",
            "Now, {nextTitle}.",
            "Next, {nextTitle}.",
            "Here's {nextTitle}.",
            "It's {nextTitle}.",
            "{nextArtist} now, {nextTitle}.",
            "Now, {nextArtist} — {nextTitle}.",
            "This is {nextTitle}.",
        ],
        artistFocus: [
            "{artist}.",
            "{artist}, there.",
            "Just {artist}.",
            "That's been {artist}.",
            "{artist}'s {title}.",
            "{artist}, just now.",
            "That's {artist} for you.",
            "{artist} with {title}.",
        ],
        stationID: [
            "{station}.",
            "On {station}.",
            "{station}, here.",
            "Still {station}.",
            "{station}, on air.",
            "That's {station}.",
            "We're {station}.",
            "{station}. Stay put.",
        ],
        opener: .minimal,
        atmosphere: [
            .earlyMorning: ["Early.", "Early start.", "Quiet, early.", "Early hours."],
            .morning: ["Morning.", "Morning, steady.", "Morning set.", "Morning's going."],
            .afternoon: ["Afternoon.", "Afternoon set.", "Steady afternoon.", "Afternoon's going."],
            .evening: ["Evening.", "Evening set.", "Quiet evening.", "Evening's in."],
            .lateNight: ["Late.", "Late hours.", "Late and quiet.", "Night's in."],
        ],
        continuation: [
            "More soon.",
            "There's more.",
            "Don't go far.",
            "Back to it.",
            "On we go.",
            "Still going.",
            "We'll keep going.",
            "More music next.",
        ],
        briefingLead: [
            "A few things.",
            "Quick update.",
            "Before the next one.",
            "Here's what's new.",
            "Couple of things.",
            "Here's the rundown.",
            "One sec.",
            "Quick heads-up.",
        ],
        briefingOutro: [
            "That's it.",
            "Done.",
            "Back to music.",
            "That's all.",
            "Okay. Music.",
            "On with it.",
            "That's everything.",
            "Music's back.",
        ],
        greetings: [
            .earlyMorning: ["Morning, early.", "Hi. Early one.", "It's early. Hi."],
            .morning: ["Morning, all.", "Hi there. Morning.", "Hey. Morning."],
            .afternoon: ["Afternoon, all.", "Hi there. Afternoon.", "Hey. Afternoon."],
            .evening: ["Evening, all.", "Hi there. Evening.", "Hey. Evening."],
            .lateNight: ["Hi. Late one.", "Hey there. Late hours.", "You're up late. Hi."],
        ],
        combined: [
            "{title}. {nextTitle}.",
            "{artist}, then {nextArtist}.",
            "That's {title}. Now, {nextTitle}.",
            "{title}, {artist}. Next, {nextTitle}.",
            "{artist}. Now {nextArtist}.",
            "{title} there. {nextTitle} now.",
            "{artist} out. {nextArtist} in.",
            "{title}. Up next, {nextArtist}.",
            "That was {artist}. This is {nextArtist}.",
            "Here's {nextTitle}, after {title}.",
        ],
        timeChecks: DJTimeCheckPhrases(
            on: ["It's {time}.", "Time check, {time}.", "The time, {time}."],
            comingUp: ["Almost {time}.", "Time check, almost {time}.", "The time, nearly {time}."],
            justAfter: ["Just past {time}.", "Time check, just past {time}.", "The time, just after {time}."]
        )
    )

    /// The phrasing bank for a station's existing `DJPersonality` (lane 4, docs/dj-persona.md).
    /// The persona changes what is said, never the facts, the voice, the scheduler or the caps.
    public static func forPersonality(_ personality: DJPersonality) -> EditorialTone {
        switch personality {
        case .warm: return .warm
        case .upbeat: return .upbeat
        case .laidBack: return .laidBack
        case .minimal: return .minimal
        }
    }

    /// Every line in every pool (for scans in tests).
    public var allLines: [String] {
        backAnnounce + closing + artistFocus + stationID + continuation + briefingLead + briefingOutro
            + atmosphere.values.flatMap { $0 } + greetings.values.flatMap { $0 } + combined
    }

    /// Every time-check template, all relations (for scans in tests). Not in `allLines`: these
    /// are the one place a line says a clock time, so the no-clock-times scans skip them.
    public var allTimeCheckLines: [String] {
        DJTimeCheckRelation.allCases.flatMap { timeChecks.templates(for: $0) }
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
