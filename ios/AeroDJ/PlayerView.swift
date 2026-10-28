import SwiftUI
import AeroDJCore

/// Player shell. MusicKit playback is managed by the framework; this view
/// reflects state and forwards user actions. No protected-stream mixing.
///
/// The UI is `PlayingScreen` (Listen on the closed Duo, the two-zone Studio when open). It
/// binds to the app-scoped session's `snapshot`, `studio` (tuner, Connections, DJ state)
/// and real actions. The session speech-stop hook is armed in `AppDependencies`, not here.
/// Playback callbacks are bound once on the split root (`PlaybackSessionBinder`), not on
/// this pane, so a fold or rotation cannot run them again.
struct PlayerView: View {
    let station: Station
    /// The app-scoped `MusicKitService.shared`. Observed, not owned and not wrapped in `StateObject`.
    @ObservedObject private var music: MusicKitService
    @ObservedObject private var interlude: InterludePlaybackAdapter
    let djSession: DJBreakSession
    let studio: StudioPresentationModel
    let isTestStation: Bool

    /// `music` and `interlude` are the app-scoped players from `AppDependencies`. Never new ones.
    init(station: Station, music: MusicKitService, interlude: InterludePlaybackAdapter,
         djSession: DJBreakSession, studio: StudioPresentationModel, isTestStation: Bool) {
        precondition(music === MusicKitService.shared, "MusicKitService.shared is the only player")
        self.station = station
        self.music = music
        self.djSession = djSession
        self.studio = studio
        self.isTestStation = isTestStation
        self.interlude = interlude
    }

    var body: some View {
        PlayingScreen(station: stationRef,
                      access: access,
                      snapshot: music.snapshot,
                      actions: .live(music),
                      search: .live(music, station: stationRef, djSession: djSession, briefing: LiveQueueBriefing.provider(studio: studio)),
                      studio: studio,
                      isTestStation: isTestStation,
                      timeSource: .live)
        #if AERODJ_P0_DIAG
        .safeAreaInset(edge: .bottom) { P0EventTracePanel().frame(height: 450).padding(.horizontal, 8) }
        #endif
        .navigationTitle(station.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        // Fry #110: Tune Save/Discard waits on real transport. Callbacks + auth refresh stay
        // on PlaybackSessionBinder (once-only); do not authorize() here.
        .task { await reportPlaybackActivity(music.snapshot) }
        .onChange(of: music.snapshot) { _, snap in
            Task { await reportPlaybackActivity(snap) }
        }
    }

    /// Real transport only (not a UI playing flag). `.stopped` → idle apply; playing,
    /// paused mid-song (incl. system hold), and unknown future cases (e.g. `.preparing`
    /// from Atlas #109) → holding so Save stays pending. See `StationPlaybackActivity.init(transport:)`.
    private func reportPlaybackActivity(_ snap: PlaybackSnapshot) async {
        await studio.station.setPlaybackActivity(StationPlaybackActivity(transport: snap.transport))
    }

    private var stationRef: StationRef { StationRef(id: station.id.uuidString, name: station.name) }

    private var access: PlaybackAccess {
        switch music.authState {
        case .unknown: .checking
        case .notDetermined: .needsAuthorization
        case .authorized: .authorized
        case .denied: .denied
        case .notSubscribed: .subscriptionRequired
        }
    }
}

/// Arms the one shared player once per process. A later layout change does not re-enter,
/// so it cannot search or play again. It never requests Apple Music permission — that
/// follows a tap on Allow or an explicit station open, never launch/restore. It does refresh
/// the non-prompting `MusicAuthorization.currentStatus` so a previously granted user still
/// reaches `configureAudioSession` / `startObserving`, and `.notDetermined` shows Allow.
@MainActor
enum PlaybackSessionBinder {
    private static var didBind = false

