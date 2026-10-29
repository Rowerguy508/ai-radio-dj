import AeroDJCore
import SwiftUI

/// "Couldn't start that station" (-Nova). A short glass capsule over the station split when the
/// listener's created-station tap could not start anything (`StationStartNotice`, tested in core).
/// - Never blocks taps: no hit testing, no buttons. It dismisses itself after 3 s; the next row tap
///   clears it sooner.
/// - VoiceOver hears it once as an announcement when it appears.
/// - Reduce Motion: fades only, no slide.
struct StationStartToast: View {
    let notice: StationStartNotice
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let message = notice.message {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .aeroGlass(Capsule(), fallback: AnyShapeStyle(.regularMaterial),
                               hairline: Color.primary.opacity(0.12))
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("station.startToast")
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.35), value: notice.message)
        .task(id: notice.showID) {
            let shown = notice.showID
            guard notice.message != nil else { return }
            AccessibilityNotification.Announcement(StationStartNotice.couldNotStart).post()
            try? await Task.sleep(for: StationStartNotice.displayDuration)
            guard !Task.isCancelled else { return }
            notice.dismiss(showID: shown)
        }
    }
}

#if DEBUG
@MainActor private func previewNotice() -> StationStartNotice {
    let notice = StationStartNotice()
    notice.finish(tap: notice.beginTap(), outcome: .notStarted(.notReadyInTime))
    return notice
}

#Preview("Station start toast") {
    Color(.systemBackground)
        .overlay(alignment: .top) { StationStartToast(notice: previewNotice()) }
}
#endif
