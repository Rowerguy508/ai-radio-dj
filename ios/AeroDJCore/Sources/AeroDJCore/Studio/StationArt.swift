import Foundation

/// Deterministic fallback art for tracks without album artwork, and the station's colour
/// atmosphere. Pure and stable across launches and devices: the same seed always gives the
/// same palette and monogram (FNV-1a, not `hashValue`, which is randomised per process).
/// No network, no image assets.
public struct StationArtStyle: Equatable, Sendable {
    /// Three hues in 0..<1: the base, a neighbour for the gradient, and an accent.
    public let hues: [Double]
    /// Saturation and brightness for the base colour; the view derives the rest.
    public let saturation: Double
    public let brightness: Double
    /// One or two uppercase letters, or a music note when there is nothing to abbreviate.
    public let monogram: String
    /// Gradient direction in degrees, a multiple of 45.
    public let angle: Int
    /// 2–4 concentric "radio" rings behind the monogram.
    public let rings: Int

    /// Station-level style (the room's atmosphere).
    public static func station(_ station: StationRef?) -> StationArtStyle {
        guard let station else { return make(seed: noStationSeed, label: AppName.display) }
        return make(seed: "station:" + station.id, label: station.name)
    }

    /// Hash seed for the no-station art. Kept from before the OnAirly rename so the palette,
    /// angle and rings don't move; only the monogram follows `AppName.display`.
    static let noStationSeed = "station:" + "AeroDJ" // not user-visible: hash seed


    /// Fallback cover for one track on one station: the station's hue family, varied per track,
    /// so a queue of artwork-less songs still reads as one station but each song is distinct.
    public static func track(_ track: TrackInfo, on station: StationRef?) -> StationArtStyle {
        let base = Self.station(station)
        let h = fnv1a("track:" + track.id + "|" + track.title + "|" + track.artistName)
        let shift = (Double(h % 1000) / 1000.0 - 0.5) * 0.16          // ±0.08 around the station hue
        let hue0 = wrap(base.hues[0] + shift)
        return StationArtStyle(
            hues: [hue0, wrap(hue0 + 0.07 + Double((h >> 10) % 50) / 1000.0), wrap(hue0 + 0.45)],
            saturation: base.saturation, brightness: base.brightness,
            monogram: monogram(track.title),
            angle: Int((h >> 20) % 8) * 45,
            rings: 2 + Int((h >> 24) % 3))
    }

    public static func make(seed: String, label: String) -> StationArtStyle {
        let h = fnv1a(seed)
        let hue0 = Double(h % 360) / 360.0
        return StationArtStyle(
            hues: [hue0, wrap(hue0 + 0.08 + Double((h >> 9) % 40) / 1000.0), wrap(hue0 + 0.42)],
            saturation: 0.55 + Double((h >> 16) % 20) / 100.0,          // 0.55–0.74
            brightness: 0.70 + Double((h >> 24) % 15) / 100.0,          // 0.70–0.84
            monogram: monogram(label),
            angle: Int((h >> 32) % 8) * 45,
            rings: 2 + Int((h >> 40) % 3))
    }

    /// First letters of the first two words that start with a letter or digit.
    public static func monogram(_ text: String) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
        let letters = words.compactMap { $0.first(where: { $0.isLetter || $0.isNumber }) }.prefix(2)
        return letters.isEmpty ? "♪" : String(letters).uppercased()
    }

    static func wrap(_ x: Double) -> Double { let r = x.truncatingRemainder(dividingBy: 1); return r < 0 ? r + 1 : r }

    static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x0000_0100_0000_01B3 }
        return h
    }
}
