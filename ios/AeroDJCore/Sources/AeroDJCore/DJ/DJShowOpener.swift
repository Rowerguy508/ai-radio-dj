import Foundation

// The show opener (build 34): the first DJ break of a session sets the stage. It welcomes the
// listener with the day-part greeting, names the real station, sets the mood, gives the time when
// the time-check rules allow it, and talks up the first song. It is planned by `DJScriptWriter`
// (natural shapes on), rendered by the same `DJBreakPreparer` and `VoiceRenderer` as every other
// break, and capped by `DJCadence.maxOpenerBreakSeconds` (22 s) instead of the 12 s ordinary cap.
//
// Copy rules (house style, `SpokenScriptLintTests`): casual, like a DJ hanging out with a friend.
// Sentences of 12 words at most, contractions, no announcer boilerplate ("Welcome to...", "you are
// listening to", "ladies and gentlemen"), no facts of our own. `station` lines carry `{station}`
// and nothing else; `setup` lines are mood only (no clock claims, no numbers, no weather). The
// time is never in this copy: it comes from the time-check machinery (`DJPlannedTimeCheck`,
// re-read at render time, #347 drops).

/// One persona's opener copy.
public struct DJOpenerPhrases: Equatable, Sendable {
    /// Names the station. Each line has `{station}` (the real station name) and no other slot.
    public var station: [String]
    /// Sets the mood for the session, by day part. Fact-free presenter lines.
    public var setup: [DayPart: [String]]

    public init(station: [String], setup: [DayPart: [String]]) {
        self.station = station
        self.setup = setup
    }

    /// Every opener line (for scans in tests).
    public var allLines: [String] { station + DayPart.allCases.flatMap { setup[$0, default: []] } }

    /// Warm: the default persona. Casual, like hanging out with a friend (build 34 owner note).
    public static let warm = DJOpenerPhrases(
        station: [
            "You're on {station}. Glad you stopped by.",
            "It's {station}, and you're in good company.",
            "You found {station}. Make yourself at home.",
            "This is {station}. Sit back, we've got a good one going.",
            "You're hanging out with {station} now.",
        ],
        setup: [
            .earlyMorning: ["No rush this early. Let the music do the work.",
                            "Day's barely started. We'll take it one song at a time.",
                            "Quiet start, so we'll keep it gentle for a bit."],
            .morning: ["Let's get the morning going with some good music.",
                       "Grab a coffee if you've got one. Songs are lined up.",
                       "Whatever the morning's got, the music's covered."],
            .afternoon: ["Let's keep the afternoon rolling, one song at a time.",
                         "Take a breather. We've got the music.",
                         "Kick back for a bit. We'll handle the tunes."],
            .evening: ["Time to unwind. We'll keep it easy from here.",
                       "Put your feet up and let the evening play out.",
                       "Evening's here. Let's make it a good one."],
            .lateNight: ["It's late, so we'll keep it low and easy.",
                         "Night owls, we'll keep you company for a while.",
                         "World's gone quiet. Stick around, the music's on us."],
        ])

    /// Upbeat: high energy, still casual and no hype words.
    public static let upbeat = DJOpenerPhrases(
        station: [
            "Hey hey, it's {station}.",
            "You're locked into {station}. Let's go.",
            "It's {station}, and we're kicking things off.",
            "{station}'s on, and so are you.",
            "Turn it up, it's {station}.",
        ],
        setup: [
            .earlyMorning: ["Early start, so let's wake things up a little.",
                            "Rise and shine. We've got songs to get you moving.",
                            "Let's kick the day off right, one track at a time."],
            .morning: ["Let's give this morning a soundtrack.",
                       "We're starting strong and keeping the music coming.",
                       "Let's get this morning moving. Plenty of music on deck."],
            .afternoon: ["Afternoon slump? Not here. Let's keep it moving.",
                         "Let's lift the afternoon with a run of songs.",
                         "Let's power through the afternoon together."],
            .evening: ["Evening's here, and the music's just getting going.",
                       "Let's light up the evening with a good run.",
                       "Long day? Let's turn it around with some music."],
            .lateNight: ["Night's still young here. Let's keep the energy up.",
                         "Still going strong. Let's ride the night out.",
                         "We're up late together. Let's keep it rolling."],
        ])

    /// Laid-back: slow, unhurried.
    public static let laidBack = DJOpenerPhrases(
        station: [
            "You're with {station} now. Nowhere to be.",
            "It's {station}. Nice and slow from here.",
            "Settle in, you're on {station}.",
            "Hey, it's {station}. Take a load off.",
            "You drifted over to {station}. Glad you did.",
        ],
        setup: [
            .earlyMorning: ["Nice and slow this morning. We'll wake up together.",
                            "Let the day start gently. The music's here.",
                            "Early hours are for taking it easy. Stay a while."],
            .morning: ["Slow morning, no pressure. Let the songs keep you company.",
                       "Pour something warm and let the music roll.",
                       "No plans needed. We'll keep the tunes gentle."],
            .afternoon: ["Let the afternoon slow down a little. We've got the music.",
                         "Feet up if you can. We'll keep it mellow.",
                         "No hurry today. Just let it play."],
            .evening: ["Let the day go. The evening's for slowing down.",
                       "Dim the lights if you like. We'll keep it soft.",
                       "The evening's yours. Nothing to do but listen."],
            .lateNight: ["Late and quiet. We'll keep it soft and low.",
                         "The night's gone still. Let's keep it that way.",
                         "Just a few of us up now. Get cozy."],
        ])

    /// Minimal: casual and brief, not formal. Still the longest break of the session.
    public static let minimal = DJOpenerPhrases(
        station: [
            "Now on {station}.",
            "Tuned in. {station}.",
            "{station}. Glad you came.",
            "{station}'s on.",
        ],
        setup: [
            .earlyMorning: ["Early. Music's on.", "Quiet start. Less talk.", "Early hours. Easy music."],
            .morning: ["Morning. Music's on.", "Steady music from here.", "Less talk, more music."],
            .afternoon: ["Afternoon. Music's on.", "Easy afternoon music.", "Music first. Less talk."],
            .evening: ["Evening. Music's on.", "Quiet evening music.", "Music first. Talk later."],
            .lateNight: ["Late. Music's on.", "Low and easy, late.", "Night music. Less talk."],
        ])
}

/// Why the opener planned no time check. Reported in `OrdinaryBreakCapReport.omittedOpenerTimeChecks`;
/// render-time drops (stale, late, over cap) use #347's `DJTimeCheckDrop` as for any time check.
public enum DJOpenerTimeCheckOmission: String, Equatable, Sendable, CaseIterable {
    /// The caller gave no planning clock, so there is no true time to speak.
    case noClock
    /// The boundary's known air time is too far from the planning clock.
    case airTimeDrift
    /// Another time check is planned or aired within `timeCheckMinSpacingSeconds`.
    case spacing
    /// No time-check phrasing for the reading (`DJBreakShapeConfig.timeChecks` empty).
    case noPhrasing
    /// The line would not fit the opener cap or the cue limit.
    case overCap
}
