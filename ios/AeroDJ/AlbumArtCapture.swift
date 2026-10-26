#if DEBUG
import AeroDJCore
import SwiftUI

/// Debug-only capture of Now Playing when a song actually has artwork.
///
/// Separate from `StudioCapture` so Fry's scenario list stays untouched. Launch with
/// `-AeroDJTestStation YES -AeroDJStudioCapture YES -AeroDJAlbumArtFixture YES`.
/// The picture is a bundled fixture, not a network fetch and not the station ident.
enum AlbumArtCapture {
    static let defaultsKey = "AeroDJAlbumArtFixture"

    static func isRequested(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    static var fixtureURL: URL? {
        Bundle.main.url(forResource: "FixtureAlbum", withExtension: "png")
    }

    static var snapshot: PlaybackSnapshot {
        var snap = PlaybackFixtures.playing
        guard let url = fixtureURL, let now = snap.nowPlaying else { return snap }
        snap.nowPlaying = TrackInfo(id: now.id, title: now.title, artistName: now.artistName, artworkURL: url)
        return snap
    }
}

struct AlbumArtCaptureView: View {
    let dependencies: AppDependencies
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Group {
                if loaded {
                    PlayingScreen(station: PlaybackFixtures.station, access: .authorized,
                                  snapshot: AlbumArtCapture.snapshot, actions: .preview,
                                  search: nil, studio: dependencies.studio, isTestStation: true)
                } else {
                    ProgressView()
                }
            }
        }
        .preferredColorScheme(UserDefaults.standard.bool(forKey: StudioCapture.darkKey) ? .dark : nil)
        .task {
            let studio = dependencies.studio
            for _ in 0..<200 {
                switch studio.station.loadState {
                case .ready, .failed: break
                default:
                    try? await Task.sleep(for: .milliseconds(50))
                    continue
                }
                break
            }
            loaded = true
        }
    }
}
#endif
