import SwiftUI
import AeroDJCore

/// Player shell. MusicKit playback is managed by the framework; this view
/// reflects state and forwards user actions. No protected-stream mixing.
///
/// The UI is `PlayingScreen` (Listen on the closed Duo, the two-zone Studio when open). It
/// binds to the app-scoped session's `snapshot`, `studio` (tuner, Connections, DJ state)
/// and real actions. The `.task` audio wiring is owned by Claude (#58) and is kept verbatim.
struct PlayerView: View {
    let station: Station
    @StateObject private var music: MusicKitService
    @StateObject private var interlude: InterludePlaybackAdapter
    let djSession: DJBreakSession
    let studio: StudioPresentationModel
    let isTestStation: Bool

    /// `music` is the app-scoped session from `AppDependencies`. Never a new player.
    init(station: Station, music: MusicKitService, djSession: DJBreakSession,
         studio: StudioPresentationModel, isTestStation: Bool) {
        self.station = station
        self.djSession = djSession
        self.studio = studio
        self.isTestStation = isTestStation
        _music = StateObject(wrappedValue: music)
        _interlude = StateObject(wrappedValue: InterludePlaybackAdapter(music: music))
    }

    var body: some View {
        PlayingScreen(station: stationRef,
                      access: access,
                      snapshot: music.snapshot,
                      actions: .live(music),
                      search: .live(music, station: stationRef, djSession: djSession),
                      studio: studio,
                      isTestStation: isTestStation)
        .navigationTitle(station.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task {
            music.onBoundary = { @MainActor [interlude, music, djSession] boundary, finishedIndex in
                guard case .naturalEnd = boundary else { return }
                // A break is only ever played at a natural end. Anything late, missing or failed is
                // skipped, and the next song is not delayed.
                Task { @MainActor in
                    // The break (or its skip) comes first; the next song is loaded only after it.
                    if interlude.isSpeaking {
                        music.skipInterlude()
                    } else if let prepared = await djSession.naturalBoundary(afterTrack: finishedIndex) {
                        switch BreakHandoffPolicy.decide(prepared: prepared) {
                        case let .play(breakToPlay):
                            let line = breakToPlay.cues.map(\.text).joined(separator: " ")
                            await interlude.play(clips: breakToPlay.clips.map(\.audio.data), line: line, afterTrack: finishedIndex)
                        case .continueMusic:
                            music.logBreakSkipped(after: finishedIndex, reason: .notPlanned)
                            music.skipInterlude()
                        }
                    } else {
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
            // Player side of the session hook. Fry #73 owns the property and the purge call.
            djSession.onBreakMustStop = { [interlude] reason in
                interlude.stopCurrentInterlude(reason: reason)
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
            await music.authorize()
        }
    }

    private var stationRef: StationRef { StationRef(id: station.id.uuidString, name: station.name) }

    private var access: PlaybackAccess {
        switch music.authState {
        case .unknown: .checking
        case .authorized: .authorized
        case .denied: .denied
        case .notSubscribed: .subscriptionRequired
        }
    }
}

#Preview {
    let dependencies = AppDependencies.make()
    NavigationStack {
        PlayerView(station: Station(id: UUID(), name: "Morning Calm", description: nil),
                   music: dependencies.playback, djSession: dependencies.djSession,
                   studio: dependencies.studio, isTestStation: dependencies.mode == .testStation)
    }
}
