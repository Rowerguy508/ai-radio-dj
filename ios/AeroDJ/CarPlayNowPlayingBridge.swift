import AeroDJCore
@preconcurrency import MediaPlayer
import UIKit

/// Publishes `CarPlayNowPlaying` onto the now-playing info the system template reads.
///
/// Play, pause, and next are left on the remote commands `MusicKitService` already
/// installed. Text is written only from the latest publication. A fetch sets artwork
/// only when `CarPlayArtworkGate` still accepts that token, and never writes the song
/// that was current when the fetch began.
@MainActor
final class CarPlayNowPlayingBridge {
    private var gate = CarPlayArtworkGate()
    private var fetchTask: Task<Void, Never>?
    private var didCheckKeys = false
    private let load: @MainActor (URL) async throws -> Data

    init(load: @escaping @MainActor (URL) async throws -> Data = { url in
        try await URLSession.shared.data(from: url).0
    }) {
        self.load = load
    }

    func apply(_ fields: CarPlayNowPlaying) {
        checkKeys()
        for command in gate.publish(fields) {
            perform(command)
        }
    }

    func cancel() {
        fetchTask?.cancel()
        fetchTask = nil
        gate = CarPlayArtworkGate()
    }

    private func perform(_ command: CarPlayArtworkGate.Command) {
        switch command {
        case .writeText(let fields):
            MPNowPlayingInfoCenter.default().nowPlayingInfo = CarPlayNowPlayingMerge.apply(fields: fields, to: currentInfo())
        case .clearArtwork:
            fetchTask?.cancel()
            fetchTask = nil
            var info = currentInfo()
            info.removeValue(forKey: MPMediaItemPropertyArtwork)
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        case .startFetch(let token):
            fetchTask?.cancel()
            fetchTask = Task { @MainActor in
                let data: Data
                do {
                    data = try await self.load(token.url)
                } catch {
                    if !Task.isCancelled { self.gate.fetchFailed(token) }
                    return
                }
                guard !Task.isCancelled else { return }
                guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else {
                    self.gate.fetchFailed(token)
                    return
                }
                switch self.gate.fetchArrived(token) {
                case .ignore:
                    return
                case .setArtwork:
                    var info = self.currentInfo()
                    info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                }
            }
        }
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
