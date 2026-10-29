import Foundation

/// The DJ voice level that drives the on-air orb (-Fry).
///
/// Pure parts only, so they run on Linux. The app reads a level from the clip player
/// (`InterludePlaybackAdapter`, AVAudioPlayer metering), maps it here, smooths it here,
/// and publishes it with `DJPresentationStore.updateSpeechLevel(_:afterTrack:)`. The store
/// keeps it at exactly 0 unless the state is `.speaking`.
public enum DJSpeechLevelMapping {
    /// The quietest level that still moves the orb. At or below this, the level is 0.
    public static let floorDBFS: Float = -50

    /// Maps a dBFS reading to 0...1. `floorDBFS` or lower is 0, 0 dBFS or higher is 1,
    /// linear in dB between. NaN is 0.
    public static func level(dBFS: Float, floor: Float = floorDBFS) -> Float {
        guard !dBFS.isNaN, floor < 0 else { return 0 }
        if dBFS <= floor { return 0 }
        if dBFS >= 0 { return 1 }
        return (dBFS - floor) / -floor
    }

    /// dBFS for a linear RMS value (1.0 is full scale). 0 or less is -infinity.
    public static func dBFS(rms: Float) -> Float {
        guard rms.isFinite else { return rms == .infinity ? .infinity : -.infinity }
        guard rms > 0 else { return -.infinity }
        return 20 * log10(rms)
    }

    /// Maps a linear RMS value to 0...1.
    public static func level(rms: Float, floor: Float = floorDBFS) -> Float {
        level(dBFS: dBFS(rms: rms), floor: floor)
    }

    /// RMS of one buffer of samples. Empty is 0. Does not allocate.
    public static func rms(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }
}

/// One-pole attack/release smoothing. A rising level follows fast (`attack`), a falling
/// level decays more slowly (`release`), so the orb jumps with a syllable and eases off.
public struct DJSpeechLevelSmoother: Equatable, Sendable {
    /// Time constants, in seconds.
    public let attack: Double
    public let release: Double
    public private(set) var value: Float = 0

    public init(attack: Double = 0.03, release: Double = 0.18) {
        self.attack = max(0, attack)
        self.release = max(0, release)
    }

    /// Moves toward `target` (clamped to 0...1) over `dt` seconds and returns the new value.
    @discardableResult
    public mutating func step(toward target: Float, dt: Double) -> Float {
        let target = target.isFinite ? min(1, max(0, target)) : 0
        let tau = target > value ? attack : release
        let dt = dt.isFinite ? max(0, dt) : 0
        let alpha: Float = tau == 0 ? 1 : Float(1 - exp(-dt / tau))
        value += (target - value) * alpha
        value = min(1, max(0, value))
        return value
    }

    public mutating func reset() { value = 0 }
}

/// Mapping plus smoothing, plus the ~30 Hz publish interval the app uses.
public struct DJSpeechLevelMeter: Equatable, Sendable {
    /// About 30 updates a second.
    public static let interval: Double = 1.0 / 30
    public private(set) var smoother: DJSpeechLevelSmoother

    public init(smoother: DJSpeechLevelSmoother = DJSpeechLevelSmoother()) {
        self.smoother = smoother
    }

    public var level: Float { smoother.value }

    /// One reading in dBFS (AVAudioPlayer `averagePower`). Returns the smoothed level.
    @discardableResult
    public mutating func sample(dBFS: Float, dt: Double = interval) -> Float {
        smoother.step(toward: DJSpeechLevelMapping.level(dBFS: dBFS), dt: dt)
    }

    /// One reading as linear RMS (an engine tap). Returns the smoothed level.
    @discardableResult
    public mutating func sample(rms: Float, dt: Double = interval) -> Float {
        smoother.step(toward: DJSpeechLevelMapping.level(rms: rms), dt: dt)
    }

    public mutating func reset() { smoother.reset() }
}
