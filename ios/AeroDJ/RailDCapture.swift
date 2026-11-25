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

    /// Build 58 follow-up (-Nova): `-AeroDJCaptureClosedStatusColumn YES` gives the closed-Duo frame
    /// the device's trailing status column: the container's trailing safe area grows by this much
    /// (so the player's reader ends where the column starts, as on the device, and its own inset
    /// reads 0), and the player gets the same width through `trailingSystemInset`, the value
    /// `StationSplitRoot` derives from the window. Other frames and launches are unchanged.
    static let closedStatusColumnKey = "AeroDJCaptureClosedStatusColumn"
    static let closedStatusColumnWidth: Double = 73

    /// The injected column width for this scenario: 0 unless the launch asks for it on the closed Duo.
    static func closedStatusColumn(for scenario: StudioCaptureScenario) -> Double {
        guard scenario.railDFrame == .railDDuoClosed,
              UserDefaults.standard.bool(forKey: closedStatusColumnKey) else { return 0 }
        return closedStatusColumnWidth
    }

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
                    // #626 (-Nova): the safe-area band goes on the player inside the stack. Padded
                    // outside it, the band never reached the player's reader (run 45466062310: the
                    // reader stayed 390 wide, `extend` came on top, and the rail drew off-screen).
                    NavigationStack {
                        player.modifier(ClosedStatusColumnInset(width: Self.closedStatusColumn(for: scenario)))
                    }
                    .modifier(ClosedStatusColumnCapture(width: Self.closedStatusColumn(for: scenario)))
                }
            }
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

/// The closed Duo's status column in a capture (`RailDCaptureContainer.closedStatusColumnKey`),
/// on the player itself: a trailing safe-area band of `width` (so the player's reader ends where
/// the column starts, as under the device's window) and the same width in `trailingSystemInset`.
/// `width == 0` returns the content as is, so every other capture keeps its pixels.
private struct ClosedStatusColumnInset: ViewModifier {
    let width: Double

    @ViewBuilder
    func body(content: Content) -> some View {
        if width > 0.5 {
            content
                .safeAreaPadding(.trailing, CGFloat(width))
                .environment(\.trailingSystemInset, width)
        } else {
            content
        }
    }
}

/// The stand-in for the device's time and battery ring at the top of the status column
/// (`ClosedStatusColumnInset` makes the band). `width == 0` returns the content as is.
private struct ClosedStatusColumnCapture: ViewModifier {
    let width: Double

    @ViewBuilder
    func body(content: Content) -> some View {
        if width > 0.5 {
            content
                .overlay(alignment: .topTrailing) {
                    VStack(spacing: 6) {
                        Text(verbatim: "12:58")
                            .font(.system(size: 15, weight: .semibold).monospacedDigit())
                        Image(systemName: "battery.75percent")
                            .font(.system(size: 17))
                    }
                    .foregroundStyle(.white)
                    .frame(width: CGFloat(width))
                    .padding(.top, 12)
                    .ignoresSafeArea(.container, edges: .trailing)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
        } else {
            content
        }
    }
}
#endif
