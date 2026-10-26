import AeroDJCore
import SwiftUI

/// What Now Playing shows when there is no track the transport can control.
///
/// Copy comes only from `NowPlayingContent` (connecting, access off, subscription,
/// nothing playing). The plate is the station's own ident, not a song cover and not a
/// spinner. A progress indicator appears only while Apple Music is connecting, beside
/// the status line.
struct EmptyStationStage: View {
    let content: NowPlayingContent
    @Environment(\.artStation) private var station
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 18) {
            StationIdentPlate(style: .station(station), size: plateSide, caption: station?.name)

            VStack(spacing: 6) {
                if content == .connecting {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityHidden(true)
                        Text(content.title)
                            .font(.title3.weight(.semibold))
                    }
                } else {
                    Text(content.title)
                        .font(.title3.weight(.semibold))
                }
                if let detail = content.detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)

            if content == .accessDenied, let url = URL(string: UIApplication.openSettingsURLString) {
                Button("Open Settings") { openURL(url) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("empty.stage")
    }

    /// The station plate shrinks at accessibility sizes so the status text can grow.
    private var plateSide: CGFloat { typeSize.isAccessibilitySize ? 128 : 220 }
}

#Preview("Empty stages") {
    VStack(spacing: 28) {
        EmptyStationStage(content: .nothingPlaying)
        EmptyStationStage(content: .connecting)
        EmptyStationStage(content: .accessDenied)
    }
    .padding()
    .environment(\.artStation, PlaybackFixtures.station)
}