    static func bind(_ dependencies: AppDependencies) async {
        guard !didBind else { return }
        didBind = true
        let music = dependencies.playback
        precondition(music === MusicKitService.shared, "MusicKitService.shared is the only player")
        let interlude = dependencies.interlude
        let djSession = dependencies.djSession
        music.onBoundary = { @MainActor [interlude, music, djSession] boundary, finishedIndex in
            #if AERODJ_P0_DIAG
            P0EventTraceHost.shared.onBoundary(boundary, finishedIndex: finishedIndex)
            #endif
            guard case .naturalEnd = boundary else { return }
            // Hand the break out before this closure awaits anything. The window was the
            // `Task` below awaiting `naturalBoundary` while `PendingPlayStop` was still idle:
            // an unplug or interruption in that await was ignored, then `handOut` plus `play`
            // could start the break on the speaker. A second `handOut` would clear the held stop.
            interlude.handOut(afterTrack: finishedIndex)
            // A break is only ever played at a natural end. Anything late, missing or failed is
            // skipped, and the next song is not delayed.
            Task { @MainActor in
                /// The handed-out break never started. Report `.failed` so DJ state leaves `.ready`,
                /// and leave the boundary transition so music can continue.
                @MainActor func reportUnplayed(_ reason: HandedOutBreakSkip) {
                    let report = HandedOutBreakReport.skipped(
                        reason, afterTrack: finishedIndex, mayAutoResume: music.mayAutoResume)
                    if case .playbackFailed(let k) = report.event {
                        djSession.playbackFailed(afterTrack: k)
                    }
                    music.logBreakSkipped(after: finishedIndex, reason: .notPlanned)
                    if report.resume.audioEvent != nil {
                        music.skipInterlude()
                    }
                }
                // The break (or its skip) comes first; the next song is loaded only after it.
                if interlude.isSpeaking {
                    #if AERODJ_P0_DIAG
                    P0EventTraceHost.shared.naturalBoundary(.interludeSpeaking, afterTrack: finishedIndex)
                    #endif
                    interlude.abandonHandOut()
                    music.skipInterlude()
                } else if let prepared = await djSession.naturalBoundary(afterTrack: finishedIndex) {
                    #if AERODJ_P0_DIAG
                    P0EventTraceHost.shared.naturalBoundary(.breakPrepared, afterTrack: finishedIndex)
                    #endif
                    switch BreakHandoffPolicy.decide(prepared: prepared) {
                    case let .play(breakToPlay):
                        let line = breakToPlay.cues.map(\.text).joined(separator: " ")
                        let clips = breakToPlay.clips.map(\.audio.data)
                        // Empty line or no clips: the break was handed out and will not play.
                        guard !line.isEmpty, !clips.isEmpty else {
                            interlude.abandonHandOut()
                            reportUnplayed(.emptyLine)
                            break
                        }
                        await interlude.play(clips: clips, line: line, afterTrack: finishedIndex)
                    case .continueMusic:
                        // Close the early hand-out. A later stop must see idle, not a break
                        // that will never play.
                        interlude.abandonHandOut()
                        reportUnplayed(.emptyLine)
                    }
                } else {
                    #if AERODJ_P0_DIAG
                    let skip = djSession.lastNoBreak
                    P0EventTraceHost.shared.naturalBoundary(.noBreak(skip?.reason, cadencePlanned: skip?.cadencePlanned ?? false),
                                                            afterTrack: finishedIndex)
                    #endif
                    // No prepared break. Same close-out: the hand-out is over.
                    interlude.abandonHandOut()
                    music.logBreakSkipped(after: finishedIndex, reason: .notPlanned)
                    music.skipInterlude()
                }
                await music.startNextTrack(after: finishedIndex)
            }
        }
        // A song really started: the DJ session plans its break with the catalog duration.
        // Without a duration nothing is planned, so the DJ stays quiet rather than guessing.
        music.onSongStarted = { [djSession] index, duration in
            guard let duration else { return }
            Task { await djSession.songStarted(index: index, remaining: .seconds(duration)) }
        }
        music.onBreakMustStop = { [interlude] reason in
            if let reason {
                interlude.stopCurrentInterlude(reason: reason)
            } else {
                interlude.stop()
            }
        }
        // A skip cuts the skipped song's break, so a prepared break for it is never played.
        music.onSongSkipped = { [djSession] index in
            Task { await djSession.songCut(afterTrack: index) }
        }
        // Only real audio events reach the DJ session; nothing is synthesized from the plan.
        interlude.onPlayback = { [djSession] event in
            switch event {
            case .started(let k): djSession.playbackStarted(afterTrack: k)
            case .finished(let k): djSession.playbackFinished(afterTrack: k)
            // A revoke stops On Air without a voice failure. The session has no cancel event.
            case .revoked(let k): djSession.playbackFinished(afterTrack: k)
            case .failed(let k): djSession.playbackFailed(afterTrack: k)
            }
        }
        // Non-prompting status only. Launch and selection restore must not call request().
        await music.refreshAuthorizationStatus()
    }
}

#Preview {
    let dependencies = AppDependencies.make()
    NavigationStack {
        PlayerView(station: Station(id: UUID(), name: "Morning Calm", description: nil),
                   music: dependencies.playback, interlude: dependencies.interlude,
                   djSession: dependencies.djSession, studio: dependencies.studio,
                   isTestStation: dependencies.mode == .testStation)
    }
}
