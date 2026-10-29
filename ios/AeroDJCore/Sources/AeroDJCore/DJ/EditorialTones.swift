import Foundation

// Selectable DJ tones (Echo, build 27). Same rules as `EditorialTone.warm`: placeholders come
// only from track metadata or the station display name, no facts, no hype, no exclamations,
// greetings and color name only their own day part, closing lines fit 4 s and every line that
// is not tied to a day part reads right at any hour. Naturalness: UNVERIFIED (not listened to).

public extension EditorialTone {
    /// Classic radio host: brisk and friendly, "stick around" energy, never overexcited.
    static let classic = EditorialTone(
        backAnnounce: [
            "That's {artist}, with {title}.",
            "There it is — {title}, from {artist}.",
            "Coming off {title}, from {artist}.",
            "{artist}, {title} — good stuff.",
            "You've been listening to {title}, from {artist}.",
            "Just played: {title}, from {artist}.",
            "{title} — {artist} with that one.",
            "Hope you caught that one — {title}, from {artist}.",
            "{artist} with {title}, right there.",
            "And that was {title}.",
        ],
        // One sentence, at most three words besides the names; every line names {nextTitle}.
        closing: [
            "Right now: {nextArtist}, {nextTitle}.",
            "Now it's {nextArtist}, {nextTitle}.",
            "This is {nextTitle}, from {nextArtist}.",
            "Up now, {nextTitle}.",
            "Coming right up, {nextTitle}.",
            "And here's {nextTitle}.",
            "Next, {nextArtist} — {nextTitle}.",
            "Rolling on with {nextTitle}.",
        ],
        artistFocus: [
            "That's {artist} for you.",
            "{artist} — {title}.",
            "A little {artist} for you there.",
            "There's {artist}, and {title}.",
        ],
        stationID: [
            "This is {station} — your music, all day long.",
            "{station}, good to have you with us.",
            "You're locked in to {station}.",
            "Stick with {station} — plenty more coming.",
            "{station} — keeping it rolling.",
            "It's {station}, and you're in the right place.",
        ],
        atmosphere: [
            .earlyMorning: ["Up and at it early — let's get going.", "Early hours, easy start.",
                            "Getting the day started right here."],
            .morning: ["The morning's rolling along.", "Good time to get things moving.",
                       "Here's some music for your morning."],
            .afternoon: ["Afternoon's in full swing.", "Keeping the afternoon moving.",
                         "Right through the afternoon with you."],
            .evening: ["Evening's here — let's keep it going.", "Into the evening we go.",
                       "Good to have company this evening."],
            .lateNight: ["Still going strong this late.", "Late hours, and the music keeps going.",
                         "Night owls, you're in good hands."],
        ],
        continuation: [
            "Good to have you with us.",
            "We've got a whole lot more music on the way — so don't go anywhere.",
            "Stick around, there's more right behind this one.",
            "Lots more coming up.",
            "Stay right there.",
        ],
        briefingLead: [
            "Before we keep it rolling, here's what's on your plate.",
            "Real quick, before the next one.",
            "A few things for you.",
        ],
        briefingOutro: [
            "Alright — back to the music.",
            "That's the rundown.",
            "Okay, let's get back to it.",
        ],
        greetings: [
            .earlyMorning: ["Morning, early birds.", "Good morning — early start, let's go.", "Rise and shine."],
            .morning: ["Good morning, good to have you.", "Hey, good morning.", "Morning, and welcome aboard."],
            .afternoon: ["Hey, good afternoon.", "Afternoon, and welcome aboard.", "Good afternoon — let's get into it."],
            .evening: ["Hey, good evening.", "Evening, and welcome aboard.", "Good evening — let's get into it."],
            .lateNight: ["Hey, night owl — welcome aboard.", "Late one, and welcome aboard.",
                         "Good to have you this late."],
        ]
    )

    /// Late-night host: low, unhurried, few words. The name is the voice, not the hour: only the
    /// day-part pools mention the time, so it reads right in the morning too.
    static let lateNight = EditorialTone(
        backAnnounce: [
            "That was {artist}… {title}.",
            "{title}, from {artist}. Nice and easy.",
            "That's {title}, by {artist}.",
            "{artist} there… {title}.",
            "Easing out of {title}, from {artist}.",
            "That one was {artist} — {title}.",
            "Just heard {title}, from {artist}.",
            "{title}, from {artist}. Let that one sit for a second.",
            "And that was {title}… {artist}.",
            "Back from {title}, by {artist}.",
        ],
        // One sentence, at most three words besides the names; every line names {nextTitle}.
        closing: [
            "Here's {nextArtist}, {nextTitle}.",
            "Next, {nextTitle}.",
            "Let's ease into {nextTitle}.",
            "Now — {nextTitle}, from {nextArtist}.",
            "Over to {nextArtist}, {nextTitle}.",
            "Here's {nextTitle}, by {nextArtist}.",
            "Something from {nextArtist} — {nextTitle}.",
            "Into {nextTitle}.",
        ],
        artistFocus: [
            "That's {artist}.",
            "Some {artist} for you.",
            "{artist}, and {title}.",
            "A little {artist}.",
        ],
        stationID: [
            "You're with {station} — glad you're here.",
            "{station}, keeping it easy.",
            "This is {station} — no rush.",
            "Settle in — this is {station}.",
            "{station}, right here with you.",
            "Still {station}, still taking it slow.",
        ],
        atmosphere: [
            .earlyMorning: ["Early, quiet, no hurry.", "Slow start — that's fine.", "The day can wait a minute."],
            .morning: ["Slow morning — that's alright.", "Taking the morning easy.", "No rush this morning."],
            .afternoon: ["Easing through the afternoon.", "A quiet bit of the afternoon.",
                         "The afternoon can take its time."],
            .evening: ["Evening now — let it slow down.", "Easing into the evening.",
                       "The evening's taking its time."],
            .lateNight: ["Deep in the night now — no hurry.", "Keep it low — it's late.", "Quiet hours. Settle in."],
        ],
        continuation: [
            "Settle in, keep it low, and let the music do the talking.",
            "No rush — we'll keep it easy.",
            "Stay a while.",
            "We're in no hurry.",
            "Nothing to do but listen.",
        ],
        briefingLead: [
            "One thing before the next song.",
            "Just a couple of things.",
            "Quietly, before we go on.",
        ],
        briefingOutro: [
            "That's all from me — back to the quiet.",
            "Back to the music, nice and slow.",
            "That's it. Settle back in.",
        ],
        greetings: [
            .earlyMorning: ["Morning. Take it easy.", "Hey — early one, huh.", "A quiet good morning to you."],
            .morning: ["Morning. No rush.", "Good morning — take your time.", "Hi, and good morning."],
            .afternoon: ["Afternoon. Slow and steady.", "Hi, and good afternoon.", "Afternoon — settle in."],
            .evening: ["Evening. Settle in.", "Hi, and good evening.", "Good evening — no rush."],
            .lateNight: ["Hey, night owl.", "Late, huh? Settle in.", "Hi — keeping it quiet tonight."],
        ]
    )
}

public extension DJPersonality {
    /// The words a break uses for this personality (Echo, build 27). Warm is the default.
    /// Minimal keeps warm's words; its shorter break cap (`maxTransitionSeconds`) is the difference.
    /// Read only through `DJScriptWriter`'s tone: no other scheduler or renderer looks at it.
    var editorialTone: EditorialTone {
        switch self {
        case .warm, .minimal: .warm
        case .upbeat: .classic
        case .laidBack: .lateNight
        }
    }
}
