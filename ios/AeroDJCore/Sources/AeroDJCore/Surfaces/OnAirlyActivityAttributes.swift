#if canImport(ActivityKit) && os(iOS)
import ActivityKit

/// #465 item 7: the on-air Live Activity. Shared by the app (which starts, updates and ends
/// it) and the widget extension (which draws it). No static attributes: the whole payload is
/// the display-only `NowPlayingDisplay` content state.
public struct OnAirlyActivityAttributes: ActivityAttributes {
    public typealias ContentState = NowPlayingDisplay

    public init() {}
}
#endif
