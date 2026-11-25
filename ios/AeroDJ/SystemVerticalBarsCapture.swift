#if DEBUG
import AeroDJCore
import SwiftUI

/// #465 item 1, DEBUG Studio capture only (-Nova). Read once at launch: true only in a Studio
/// capture run in the test station, with `-AeroDJCaptureSystemVerticalBars YES`, on a binary built
/// with the iOS 27.1 SDK (`compiler(>=6.4)`) running on iOS 27.1 or later. Then
/// `DuoVerticalRail.usesSystemBar` is true, the player attaches the existing
/// `DuoSystemVerticalToolbar` and drops the custom rail, exactly as the shipping code would if
/// the owner says yes. Every other run, Debug included, is false and draws Rail D as before.
///
/// A `let` of a `Sendable` value, so it needs no actor isolation under Swift 6.
enum SystemVerticalBarsCaptureFlag {
    static let isOn: Bool = {
        let defaults = UserDefaults.standard
        var sdkHasVerticalBar = false
        #if compiler(>=6.4)
        if #available(iOS 27.1, *) { sdkHasVerticalBar = true }
        #endif
        return SystemVerticalBarsCapture.attachesSystemBar(
            studioCapture: defaults.bool(forKey: StudioCapture.defaultsKey),
            testStation: defaults.bool(forKey: TestStation.defaultsKey),
            launchFlag: defaults.bool(forKey: SystemVerticalBarsCapture.launchKey),
            sdkHasVerticalBar: sdkHasVerticalBar)
    }()
}

/// The open Duo upright and sideways in Rail D's own capture frames (`RailDCaptureContainer`
/// with `railDPortrait` / `railDLandscapeCentred`), the same playing song with a break ready, so
/// each shot sits beside its `rail-d-duo-open-*` counterpart. Without the launch flag (or below
/// the 27.1 SDK) the frame is plain Rail D. `capture.systemVerticalBars` tells the UI test which
/// one it got; it is a 1 pt marker outside the frame, never in the shot's controls.
struct SystemVerticalBarsCaptureView: View {
    let scenario: SystemVerticalBarsCapture.Scenario
    let dependencies: AppDependencies

    @State private var loaded = false
    @State private var failure: String?

    /// The Rail D frame this scenario reuses. Its playing, seekable snapshot comes with it.
    private var railDFrame: StudioCaptureScenario {
        switch scenario {
        case .duoOpenPortrait: .railDPortrait
        case .duoOpenLandscape: .railDLandscapeCentred
        }
    }

    var body: some View {
        Group {
            if let failure {
                Text(failure).accessibilityIdentifier("capture.failed")
            } else if !loaded {
                Text("Loading studio capture").accessibilityIdentifier("capture.loading")
            } else {
                RailDCaptureContainer(scenario: railDFrame, studio: dependencies.studio)
                    .overlay(alignment: .bottomLeading) {
                        let value = SystemVerticalBarsCaptureFlag.isOn ? "system" : "railD"
                        Text(verbatim: value)
                            .font(.system(size: 1))
                            .accessibilityIdentifier("capture.systemVerticalBars")
                            .accessibilityLabel(Text(verbatim: value))
                            .allowsHitTesting(false)
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(UserDefaults.standard.bool(forKey: StudioCapture.darkKey) ? .dark : nil)
        // As `StudioCaptureView` for the Rail D frames: no rating controller from the app root.
        .environment(\.songRating, nil)
        .task {
            // As `StudioCaptureView`: wait for the app root's Studio load, then the same
            // break-ready state the Rail D frames show.
            let studio = dependencies.studio
            UserDefaults.standard.set(false, forKey: DisplayContinuityLaunch.probeKey)
            for _ in 0..<200 {
                switch studio.station.loadState {
                case .ready, .failed:
                    studio.dj.send(.breakReady(afterTrack: 0, includesBriefing: false, seconds: 30))
                    loaded = true
                    return
                default:
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            failure = "System vertical bars capture failed: station did not load within 10 s (\(scenario.rawValue))"
        }
    }
}
#endif
