#if DEBUG
/// When the app freezes motion for UI-test screenshots (`-AERODJ_UITEST_DISABLE_ANIMATIONS YES`).
///
/// Only the Debug UI-test capture path honours the flag: the test station, in Studio capture
/// mode, in a build that allows UI-test hooks. Release passes `allowsUITestHooks: false` (the
/// app's hook is compiled only under `DEBUG`), so the flag can never change a shipped build. Like
/// the test station, this type is compiled only under `DEBUG`; CI checks the Release app.
/// The freeze itself (`CaptureMotionFreeze` in the app) disables UIKit and SwiftUI animations,
/// holds activity indicators at a fixed frame and hides the text caret, so iPhone screenshots
/// are pixel-stable between runs. -Atlas
public enum UITestAnimationFreezePolicy {
    /// UserDefaults key; launch arguments `-<key> YES` populate UserDefaults.
    public static let defaultsKey = "AERODJ_UITEST_DISABLE_ANIMATIONS"

    public static func isActive(flag: Bool, mode: AppRuntimeMode, studioCapture: Bool,
                                allowsUITestHooks: Bool) -> Bool {
        allowsUITestHooks && mode == .testStation && studioCapture && flag
    }
}
#endif
