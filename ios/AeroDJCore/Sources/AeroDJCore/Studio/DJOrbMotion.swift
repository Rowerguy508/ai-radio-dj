import Foundation

/// Pure motion for the on-air lava-lamp orb (Folded Now Playing). The SwiftUI view samples
/// `DJPresentationStore.speechLevel` once a frame, calls `DJOrbMotion.advance`, and draws the
/// returned `DJOrbFrame`. Nothing here reads or changes playback, speech or session state.
/// Unit tested on Linux. -Nova

/// How the orb is drawn.
public enum DJOrbRenderMode: Equatable, Sendable {
    /// Metal metaballs (iOS 18+ with the shader in the app's default library).
    case metaballs
    /// Reduce Motion: one still, soft circle that only breathes a little with the voice.
    /// No drift and no metaball churn.
    case still
    /// No shader (iOS 17, or the metallib is missing the function): a plain gradient circle
    /// that scales with the voice.
    case gradient
}

public enum DJOrbPolicy {
    /// Reduce Motion wins over everything, so a Reduce Motion listener never sees churn.
    public static func mode(reduceMotion: Bool, shaderAvailable: Bool) -> DJOrbRenderMode {
        if reduceMotion { return .still }
        return shaderAvailable ? .metaballs : .gradient
    }

    /// Reduce Transparency: no translucent outer glow; the orb is drawn fully opaque.
    public static func glowOpacity(reduceTransparency: Bool) -> Double {
        reduceTransparency ? 0 : 0.45
    }
}

/// One frame of the orb.
public struct DJOrbFrame: Equatable, Sendable {
    /// The eased voice level the frame was built from, 0...1.
    public var level: Float
    /// Shader time. Integrated from the drift rate, so a rate change never jumps the blobs.
    public var phase: Double
    /// Blob fatness for the shader, 0...1.
    public var blobSize: Float
    /// Blob count for the shader, fractional so the last blob grows in (1...8).
    public var blobCount: Float
    /// Whole-orb scale.
    public var scale: Double

    public init(level: Float, phase: Double, blobSize: Float, blobCount: Float, scale: Double) {
        self.level = level
        self.phase = phase
        self.blobSize = blobSize
        self.blobCount = blobCount
        self.scale = scale
    }
}

public struct DJOrbMotion: Equatable, Sendable {
    // Idle (DJ quiet, or between clips): slow, calm drift.
    public static let idleRate: Double = 0.25
    // Full voice: livelier drift.
    public static let speakingRate: Double = 1.1
    public static let idleBlobSize: Float = 0.5
    public static let speakingBlobSize: Float = 0.82
    public static let idleBlobCount: Float = 4
    public static let speakingBlobCount: Float = 5
    public static let idleScale: Double = 0.92
    public static let speakingScale: Double = 1.02
    /// Reduce Motion and the gradient fallback breathe within these.
    public static let stillScaleRange: Double = 0.04
    public static let gradientScaleRange: Double = 0.08
    /// A frame gap longer than this (backgrounded, first frame) counts as this long, so the
    /// drift never leaps and the ease still starts from where it was.
    public static let maxFrameGap: Double = 0.1
    /// Phase wraps here. Far below where Float loses the precision the shader needs.
    public static let phaseWrap: Double = 10_000

    /// Slower than Fry's meter (30 ms / 180 ms): the meter already follows syllables, the orb
    /// only needs the envelope, and the long release rides over the dip between clips.
    public private(set) var smoother = DJSpeechLevelSmoother(attack: 0.12, release: 0.45)
    public private(set) var phase: Double = 0

    public init() {}

    public var level: Float { smoother.value }

    /// Eases toward `speechLevel` over `dt` seconds and returns the frame to draw.
    @discardableResult
    public mutating func advance(speechLevel: Float, dt: Double, mode: DJOrbRenderMode) -> DJOrbFrame {
        let dt = dt.isFinite ? min(Self.maxFrameGap, max(0, dt)) : 0
        let eased = smoother.step(toward: speechLevel, dt: dt)
        let e = Double(eased)
        switch mode {
        case .metaballs:
            phase += (Self.idleRate + (Self.speakingRate - Self.idleRate) * e) * dt
            if phase >= Self.phaseWrap { phase -= Self.phaseWrap }
            return DJOrbFrame(level: eased, phase: phase,
                              blobSize: Self.idleBlobSize + (Self.speakingBlobSize - Self.idleBlobSize) * eased,
                              blobCount: Self.idleBlobCount + (Self.speakingBlobCount - Self.idleBlobCount) * eased,
                              scale: Self.idleScale + (Self.speakingScale - Self.idleScale) * e)
        case .still:
            // No phase change: nothing drifts.
            return DJOrbFrame(level: eased, phase: phase, blobSize: Self.idleBlobSize,
                              blobCount: Self.idleBlobCount, scale: 1 + Self.stillScaleRange * e)
        case .gradient:
            return DJOrbFrame(level: eased, phase: phase, blobSize: Self.idleBlobSize,
                              blobCount: Self.idleBlobCount,
                              scale: (1 - Self.gradientScaleRange / 2) + Self.gradientScaleRange * e)
        }
    }
}
