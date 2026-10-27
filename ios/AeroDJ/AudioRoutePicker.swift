import AVKit
import SwiftUI

/// System AirPlay / audio-output route picker for Now Playing.
/// Wraps `AVRoutePickerView` as a reusable leaf; layout and placement are Nova's.
/// Does not observe or log route names or device details.
/// -Atlas
@MainActor
struct AudioRoutePicker: UIViewRepresentable {
    /// Idle control tint. Defaults to light type for the Now Playing slab.
    var tint: Color = AeroDJPalette.onMediaLight
    /// Tint while an external route (e.g. AirPlay) is active.
    var activeTint: Color = AeroDJPalette.accentText

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        applyTints(to: picker)
        picker.accessibilityLabel = "Audio output"
        picker.accessibilityIdentifier = "nowPlaying.routePicker"
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        applyTints(to: uiView)
    }

    private func applyTints(to picker: AVRoutePickerView) {
        picker.tintColor = UIColor(tint)
        picker.activeTintColor = UIColor(activeTint)
    }
}

#if DEBUG
#Preview("Audio route picker") {
    ZStack {
        AeroDJPalette.slab.ignoresSafeArea()
        AudioRoutePicker()
            .frame(width: 44, height: 44)
    }
}
#endif
