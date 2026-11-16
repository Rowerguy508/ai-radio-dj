#if DEBUG
import AeroDJCore
import SwiftUI

/// Regular-width stand-in for the arrangement panes. Same 640 × 820 pt as
/// `DuoWideCaptureContainer`, with `horizontalSizeClass` regular so the listen
/// player splits. The compact-class container is a different scenario and stays
/// on the existing columns.
struct ArrangementCaptureContainer: View {
    let studio: StudioPresentationModel

    var body: some View {
        let size = StudioCapture.duoWideContainerSize
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        ZStack {
            Color(white: 0.14)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            NavigationStack {
                PlayingScreen(station: PlaybackFixtures.station, access: .authorized,
                              snapshot: StudioCaptureScenario.duoArrangement.snapshot,
                              actions: .preview,
                              search: .captureOffline,
                              studio: studio, isTestStation: true,
                              timeSource: .fixture)
            }
            .environment(\.horizontalSizeClass, .regular)
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .overlay { shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 1).allowsHitTesting(false) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("capture.duoContainer")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
#endif
