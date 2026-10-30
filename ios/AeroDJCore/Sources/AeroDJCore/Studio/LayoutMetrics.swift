import Foundation

/// Width class as SwiftUI reports it, without importing SwiftUI (so it is tested on Linux).
/// `unspecified` is SwiftUI's nil size class: it never counts as regular.
public enum LayoutWidthClass: Equatable, Sendable {
    case compact
    case regular
    case unspecified
}

/// The device idiom, without importing UIKit. Everything that is not an iPad is `.phone` here,
/// so an unknown idiom takes the iPhone path.
public enum LayoutIdiom: Equatable, Sendable {
    case phone
    case pad
}

/// iPad-only layout values (v1 ships on iPhone and iPad, owner decision 2026-10-29). The rule
/// is that the iPhone never changes: every value here is `nil` unless the device is an iPad
/// AND the width class is regular. `nil` means "no iPad change": the view keeps its existing
/// code path, the one the iPhone has always taken.
///
/// Why both gates: the width class alone is not enough. An iPhone Plus/Max in landscape and the
/// unfolded Duo both report a regular width class, and their layout must not move. The idiom
/// alone is not enough either: an iPad in Split View or Slide Over is compact and must take the
/// iPhone path, unchanged.
public struct LayoutMetrics: Equatable, Sendable {
    /// Readable column for iPad regular width: roughly the width of a comfortable line of body
    /// text, and the width a form sheet gets on the larger iPads.
    public static let iPadReadableMaxWidth: Double = 640

    /// The cap for content that would otherwise run edge to edge, or `nil` (no cap: the
    /// existing layout, untouched).
    public let readableMaxWidth: Double?

    public init(widthClass: LayoutWidthClass, idiom: LayoutIdiom) {
        let iPadRegular = idiom == .pad && widthClass == .regular
        readableMaxWidth = iPadRegular ? Self.iPadReadableMaxWidth : nil
    }

    /// True only for an iPad at regular width. Views branch on this; the `false` branch is the
    /// iPhone path and must stay byte-for-byte what it was.
    public var usesIPadLayout: Bool { readableMaxWidth != nil }
}
