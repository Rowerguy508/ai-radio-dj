#if DEBUG
import AeroDJCore
import ObjectiveC
import SwiftUI
import UIKit

/// Debug-only: freezes motion for UI-test screenshots so the iPhone masked diff in CI
/// (`compare-iphone-screenshots.py`) is pixel-stable between runs. Honoured only when
/// `UITestAnimationFreezePolicy` says so: the test station, in Studio capture mode, with
/// `-AERODJ_UITEST_DISABLE_ANIMATIONS YES`. Release builds do not compile this file, and CI
/// checks the Release binary for its symbols (device-build job).
///
/// One hook at launch, no edits to individual views:
/// - `UIView.setAnimationsEnabled(false)`: UIKit animations (sheets, rotation, keyboard) jump
///   to their end state and their completions still run.
/// - `CaptureMotionFreezeRoot` on the window root: every SwiftUI transaction has its
///   animation removed and `disablesAnimations` set, so `.animation(_:value:)` adds none.
/// - Activity indicators (SwiftUI's circular `ProgressView` is one): the indicator's layer
///   clock is stopped at 0, so the spinner is drawn at the same frame every run while it is
///   still "animating" for SwiftUI and VoiceOver.
/// - Text fields and text views report a zero caret rect, so no blinking caret is drawn.
///   Keyboard autocorrection and spell-check underlines are switched off on the simulator by
///   `ios/scripts/settle-simulator-keyboard.sh` in CI.
/// Layouts and sizes are unchanged: nothing here adds, removes or resizes a view. -Atlas
enum CaptureMotionFreeze {
    @MainActor private static var installed = false

    static func isRequested(mode: AppRuntimeMode, defaults: UserDefaults = .standard) -> Bool {
        UITestAnimationFreezePolicy.isActive(
            flag: defaults.bool(forKey: UITestAnimationFreezePolicy.defaultsKey),
            mode: mode,
            studioCapture: StudioCapture.isRequested(mode: mode, defaults: defaults),
            allowsUITestHooks: true)
    }

    /// Call once from `AeroDJApp.init`. Returns whether the freeze is on for this launch.
    @MainActor @discardableResult
    static func installIfRequested(mode: AppRuntimeMode) -> Bool {
        guard isRequested(mode: mode) else { return false }
        guard !installed else { return true }
        installed = true
        UIView.setAnimationsEnabled(false)
        swizzle(UIActivityIndicatorView.self, #selector(UIView.didMoveToWindow),
                #selector(UIActivityIndicatorView.aerodjFreeze_didMoveToWindow))
        swizzle(UITextField.self, #selector(UITextField.caretRect(for:)),
                #selector(UITextField.aerodjFreeze_caretRect(for:)))
        swizzle(UITextView.self, #selector(UITextView.caretRect(for:)),
                #selector(UITextView.aerodjFreeze_caretRect(for:)))
        return true
    }

    /// Exchanges two instance methods on `cls` only. If `cls` merely inherits `original`
    /// (UIActivityIndicatorView and `didMoveToWindow`), the method is added to `cls` first,
    /// so the superclass (every other UIView) is never changed.
    private static func swizzle(_ cls: AnyClass, _ original: Selector, _ replacement: Selector) {
        guard let originalMethod = class_getInstanceMethod(cls, original),
              let replacementMethod = class_getInstanceMethod(cls, replacement) else {
            assertionFailure("CaptureMotionFreeze: \(cls) is missing \(original) or \(replacement)")
            return
        }
        if class_addMethod(cls, original, method_getImplementation(replacementMethod),
                           method_getTypeEncoding(replacementMethod)) {
            class_replaceMethod(cls, replacement, method_getImplementation(originalMethod),
                                method_getTypeEncoding(originalMethod))
        } else {
            method_exchangeImplementations(originalMethod, replacementMethod)
        }
    }
}

/// Applied to the window root when the freeze is on; a no-op otherwise.
struct CaptureMotionFreezeRoot: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        } else {
            content
        }
    }
}

extension UIActivityIndicatorView {
    /// Runs as `didMoveToWindow` once swizzled. Stopping the layer clock at 0 renders every
    /// animation on the indicator at its first frame, whenever it was added.
    @objc func aerodjFreeze_didMoveToWindow() {
        aerodjFreeze_didMoveToWindow() // the original implementation, after the exchange
        layer.speed = 0
        layer.timeOffset = 0
    }
}

extension UITextField {
    @objc func aerodjFreeze_caretRect(for position: UITextPosition) -> CGRect { .zero }
}

extension UITextView {
    @objc func aerodjFreeze_caretRect(for position: UITextPosition) -> CGRect { .zero }
}
#endif
