import SwiftUI

/// Player shell. MusicKit playback is managed by the framework; this view
/// only reflects state and forwards user actions. No protected-stream mixing.
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
