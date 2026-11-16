import AeroDJCore
import SwiftUI
import WidgetKit

/// #465 item 7 / #486 / #539: the Live Activity (05). The Dynamic Island shows the station,
/// the song, the generated art, the On Air tally and the Ready line. The lock screen and
/// StandBy share one view: while system Now Playing already has the player, that view is DJ
/// state only (On Air / "DJ break after this song") and does not repeat title, artist,
/// artwork or transport. The tally reads `onAirLabel` (confirmed `.speaking` only). The Ready
/// line reads `readyLabel` and is never shown as On Air. This view only reads published
/// state: the app starts, updates and ends the activity fire-and-forget, so it can never
/// drive or delay playback.
struct OnAirLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: OnAirlyActivityAttributes.self) { context in
            // `context.state` stays the full display for the Dynamic Island below.
            // The lock-screen view decides what of it is safe to draw (#539).
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
/// StandBy uses this same view. While system Now Playing owns the lock screen it shows only
/// DJ state, so it does not repeat the song. The Now Playing widget remains the StandBy
/// clock-radio face for the track. The Dynamic Island does not use this view.
struct LockScreenActivityView: View {
    let display: NowPlayingDisplay

    var body: some View {
        let shown = display.lockScreenPresentation
        Group {
            if display.lockScreenShowsPlaybackChrome {
                playbackCard(shown)
            } else {
                djState(shown)
            }
        }
    }

    /// On Air and the ready line only. No title, artist, artwork, station or transport.
    private func djState(_ shown: NowPlayingDisplay) -> some View {
        VStack(alignment: .leading, spacing: CGFloat(LiveActivityLayout.rowSpacing)) {
            if let label = shown.onAirLabel {
                OnAirTally(label: label)
            }
            if let ready = shown.readyLabel {
                ReadyCaption(label: ready)
                    .frame(height: CGFloat(LiveActivityLayout.readyLineHeight), alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(CGFloat(LiveActivityLayout.padding))
    }

    /// The only card, used before system Now Playing is up (`.starting`).
    private func playbackCard(_ shown: NowPlayingDisplay) -> some View {
        VStack(alignment: .leading, spacing: CGFloat(LiveActivityLayout.rowSpacing)) {
            HStack(spacing: 8) {
                Text(AppName.display)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                if let label = shown.onAirLabel {
                    OnAirTally(label: label)
                } else if let caption = shown.state.caption {
                    Text(caption)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(WidgetPalette.secondaryText)
                }
            }
            .frame(height: CGFloat(LiveActivityLayout.headerHeight))
            HStack(spacing: 12) {
                DisplayArtView(art: shown.art, size: CGFloat(LiveActivityLayout.artSize)).privateField()
                VStack(alignment: .leading, spacing: 2) {
                    Text(shown.track ?? "")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text([shown.artist, shown.station].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(WidgetPalette.secondaryText)
                }
                .lineLimit(1)
                .privateField()
                Spacer(minLength: 0)
            }
            .frame(height: CGFloat(LiveActivityLayout.artSize))
            if let ready = shown.readyLabel {
                ReadyCaption(label: ready)
                    .frame(height: CGFloat(LiveActivityLayout.readyLineHeight), alignment: .leading)
            }
        }
        .padding(CGFloat(LiveActivityLayout.padding))
        .frame(maxHeight: CGFloat(LiveActivityLayout.maxHeight))
    }
}
