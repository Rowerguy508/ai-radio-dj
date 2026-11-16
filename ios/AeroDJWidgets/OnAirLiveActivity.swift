import AeroDJCore
import SwiftUI
import WidgetKit

/// #465 item 7 / #486: the Live Activity (05). Lock screen, StandBy and the Dynamic Island
/// show the station, the song, the generated art, the On Air tally and the Ready line,
/// nothing else. The tally reads `onAirLabel` (confirmed `.speaking` only). The Ready line
/// reads `readyLabel` ("DJ break after this song") and is never shown as On Air. This view
/// only reads published state: the app starts, updates and ends the activity fire-and-forget,
/// so it can never drive or delay playback.
struct OnAirLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: OnAirlyActivityAttributes.self) { context in
            LockScreenActivityView(display: context.state)
                .activityBackgroundTint(WidgetPalette.background.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    DisplayArtView(art: context.state.art, size: 52).privateField()
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.track ?? AppName.display)
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text(context.state.artist ?? "")
                            .font(.subheadline)
                            .foregroundStyle(WidgetPalette.secondaryText)
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .privateField()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(context.state.art?.color(0) ?? WidgetPalette.stationLabel)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text(context.state.station ?? "")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .privateField()
                        Spacer(minLength: 0)
                        if let label = context.state.onAirLabel {
                            OnAirTally(label: label)
                        } else if let ready = context.state.readyLabel {
                            ReadyCaption(label: ready)
                        }
                    }
                }
            } compactLeading: {
                Circle()
                    .fill(context.state.art?.color(0) ?? WidgetPalette.stationLabel)
                    .frame(width: 12, height: 12)
                    .accessibilityLabel(AppName.display)
            } compactTrailing: {
                if let label = context.state.onAirLabel {
                    Circle()
                        .fill(WidgetPalette.tallyDot)
                        .frame(width: 10, height: 10)
                        .accessibilityLabel(label)
                }
            } minimal: {
                Circle()
                    .fill(context.state.isOnAir ? WidgetPalette.tallyDot : (context.state.art?.color(0) ?? WidgetPalette.stationLabel))
                    .frame(width: 10, height: 10)
                    .accessibilityLabel(context.state.onAirLabel ?? context.state.readyLabel ?? AppName.display)
            }
        }
    }
}

/// Lock screen and StandBy presentation. Built from `LiveActivityLayout`, whose total stays
/// under the 160 pt the system allows before truncating (NowPlayingDisplayTests).
struct LockScreenActivityView: View {
    let display: NowPlayingDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: CGFloat(LiveActivityLayout.rowSpacing)) {
            HStack(spacing: 8) {
                Text(AppName.display)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                if let label = display.onAirLabel {
                    OnAirTally(label: label)
                } else if let caption = display.state.caption {
                    Text(caption)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(WidgetPalette.secondaryText)
                }
            }
            .frame(height: CGFloat(LiveActivityLayout.headerHeight))
            HStack(spacing: 12) {
                DisplayArtView(art: display.art, size: CGFloat(LiveActivityLayout.artSize)).privateField()
                VStack(alignment: .leading, spacing: 2) {
                    Text(display.track ?? "")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text([display.artist, display.station].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(WidgetPalette.secondaryText)
                }
                .lineLimit(1)
                .privateField()
                Spacer(minLength: 0)
            }
            .frame(height: CGFloat(LiveActivityLayout.artSize))
            if let ready = display.readyLabel {
                ReadyCaption(label: ready)
                    .frame(height: CGFloat(LiveActivityLayout.readyLineHeight), alignment: .leading)
            }
        }
        .padding(CGFloat(LiveActivityLayout.padding))
        .frame(maxHeight: CGFloat(LiveActivityLayout.maxHeight))
    }
}
