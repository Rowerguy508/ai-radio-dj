import AeroDJCore
import SwiftUI
import UIKit

/// iPad support (-Nova). The one bridge from SwiftUI/UIKit to `LayoutMetrics`, the pure gate
/// in AeroDJCore that the Linux tests pin. A view asks `LayoutMetrics(horizontalSizeClass)`;
/// a `nil` value means "no iPad change: take the existing iPhone code path, untouched".
extension LayoutIdiom {
    /// Fixed for the life of the process. Anything that is not an iPad counts as a phone,
    /// so an iPhone (any size, any orientation) and the Duo can never get an iPad value.
    @MainActor static var current: LayoutIdiom {
        UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone
    }
}

extension LayoutWidthClass {
    /// SwiftUI's nil size class maps to `unspecified`, which never counts as regular.
    init(_ sizeClass: UserInterfaceSizeClass?) {
        switch sizeClass {
        case .regular: self = .regular
        case .compact: self = .compact
        default: self = .unspecified
        }
    }
}

extension LayoutMetrics {
    /// iPad at regular width only. Compact width (every iPhone in portrait, an iPad in Split
    /// View or Slide Over) and a regular-width phone (Plus/Max landscape, open Duo) get `nil`.
    @MainActor init(_ horizontalSizeClass: UserInterfaceSizeClass?) {
        self.init(widthClass: LayoutWidthClass(horizontalSizeClass), idiom: .current)
    }
}
