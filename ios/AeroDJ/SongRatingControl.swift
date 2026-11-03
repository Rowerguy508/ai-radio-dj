import AeroDJCore
import SwiftUI

// In-app station ratings (-Nova, PR B). The logic is `SongRatingController` in AeroDJCore (tested
// on Linux); this file gives it live hooks and draws the button, the Undo toast and the Settings
// section. Nothing here logs a song, an artist, a rating or a station, and nothing reaches the DJ
// or a voice: the station queue reads the bias, the DJ only ever sees the queue.

extension SongRatingController {
    /// The live controller. `scope`: the committed station, as a saved recipe while the last
    /// applied recipe still has the same seeds, else by its seeds (`StationRatingScope.recipeID`).
    /// Never on the playing song: `MusicKitService.skip()` (a user skip; its own break is dropped
    /// by the skip path). Every change first rebuilds the queue and drops prepared breaks that name
    /// a queued, now-excluded song (`StationQueuePlayer.ratingChanged`).
    static func live(ratings: StationRatingsModel, station: StationConfigurationModel,
                     studio: StudioPresentationModel, music: MusicKitService,
                     queue: StationQueuePlayer?) -> SongRatingController {
        SongRatingController(ratings: ratings, hooks: .init(
            scope: { [weak studio, weak station] in
                guard let station else { return nil }
                return StationRatingScope(recipeID: liveRecipeID(studio: studio, station: station),
                                          configuration: station.committedDisplayed)
            },
            playingSongID: { [weak music] in music?.currentTrack?.id },
            origin: { [weak music] id in music?.queue.first(where: { $0.id == id })?.origin ?? .unknown },
            artistID: { [weak queue] id in queue?.artistID(forSong: id) },
            skipPlaying: { [weak music] in _ = try? await music?.skip() },
            ratingsChanged: { [weak queue] in await queue?.ratingChanged() }))
    }

    /// The recipe the committed station came from, or nil (then its seeds are the scope).
    static func liveRecipeID(studio: StudioPresentationModel?, station: StationConfigurationModel) -> UUID? {
        guard let studio else { return nil }
        return StationRatingScope.recipeID(lastApplied: studio.lastAppliedRecipeID, recipes: studio.recipes.recipes,
                                           committed: station.committedDisplayed)
    }

    #if DEBUG
    /// Screenshots and previews (StudioCapture): an in-memory book, fixed day, no playback.
    static func fixture(rated: SongRating? = nil, songID: String, labelSeen: Bool = false) async -> SongRatingController {
        let scope = StationRatingScope.seeds(0xA11CE)
        let ratings = StationRatingsModel(store: InMemoryStationRatingStore(), today: { 20_000 })
        await ratings.load()
        if let rated {
            ratings.rate(rated, song: StationRatedSong(songID: songID, artistName: "Fixture"), in: scope)
        }
        let defaults = UserDefaults(suiteName: "AeroDJRatingsFixture") ?? .standard
        defaults.set(labelSeen, forKey: SongRatingPresentation.labelSeenKey)
        return SongRatingController(ratings: ratings, hooks: .init(scope: { scope }), defaults: defaults)
    }
    #endif
}

private struct SongRatingKey: EnvironmentKey { static let defaultValue: SongRatingController? = nil }

extension EnvironmentValues {
    /// Set once at the app root (AeroDJApp). Only `TrackBlock` and `FoldedTitleBlock` (the button), the toast and the recipe
    /// delete read it; with nil (previews, StudioCapture's existing scenarios) nothing changes.
    var songRating: SongRatingController? {
        get { self[SongRatingKey.self] }
        set { self[SongRatingKey.self] = newValue }
    }
}

/// The rating Menu next to the artist line: star when unrated, else the level's symbol. 44 pt.
struct SongRatingButton: View {
    let controller: SongRatingController
    let track: TrackInfo
    var ink: Color
    @State private var confirmingClearStation = false

