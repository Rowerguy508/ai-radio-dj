/// Which dependency set the app composes at launch.
///
/// Pure and platform-independent, so the rule is tested on every CI platform.
/// `allowsTestStation` is true only in Debug builds: Release does not compile
/// the test station, so it can never be activated, whatever the launch arguments.
public enum AppRuntimeMode: String, Equatable, Sendable {
    /// Real EventKit calendar, on-device voice, live station configuration.
    case live
    /// Synthetic fixtures, on-device voice only at $0, fixture station configuration.
    case testStation

    public static func resolve(testStationFlag: Bool, allowsTestStation: Bool) -> AppRuntimeMode {
        testStationFlag && allowsTestStation ? .testStation : .live
    }
}
