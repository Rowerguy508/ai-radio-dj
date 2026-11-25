#if DEBUG
import AeroDJCore
import SwiftUI

/// Mockup D's Studio shots (owner: "Yes, build it"). One fixed container per frame, on the same
/// neutral backdrop and outline as `DuoWideCaptureContainer`, so each PNG shows exactly the
/// frame the mock draws. The landscape shots force the hinge and fold the SDK never reports in
/// the simulator (`FoldPoseOverride`): book pose for the L1 spread, flat for L2. The player is
/// the real `PlayingScreen`; nothing here changes playback. `capture.railDContainer` lets the
/// UI test wait for the final size before it reads frames. -Nova
struct RailDCaptureContainer: View {
    let scenario: StudioCaptureScenario
    let studio: StudioPresentationModel

    @State private var columns = NavigationSplitViewVisibility.all

    struct Frame {
        let size: CGSize
        let sizeClass: UserInterfaceSizeClass
        /// Stations sidebar width, nil for the player alone.
        let sidebar: CGFloat?
        let fold: FoldPoseOverride?
    }

    /// The fold band at 820 pt: 396…424, the same as `FoldedColumnLayout.duoHorizontal`.
    static let foldBand = FoldAwareness.Division(minX: 396, minY: 0, width: 28, height: 640, isActive: true)

    /// Build 54 (-Nova): `-AeroDJRailDDeviceWindow YES` draws the landscape frames at the open
    /// Duo's measured window (951 × 669 pt, the owner's @3x shots) with a centred fold band.
    static let deviceWindowKey = "AeroDJRailDDeviceWindow"
    static let deviceWindowSize = CGSize(width: 951, height: 669)

    /// #460 (-Nova): the collapsed frames draw the open Duo's trailing status column as a
    /// trailing safe-area inset (≈ 73 pt in the owner's build 54 @3x shots,
    /// `DuoStationsLayout.statusColumnClearance`'s note), which no iPad simulator window has.
    /// The collapsed player reads it like the device's (`FoldAwareness.flatRailColumn`). Every
    /// other frame keeps no inset, so its shot is unchanged.
    static let openStatusColumn: CGFloat = 73

    static func frame(for scenario: StudioCaptureScenario) -> Frame {
        let frame = baseFrame(for: scenario)
        guard UserDefaults.standard.bool(forKey: deviceWindowKey),
              frame.size == StudioCapture.duoTentContainerSize else { return frame }
        let size = deviceWindowSize
        let band = FoldedColumnLayout.duoFoldGutter
        let fold = frame.fold.map { pose in
            FoldPoseOverride(hinge: pose.hinge,
                             divisions: pose.divisions.isEmpty ? [] : [
                                FoldAwareness.Division(minX: (Double(size.width) - band) / 2, minY: 0, width: band,
                                                       height: Double(size.height), isActive: true),
                             ])
        }
        return Frame(size: size, sizeClass: frame.sizeClass, sidebar: frame.sidebar, fold: fold)
    }

    private static func baseFrame(for scenario: StudioCaptureScenario) -> Frame {
        let portrait = StudioCapture.duoWideContainerSize
        let landscape = StudioCapture.duoTentContainerSize
        if scenario == .railDPortraitOnAir {
            // #434: a flat hinge, so the player takes the open-Duo path (portrait stays portrait).
            return Frame(size: portrait, sizeClass: .compact, sidebar: nil,
                         fold: FoldPoseOverride(hinge: .init(status: .fullyOpen, angleDegrees: 180), divisions: []))
        }
        switch scenario.railDFrame {
        case .railDDuoClosed:
            return Frame(size: CGSize(width: 390, height: 844), sizeClass: .compact, sidebar: nil, fold: nil)
        case .railDPortraitSidebar:
            return Frame(size: portrait, sizeClass: .regular, sidebar: 290, fold: nil)
        case .railDLandscapeSpread:
            return Frame(size: landscape, sizeClass: .regular, sidebar: nil,
                         fold: FoldPoseOverride(hinge: .init(status: .partiallyOpen, angleDegrees: 150),
                                                divisions: [foldBand]))
        case .railDLandscapeCentred:
            return Frame(size: landscape, sizeClass: .regular, sidebar: nil,
                         fold: FoldPoseOverride(hinge: .init(status: .fullyOpen, angleDegrees: 180), divisions: []))
        case .railDLandscapeSidebar:
            return Frame(size: landscape, sizeClass: .regular, sidebar: 320, fold: nil)
        default:
            // `railDPortrait`: the unfolded Duo upright, as `duoWideReady`.
            return Frame(size: portrait, sizeClass: .compact, sidebar: nil, fold: nil)
        }
    }

    var body: some View {
        let frame = Self.frame(for: scenario)
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        ZStack {
            Color(white: 0.14)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            Group {
                if let sidebar = frame.sidebar {
                    NavigationSplitView(columnVisibility: $columns) {
                        List {
                            Text(PlaybackFixtures.station.name)
                            Text("Late Night")
                        }
                        .navigationTitle("Stations")
                        .navigationSplitViewColumnWidth(sidebar)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("split.sidebar")
                    } detail: {
                        NavigationStack { player }
                    }
                    .navigationSplitViewStyle(.balanced)
                } else {
                    NavigationStack { player }
                }
            }
            .modifier(CaptureStatusColumn(width: scenario.isRailDCollapsed ? Self.openStatusColumn : 0))
            .environment(\.horizontalSizeClass, frame.sizeClass)
            .environment(\.foldPoseOverride, frame.fold)
            .frame(width: frame.size.width, height: frame.size.height)
            .clipShape(shape)
            .overlay { shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 1).allowsHitTesting(false) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("capture.railDContainer")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    /// #460: the trailing status column, or the content unchanged at width 0 (every other frame).
    private struct CaptureStatusColumn: ViewModifier {
        let width: CGFloat
        @ViewBuilder func body(content: Content) -> some View {
            if width > 0 {
                content.safeAreaPadding(.trailing, width)
            } else {
                content
            }
        }
    }

    private var player: some View {
        PlayingScreen(station: PlaybackFixtures.station, access: scenario.access,
                      snapshot: scenario.snapshot, actions: .preview,
                      search: .captureOffline,
                      studio: studio, isTestStation: true,
                      timeSource: .fixture,
                      stationStops: [
                          DuoStationSwitch.Stop(id: PlaybackFixtures.station.id, name: PlaybackFixtures.station.name),
                          DuoStationSwitch.Stop(id: "late-night", name: "Late Night"),
                      ],
                      onOpenStation: { _ in })
    }
}
#endif