    var body: some View {
        let current = controller.rating(for: track.id)
        Menu {
            ForEach(SongRatingPresentation.menuOrder, id: \.self) { level in
                Button(role: level == .never ? .destructive : nil) {
                    Task { await controller.rate(level, songID: track.id, artistName: track.artistName) }
                } label: {
                    Label(SongRatingPresentation.title(level), systemImage: SongRatingPresentation.symbol(level))
                }
                .accessibilityAddTraits(current == level ? .isSelected : [])
            }
            if current != nil {
                Button {
                    Task { await controller.clearRating(songID: track.id) }
                } label: {
                    Label(SongRatingPresentation.clearTitle, systemImage: SongRatingPresentation.clearSymbol)
                }
            }
            Divider()
            Button(SongRatingPresentation.clearStationTitle, role: .destructive) { confirmingClearStation = true }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: SongRatingPresentation.symbol(current))
                    .font(.body.weight(.semibold))
                if !controller.labelSeen {
                    Text(SongRatingPresentation.firstTimeLabel).font(.subheadline.weight(.semibold))
                }
            }
            .foregroundStyle(ink)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .accessibilityLabel(SongRatingPresentation.accessibilityLabel(current))
        .accessibilityIdentifier("nowPlaying.rating")
        .confirmationDialog(SongRatingPresentation.clearStationTitle, isPresented: $confirmingClearStation,
                            titleVisibility: .visible) {
            Button(SongRatingPresentation.clearStationTitle, role: .destructive) {
                Task { await controller.clearStation() }
            }
        }
    }
}

/// The never toast with Undo. Top of the player, glass capsule like `StationStartToast`.
struct SongRatingToast: View {
    let controller: SongRatingController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let toast = controller.toast {
                HStack(spacing: 12) {
                    Label(toast.message, systemImage: SongRatingPresentation.symbol(.never))
                        .font(.subheadline.weight(.semibold))
                    Button(SongRatingPresentation.undoTitle) { Task { await controller.undo() } }
                        .font(.subheadline.weight(.bold))
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("nowPlaying.rating.undo")
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .aeroGlass(Capsule(), fallback: AnyShapeStyle(.regularMaterial), hairline: Color.primary.opacity(0.12))
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("nowPlaying.ratingToast")
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.35), value: controller.toast?.id)
        .task(id: controller.toast?.id) {
            guard let toast = controller.toast else { return }
            AccessibilityNotification.Announcement(toast.message).post()
            try? await Task.sleep(for: SongRatingController.toastDuration)
            guard !Task.isCancelled else { return }
            controller.dismissToast(id: toast.id)
        }
    }
}

/// The toast over the player. Without a controller in the environment the content is unchanged.
struct SongRatingToastHost: ViewModifier {
    @Environment(\.songRating) private var songRating

    @ViewBuilder
    func body(content: Content) -> some View {
        if let songRating {
            content.overlay(alignment: .top) { SongRatingToast(controller: songRating) }
        } else {
            content
        }
    }
}

/// "Clear all ratings" in Settings (#372's Form, below the talk-over row), with a confirmation.
/// Deletes the ratings file. When that fails the ratings are still there, and the footer says so.
struct StationRatingsSettingsSection: View {
    let controller: SongRatingController
    @State private var confirming = false
    @State private var clearFailed = false

    var body: some View {
        Section {
            Button(SongRatingPresentation.clearAllTitle, role: .destructive) { confirming = true }
                .accessibilityIdentifier("settings.clearAllRatings")
                .confirmationDialog(SongRatingPresentation.clearAllTitle, isPresented: $confirming,
                                    titleVisibility: .visible) {
                    Button(SongRatingPresentation.clearAllTitle, role: .destructive) {
                        Task { clearFailed = !(await controller.clearAll()) }
                    }
                } message: {
                    Text(SongRatingPresentation.clearAllFooter)
                }
        } header: {
            Text("Ratings")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if clearFailed {
                    Text(SongRatingPresentation.clearAllFailed)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("settings.clearAllRatings.failed")
                }
                Text(SongRatingPresentation.clearAllFooter)
            }
        }
    }
}
