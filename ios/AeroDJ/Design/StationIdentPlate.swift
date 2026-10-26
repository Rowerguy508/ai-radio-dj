import AeroDJCore
import SwiftUI

/// Generated station sleeve used wherever album art is missing.
///
/// The palette, monogram, angle and ring count come from `StationArtStyle` (deterministic,
/// offline). This view only draws them. It does not animate, and it never implies the DJ
/// is speaking: no level meter, no pulsing mark.
///
/// Lettering is graphic, sized to the plate. It is hidden from VoiceOver; the track and
/// station names are announced by the surrounding controls.
struct StationIdentPlate: View {
    let style: StationArtStyle
    let size: CGFloat
    var caption: String?

    /// Same curve `ArtworkView` clips the playing card to. The sleeve caption has to sit
    /// inside it, or the rounded edge cuts the station name.
    static func playingCardCornerRadius(size: CGFloat) -> CGFloat {
        size > 160 ? 26 : max(8, size * 0.2)
    }

    @Environment(\.dynamicTypeSize) private var typeSize

    private enum Tier { case mark, cover, sleeve }

    /// Queue thumbs stay a monogram. Mid sizes center it. Hero art is an editorial sleeve.
    private var tier: Tier {
        if size < 72 { .mark }
        else if size < 180 { .cover }
        else { .sleeve }
    }

    var body: some View {
        ZStack {
            fill
            if tier != .mark { dial }
            switch tier {
            case .mark: mark
            case .cover: cover
            case .sleeve: sleeve
            }
            if tier == .sleeve { innerFrame }
        }
        .frame(width: size, height: size)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityHidden(true)
    }

    // MARK: Field

    private var fill: some View {
        ZStack {
            if #available(iOS 18.0, *) {
                mesh
            } else {
                linear
            }
            // A quiet scrim so the white monogram stays legible on a bright station hue.
            LinearGradient(colors: [.black.opacity(tier == .mark ? 0.16 : 0.32),
                                    .black.opacity(0.08),
                                    .black.opacity(tier == .sleeve ? 0.46 : 0.20)],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    private var linear: some View {
        LinearGradient(colors: [style.color(0), style.color(1)],
                       startPoint: style.startPoint, endPoint: style.endPoint)
    }

    @available(iOS 18.0, *)
    private var mesh: some View {
        let wobble = Float(style.angle % 90) / 900
        let center = SIMD2<Float>(0.46 + wobble, 0.40 + wobble)
        return MeshGradient(width: 3, height: 3, points: [
            SIMD2<Float>(0, 0), SIMD2<Float>(0.5, 0), SIMD2<Float>(1, 0),
            SIMD2<Float>(0, 0.5), center, SIMD2<Float>(1, 0.55),
            SIMD2<Float>(0, 1), SIMD2<Float>(0.45, 1), SIMD2<Float>(1, 1),
        ], colors: [
            style.color(0), style.color(2), style.color(1),
            style.color(1), style.color(0), style.color(2),
            style.color(1), style.color(0), style.color(2),
        ])
    }

    /// Partial arcs, like a printed tuning scale. Count and rotation come from the style
    /// so each song is distinct. They do not move.
    private var dial: some View {
        let count = max(1, min(style.rings, 3))
        return ZStack {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .trim(from: 0.06, to: 0.40)
                    .stroke(.white.opacity(0.28 - Double(index) * 0.07),
                            style: StrokeStyle(lineWidth: max(1, size * 0.007), lineCap: .round))
                    .frame(width: size * (0.62 + CGFloat(index) * 0.16),
                           height: size * (0.62 + CGFloat(index) * 0.16))
                    .rotationEffect(.degrees(Double(style.angle) + Double(index) * 16))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .offset(x: size * 0.22, y: size * 0.22)
        .allowsHitTesting(false)
    }

    private var innerFrame: some View {
        RoundedRectangle(cornerRadius: size * 0.055, style: .continuous)
            .strokeBorder(.white.opacity(0.28), lineWidth: 1)
            .padding(size * 0.04)
            .allowsHitTesting(false)
    }

    // MARK: Lettering

    private var mark: some View {
        Text(style.monogram)
            .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.28), radius: size * 0.05, y: size * 0.012)
            .minimumScaleFactor(0.4)
            .lineLimit(1)
            .padding(size * 0.1)
            .frame(width: size, height: size)
    }

    private var cover: some View {
        Text(style.monogram)
            .font(.system(size: size * 0.34, weight: .semibold, design: .serif))
            .foregroundStyle(.white)
            .minimumScaleFactor(0.4)
            .lineLimit(1)
            .padding(size * 0.1)
            .frame(width: size, height: size)
    }

    /// Clear the continuous corner, including at AX5 where the card is shorter.
    private var sleeveInset: CGFloat {
        max(size * 0.1, Self.playingCardCornerRadius(size: size) + 8)
    }

    /// Graphic lettering. It does not grow with Dynamic Type; it wraps instead, so AX5
    /// cannot push the station name through the rounded edge.
    private var captionPointSize: CGFloat {
        let fitted = min(16, max(11, size * 0.04))
        return typeSize.isAccessibilitySize ? min(fitted, 13) : fitted
    }

    private var sleeve: some View {
        VStack(alignment: .leading, spacing: size * 0.04) {
            Text(style.monogram)
                .font(.system(size: size * 0.22, weight: .semibold, design: .serif))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            RoundedRectangle(cornerRadius: 1)
                .fill(.white.opacity(0.92))
                .frame(width: size * 0.16, height: max(2, size * 0.007))
            Spacer(minLength: 4)
            if let caption, !caption.isEmpty {
                Text(caption.uppercased())
                    .font(.system(size: captionPointSize, weight: .semibold, design: .rounded))
                    .tracking(0.35)
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 2)
                    .minimumScaleFactor(0.55)
                    .allowsTightening(true)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(sleeveInset)
        .frame(width: size, height: size, alignment: .topLeading)
    }
}

#Preview("Ident sizes") {
    let station = PlaybackFixtures.station
    let track = PlaybackFixtures.songs[0]
    HStack(alignment: .bottom, spacing: 16) {
        StationIdentPlate(style: .track(track, on: station), size: 44)
        StationIdentPlate(style: .track(track, on: station), size: 120)
        StationIdentPlate(style: .track(track, on: station), size: 280, caption: station.name)
    }
    .padding()
}
