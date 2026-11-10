import AeroDJCore
@preconcurrency import MediaPlayer
import UIKit

/// Publishes `CarPlayNowPlaying` onto the now-playing info the system template reads.
///
/// Play, pause, and next are left on the remote commands `MusicKitService` already
/// installed. This type only replaces title, artist, and the album line (the station
/// name), and drops lyrics and comments. Artwork is loaded from the track URL only.
@MainActor
final class CarPlayNowPlayingBridge {
    private var artworkTask: Task<Void, Never>?
    private var loadedArtworkURL: URL?
    private var didCheckKeys = false

    func apply(_ fields: CarPlayNowPlaying) {
        checkKeys()
        write(fields)
        guard fields.artworkURL != loadedArtworkURL else { return }
        loadedArtworkURL = fields.artworkURL
        artworkTask?.cancel()
        guard let url = fields.artworkURL else { return }
        artworkTask = Task { @MainActor in
            let data: Data
            do {
                data = try await URLSession.shared.data(from: url).0
            } catch {
                return
            }
            guard !Task.isCancelled, self.loadedArtworkURL == url, let image = UIImage(data: data),
                  image.size.width > 0, image.size.height > 0 else { return }
            var info = CarPlayNowPlayingMerge.apply(fields: fields, to: currentInfo())
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    func cancel() {
        artworkTask?.cancel()
        artworkTask = nil
        loadedArtworkURL = nil
    }

    private func write(_ fields: CarPlayNowPlaying) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = CarPlayNowPlayingMerge.apply(fields: fields, to: currentInfo())
    }

    private func currentInfo() -> [String: Any] {
        MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
    }

    private func checkKeys() {
        guard !didCheckKeys else { return }
        didCheckKeys = true
        assert(MPMediaItemPropertyTitle == CarPlayNowPlayingMerge.titleKey)
        assert(MPMediaItemPropertyArtist == CarPlayNowPlayingMerge.artistKey)
        assert(MPMediaItemPropertyAlbumTitle == CarPlayNowPlayingMerge.stationNameKey)
        assert(MPMediaItemPropertyLyrics == CarPlayNowPlayingMerge.lyricsKey)
        assert(MPMediaItemPropertyComments == CarPlayNowPlayingMerge.commentsKey)
    }
}
