import SwiftUI

/// Player shell — UI MOCK ONLY. The play/pause toggle flips a local Bool and
/// plays nothing; MusicKit playback arrives with #15. When implemented, MusicKit
/// manages playback; this view only reflects state. No protected-stream mixing.
struct PlayerView: View {
    let station: Station
    @State private var isPlaying = false

    var body: some View {
        VStack(spacing: 24) {
            Text(station.name).font(.title2)
            Text(isPlaying ? "Now Playing" : "Paused").foregroundStyle(.secondary)

            Button {
                isPlaying.toggle()
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
            }
            .buttonStyle(.plain)
        }
        .padding()
    }
}

#Preview {
    PlayerView(station: Station(id: UUID(), name: "Morning Calm", description: nil))
}
