import AeroDJCore
import SwiftUI
import WidgetKit

/// #465 item 7: the Now Playing widget. `systemSmall` is the StandBy clock-radio face (04, 04b);
/// `systemMedium` is the Home Screen version. It reads the one display-only value the app writes
/// to the existing App Group (`NowPlayingDisplayStore`), and never shows On Air: its timeline
/// can't follow a 30-second break, so the live tally is the Live Activity's job.
struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: NowPlayingDisplayStore.widgetKind, provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetView(display: entry.display)
                .containerBackground(for: .widget) {
                    ZStack {
                        WidgetPalette.background
                        if let art = entry.display?.art {
                            RadialGradient(colors: [art.color(0).opacity(0.35), .clear],
                                           center: .topTrailing, startRadius: 0, endRadius: 220)
                        }
                    }
                }
        }
        .configurationDisplayName("Now Playing")
        .description("Your OnAirly station and song. Works in StandBy.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let display: NowPlayingDisplay?
}

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: Date(), display: .widgetPlaceholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : Self.current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        // The app reloads this timeline when the station, song or playback state changes.
        completion(Timeline(entries: [Self.current()], policy: .never))
    }

    static func current() -> NowPlayingEntry {
        let data = UserDefaults(suiteName: NowPlayingDisplayStore.appGroupID)?
            .data(forKey: NowPlayingDisplayStore.defaultsKey)
        // `decode` drops anything that isn't exactly a display value; the widget copy never has
        // an on-air label, and the view ignores one anyway.
        return NowPlayingEntry(date: Date(), display: NowPlayingDisplayStore.decode(data)?.widgetCopy)
    }
}

extension NowPlayingDisplay {
    /// Gallery and placeholder only. Fictional names from the approved mockups.
    static let widgetPlaceholder = NowPlayingDisplay(
        station: "Morning Calm", track: "Tidewater", artist: "Lumen Harbor",
        art: Art(hues: [0.47, 0.55, 0.05], saturation: 0.6, brightness: 0.75, monogram: "T", angle: 135),
        state: .playing, onAirLabel: nil)
}

struct NowPlayingWidgetView: View {
    let display: NowPlayingDisplay?
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let display, !display.isEmpty {
            switch family {
            case .systemMedium:
                HStack(alignment: .center, spacing: 14) {
                    DisplayArtView(art: display.art, size: 96).privateField()
                    details(display, titleFont: .title3)
                    Spacer(minLength: 0)
                }
            default:
                VStack(alignment: .leading, spacing: 8) {
                    DisplayArtView(art: display.art, size: 52).privateField()
                    Spacer(minLength: 0)
                    details(display, titleFont: .headline)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(AppName.display)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Start a station to see it here.")
                    .font(.caption)
                    .foregroundStyle(WidgetPalette.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }

    /// STATION label, station, song and artist. Everything but the label and the state is
    /// redacted while locked. No DJ text of any kind.
    private func details(_ display: NowPlayingDisplay, titleFont: Font) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("STATION")
                    .font(.caption2.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(WidgetPalette.stationLabel)
                if let caption = display.state.caption {
                    Text("· \(caption)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(WidgetPalette.secondaryText)
                }
            }
            Group {
                Text(display.station ?? "")
                    .font(titleFont.weight(.bold))
                    .foregroundStyle(.white)
                Text(display.track ?? "")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(display.artist ?? "")
                    .font(.caption)
                    .foregroundStyle(WidgetPalette.secondaryText)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .privateField()
        }
    }
}
