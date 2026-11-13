import AeroDJCore
import Foundation
import SwiftUI

// Shared pieces for the widget and the Live Activity (mockups 04, 04b and 05).

/// Station, track, artist and art are redacted while the device is locked: `.privacySensitive()`
/// is on unless a caller opts out, which nothing in this extension does (04b).
struct PrivateField: ViewModifier {
    var isPrivate = true

    func body(content: Content) -> some View {
        content.privacySensitive(isPrivate)
    }
}

extension View {
    /// Redacted while locked. See `NowPlayingDisplay.privacySensitiveFields`.
    func privateField() -> some View { modifier(PrivateField()) }
}

enum WidgetPalette {
    static let background = Color(red: 0.05, green: 0.07, blue: 0.08)
    static let stationLabel = Color(red: 0.24, green: 0.84, blue: 0.75)
    static let tallyDot = Color(red: 1.0, green: 0.23, blue: 0.19)
    static let tallyText = Color(red: 1.0, green: 0.45, blue: 0.40)
    static let secondaryText = Color.white.opacity(0.7)
}

extension NowPlayingDisplay.Art {
    func color(_ index: Int) -> Color {
        guard !hues.isEmpty else { return .gray }
        return Color(hue: hues[index % hues.count], saturation: saturation, brightness: brightness)
    }

    var startPoint: UnitPoint {
        let radians = Double(angle) * .pi / 180
        return UnitPoint(x: 0.5 - cos(radians) / 2, y: 0.5 - sin(radians) / 2)
    }

    var endPoint: UnitPoint {
        let radians = Double(angle) * .pi / 180
        return UnitPoint(x: 0.5 + cos(radians) / 2, y: 0.5 + sin(radians) / 2)
    }
}

/// The generated cover: the station's gradient and the song's monogram. No image fetch.
struct DisplayArtView: View {
    let art: NowPlayingDisplay.Art?
    let size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
        ZStack {
            if let art {
                LinearGradient(colors: [art.color(0), art.color(1)], startPoint: art.startPoint, endPoint: art.endPoint)
                Text(art.monogram)
                    .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .minimumScaleFactor(0.5)
            } else {
                Color.white.opacity(0.12)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .accessibilityHidden(true)
    }
}

/// The tally light. Shown only when the display carries `DJStudioState.onAirLabel`, which is
/// non-nil only for a confirmed `.speaking`. Not privacy-sensitive: it stays visible (04b).
struct OnAirTally: View {
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(WidgetPalette.tallyDot)
                .frame(width: 8, height: 8)
            Text(label.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(WidgetPalette.tallyText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

extension NowPlayingDisplay.State {
    /// Short state caption; nil while playing (the art and title say enough).
    var caption: String? {
        switch self {
        case .playing: nil
        case .paused: "Paused"
        case .starting: "Starting"
        case .stopped: "Not playing"
        }
    }
}
