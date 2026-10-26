import AeroDJCore
import SwiftUI

/// What Now Playing shows when there is no track the transport can control.
///
/// Copy comes only from `NowPlayingContent` (connecting, access off, subscription,
/// nothing playing). The plate is the station's own ident, not a song cover and not a
/// spinner. A progress indicator appears only while Apple Music is connecting.
/// Reduce Motion replaces that spinner with a still mark. Accessibility sizes,
/// including AX5, stack the mark above the title and shrink the plate.
struct EmptyStationStage: View {
    let content: NowPlayingContent
    @Environment(\.artStation) private var station
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 18) {
            StationIdentPlate(style: .station(station), size: plateSide, caption: station?.name)

            VStack(spacing: 6) {
                if content == .connecting {
                    connectingTitle
                } else {
                    Text(content.title)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
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
            .accessibilityLabel(statusAccessibilityLabel)
            .accessibilityAddTraits(.isStaticText)

            if content == .accessDenied, let url = URL(string: UIApplication.openSettingsURLString) {
                Button("Open Settings") { openURL(url) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Opens the Settings app.")
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("empty.stage")
    }

    /// The station plate shrinks at accessibility sizes so the status text can grow.
    /// AX5 (accessibility extra extra extra large) shrinks it further.
    private var plateSide: CGFloat {
        if typeSize >= .accessibilityExtraExtraExtraLarge { return 96 }
        if typeSize.isAccessibilitySize { return 128 }
        return 220
    }

    private var statusAccessibilityLabel: String {
        if let detail = content.detail {
            return "\(content.title). \(detail)"
        }
        return content.title
    }

    @ViewBuilder
    private var connectingTitle: some View {
        let mark = connectingMark
        if typeSize.isAccessibilitySize {
            VStack(spacing: 8) {
                mark
                Text(content.title)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            HStack(spacing: 8) {
                mark
                Text(content.title)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var connectingMark: some View {
        if reduceMotion {
            Image(systemName: "hourglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        } else {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
        }
    }
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
