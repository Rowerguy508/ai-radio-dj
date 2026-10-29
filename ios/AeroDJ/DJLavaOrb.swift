//
//  DJLavaOrb.swift
//  AeroDJ
//
//  The on-air lava-lamp orb in the Folded art card. Its colour is the album art itself
//  (blurred `BleedArtwork`, masked by metaballs), so nothing here picks a colour; with no
//  art it is the station ident's palette, and with no track a neutral grey. Never amber.
//  Size and drift follow `DJPresentationStore.speechLevel` through `DJOrbMotion` (eased,
//  never snapped); quiet moments get a slow idle drift. Reduce Motion: a still circle that
//  breathes slightly. Reduce Transparency: no translucent glow. iOS 17 or a missing shader:
//  a plain gradient circle. Decorative, so hidden from VoiceOver.
//
//  UI only. It reads `speechLevel`; it never touches playback, speech or the session.
//
//  The metaball rendering is adapted from SWMetaballs.swift (ShipSwift,
//  signerlabs/shipswift-skills) by Nova for AeroDJ: one cluster renderer, no palette,
//  controls sheet or fountain style, and time integrated in `DJOrbMotion`.
//
//  MIT License
//
//  Copyright (c) signerlabs / ShipSwift (https://github.com/signerlabs/shipswift-skills)
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

import AeroDJCore
import Metal
import SwiftUI

/// Whether the orb's Metal function made it into the app's default library. Checked once.
/// A build without the .metal file (or a stripped metallib) draws the gradient fallback
/// instead of an empty `colorEffect`.
enum DJLavaOrbShader {
    static let functionName = "aeroDJOrbMetaballs"

    static let isAvailable: Bool = {
        guard let device = MTLCreateSystemDefaultDevice(),
              let library = device.makeDefaultLibrary() else { return false }
        return library.functionNames.contains(functionName)
    }()
}

/// Per-view motion state. A reference so the timeline can advance it each frame without
/// invalidating the view; it is never observed.
@MainActor
private final class DJLavaOrbDriver {
    private var motion = DJOrbMotion()
    private var lastDate: Date?

    func frame(at date: Date, speechLevel: Float, mode: DJOrbRenderMode) -> DJOrbFrame {
        let dt = lastDate.map { date.timeIntervalSince($0) } ?? 0
        lastDate = date
        return motion.advance(speechLevel: speechLevel, dt: dt, mode: mode)
    }
}

struct DJLavaOrb: View {
    let track: TrackInfo?
    let station: StationRef?
    /// Fry's level source. Nil (previews) is a quiet orb: idle drift only.
    let levels: DJPresentationStore?

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var driver = DJLavaOrbDriver()

    private var reduceMotion: Bool {
        #if DEBUG
        systemReduceMotion || UserDefaults.standard.bool(forKey: StudioCapture.reduceMotionKey)
        #else
        systemReduceMotion
        #endif
    }

    private var shaderAvailable: Bool {
        if #available(iOS 18.0, *) { return DJLavaOrbShader.isAvailable }
        return false
    }

    private var mode: DJOrbRenderMode {
        DJOrbPolicy.mode(reduceMotion: reduceMotion, shaderAvailable: shaderAvailable)
    }

    var body: some View {
        // 60 fps while drifting; 30 fps is plenty for the still and gradient circles.
        let interval: Double = mode == .metaballs ? 1.0 / 60 : 1.0 / 30
        TimelineView(.animation(minimumInterval: interval)) { context in
            let f = driver.frame(at: context.date, speechLevel: levels?.speechLevel ?? 0, mode: mode)
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height)
                orb(frame: f, side: side)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func orb(frame f: DJOrbFrame, side: CGFloat) -> some View {
        let glow = DJOrbPolicy.glowOpacity(reduceTransparency: reduceTransparency)
        ZStack {
            if glow > 0 {
                // One soft halo of the same art; dropped under Reduce Transparency.
                fill(side: side)
                    .mask { shape(frame: f) }
                    .blur(radius: side * 0.12)
                    .opacity(glow * (0.6 + 0.4 * Double(f.level)))
            }
            fill(side: side)
                .mask { shape(frame: f) }
                .overlay {
                    // Neutral sheen for depth. White, not a hue, so colour stays the art's.
                    RadialGradient(colors: [.white.opacity(0.22), .clear],
                                   center: UnitPoint(x: 0.36, y: 0.30), startRadius: 0, endRadius: side * 0.45)
                        .mask { shape(frame: f) }
                }
        }
        .scaleEffect(f.scale)
    }

    /// The art's own colours: heavily blurred so the cover reads as colour fields, not an image.
    @ViewBuilder
    private func fill(side: CGFloat) -> some View {
        if let track {
            BleedArtwork(track: track, station: station)
                .blur(radius: max(8, side * 0.10), opaque: true)
                .saturation(1.15)
        } else {
            // Neutral fallback: no art and no track to derive a palette from.
            LinearGradient(colors: [Color(white: 0.55), Color(white: 0.28)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    /// The silhouette: metaballs, or one soft circle.
    @ViewBuilder
    private func shape(frame f: DJOrbFrame) -> some View {
        switch mode {
        case .metaballs:
            if #available(iOS 18.0, *) {
                Rectangle()
                    .fill(.white)
                    .colorEffect(ShaderLibrary.default.aeroDJOrbMetaballs(
                        .boundingRect, .float(Float(f.phase)), .float(f.blobCount), .float(f.blobSize)))
            } else {
                circle
            }
        case .still, .gradient:
            circle
        }
    }

    /// Plain gradient circle: solid core, soft edge, sized to its frame.
    private var circle: some View {
        GeometryReader { geo in
            let r = min(geo.size.width, geo.size.height) / 2 * 0.86
            Circle()
                .fill(RadialGradient(stops: [.init(color: .white, location: 0),
                                             .init(color: .white, location: 0.62),
                                             .init(color: .white.opacity(0), location: 1)],
                                     center: .center, startRadius: 0, endRadius: max(1, r)))
                .frame(width: r * 2, height: r * 2)
                .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

#if DEBUG
#Preview("Lava orb, quiet") {
    DJLavaOrb(track: PlaybackFixtures.songs[0], station: PlaybackFixtures.station, levels: nil)
        .frame(width: 240, height: 240)
        .padding(40)
        .background(FoldedStyle.background)
}
#endif
