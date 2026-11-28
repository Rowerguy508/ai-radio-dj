import SwiftUI
import WidgetKit

/// #465 item 7 (-Nova): the OnAirly widget extension. Both surfaces read only the display-only
/// `NowPlayingDisplay` (station, track, artist, generated art, playback state, on-air label).
@main
struct OnAirlyWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        OnAirLiveActivity()
    }
}
