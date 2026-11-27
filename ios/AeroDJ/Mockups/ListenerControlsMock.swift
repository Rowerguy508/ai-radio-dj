#if DEBUG
import AeroDJCore
import SwiftUI

// #198 MOCK, owner review only (-Nova). Listener controls: DJ personality, language and
// Spanglish, what the DJ talks about (one switch and one source label per data source) and
// Sources. Nothing here is wired: every value is local `@State` that is thrown away, nothing is
// read from or written to `StationConfiguration`, UserDefaults, Connections, consent stores or
// playback. Debug only (this whole file is `#if DEBUG`), drawn only in the test station behind
// `-AeroDJStudioCapture YES` with a `listenerMock*` scenario. No production code until the owner
// OKs the design; then it is rebuilt on the real models (#196 language, #199/#200 facts).
//
// Layout: size classes and the window's safe area only. Compact width is one column, regular
// width is two columns with a side inset. No device names, no hard-coded screen sizes (the
// capture containers below set the frame, as the other Studio captures do).
// Copy marked "MOCK COPY" in docs/design/198-listener-controls-mock.md is new and unapproved.

/// The Studio shots of the #198 mock. Raw values are the `-AeroDJStudioCaptureScenario` names.
enum ListenerControlsMockScenario: String, CaseIterable {
    /// The iPhone window, compact: the controls list.
    case listenerMockPhone
    /// The iPhone window, compact: the Sources screen pushed from the list.
    case listenerMockPhoneSources
    /// The open Duo upright (640 x 820 pt container, compact width).
    case listenerMockDuoPortrait
    /// The open Duo on its side (820 x 640 pt container, regular width, two columns).
    case listenerMockDuoLandscape
    /// The iPad window, regular: two columns.
    case listenerMockPad

    static func requested(defaults: UserDefaults = .standard) -> ListenerControlsMockScenario? {
        defaults.string(forKey: StudioCapture.scenarioKey).flatMap(Self.init(rawValue:))
    }

    /// A fixed container for the Duo frames; nil draws the mock in the whole window.
    var container: (size: CGSize, sizeClass: UserInterfaceSizeClass)? {
        switch self {
        case .listenerMockDuoPortrait:
            return (size: StudioCapture.duoWideContainerSize, sizeClass: UserInterfaceSizeClass.compact)
        case .listenerMockDuoLandscape:
            return (size: StudioCapture.duoTentContainerSize, sizeClass: UserInterfaceSizeClass.regular)
        case .listenerMockPhone, .listenerMockPhoneSources, .listenerMockPad:
            return nil
        }
    }
}

/// The capture: the mock in the window, or in a fixed Duo container on the same neutral
/// backdrop and outline as `AppWideCaptureView`.
struct ListenerControlsMockCapture: View {
    let scenario: ListenerControlsMockScenario

    var body: some View {
        Group {
            if let container = scenario.container {
                let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
                ZStack {
                    Color(white: 0.14).ignoresSafeArea().accessibilityHidden(true)
                    ListenerControlsMockRoot(startsOnSources: false)
                        .environment(\.horizontalSizeClass, container.sizeClass)
                        .frame(width: container.size.width, height: container.size.height)
                        .clipShape(shape)
                        .overlay { shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 1).allowsHitTesting(false) }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("capture.listenerMockContainer")
                }
            } else {
                ListenerControlsMockRoot(startsOnSources: scenario == .listenerMockPhoneSources)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("capture.listenerMockContainer")
            }
        }
        .preferredColorScheme(UserDefaults.standard.bool(forKey: StudioCapture.darkKey) ? .dark : nil)
    }
}

// MARK: Mock-only values (not in AeroDJCore)

/// #196 is not built: there is no language setting in integration. Spec §2: English, Español,
/// Spanglish with an intensity of Off / Light / Conversational. Shown as Language plus a Spanglish
/// level (owner question 2).
enum ListenerMockLanguage: String, CaseIterable, Identifiable {
    case english, spanish
    var id: String { rawValue }
    var title: String { self == .english ? "English" : "Español" }
}

enum ListenerMockSpanglish: String, CaseIterable, Identifiable {
    case off, light, conversational
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: "Off"
        case .light: "Light"
        case .conversational: "Conversational"
        }
    }
    var detail: String {
        switch self {
        case .off: "One language only."
        case .light: "A short phrase now and then, like \u{201C}mi gente\u{201D} or \u{201C}up next\u{201D}."
        case .conversational: "Switches naturally between English and Spanish."
        }
    }
}

/// One thing the DJ may talk about: its own switch and its own source label (#198 acceptance).
struct ListenerMockTopic: Identifiable, Equatable {
    let id: String
    let title: String
    let symbol: String
    /// Where it comes from, always shown under the switch.
    let source: String
    let detail: String
    var isOn: Bool
    /// False: shown off and disabled, with the reason as its detail.
    let isAvailable: Bool

    static let fixtures: [ListenerMockTopic] = [
        // Real today: Apple Music catalog facts (#199, catalog only). No switch exists yet.
        ListenerMockTopic(id: "songFacts", title: "Song facts", symbol: "music.note",
                          source: "Apple Music", detail: "Album, year and credits Apple Music has. If there's no fact, the DJ says less.",
                          isOn: true, isAvailable: true),
        // Real today: the Weather switch in Tune > Local weather & news (#410), off by default.
        ListenerMockTopic(id: "weather", title: "Weather", symbol: "cloud.sun",
                          source: "Apple Weather \u{00B7} approximate location", detail: "Only rain, heat, cold or alerts worth hearing.",
                          isOn: true, isAvailable: true),
        // Real today in tester builds only (GDELT, owner decision Nov 3). Off by default.
        ListenerMockTopic(id: "news", title: "News", symbol: "newspaper",
                          source: "The GDELT Project \u{00B7} outlet named on air", detail: "One or two local headlines, credited to the outlet.",
                          isOn: false, isAvailable: true),
        // Real today: Morning briefing + Connections (Calendar, Shared from Mail & Messages, Markdown notes).
        ListenerMockTopic(id: "personal", title: "Personal briefing", symbol: "calendar",
                          source: "Calendar, shared items, notes \u{00B7} from Connections", detail: "Only sources you approved in Connections.",
                          isOn: false, isAvailable: true),
        // Not built: #199 was narrowed to Apple Music catalog facts only.
        ListenerMockTopic(id: "web", title: "Web lookups", symbol: "globe",
                          source: "Not available", detail: "Not built yet. Song facts come from Apple Music only.",
                          isOn: false, isAvailable: false),
    ]
}

/// One line the DJ said, with where its fact came from. Fixture text, test-station songs.
struct ListenerMockSourceEntry: Identifiable {
    let id: String
    let symbol: String
    let kind: String
    let time: String
    let line: String
    let source: String
    /// The provider's page, shown as a link label (Apple Weather's legal page, the news outlet).
    let linkTitle: String?

    static let fixtures: [ListenerMockSourceEntry] = [
        ListenerMockSourceEntry(id: "fact", symbol: "music.note", kind: "Song facts", time: "8:14",
                                line: "Up next, Slow Burn from Neon Harbor.",
                                source: "Apple Music \u{00B7} song and artist", linkTitle: nil),
        ListenerMockSourceEntry(id: "weather", symbol: "cloud.sun", kind: "Weather", time: "8:09",
                                line: "Light rain this morning, 54 now, high of 61.",
                                source: "Apple Weather", linkTitle: "Weather legal"),
        ListenerMockSourceEntry(id: "news", symbol: "newspaper", kind: "News", time: "8:02",
                                line: "From Example Outlet: the riverside path reopens Saturday.",
                                source: "Example Outlet via The GDELT Project", linkTitle: "Open article"),
        ListenerMockSourceEntry(id: "personal", symbol: "calendar", kind: "Personal briefing", time: "7:58",
                                line: "Two things on your calendar this morning.",
                                source: "Calendar \u{00B7} Connections", linkTitle: nil),
    ]
}

// MARK: Monochrome style

enum ListenerMockStyle {
    /// Selected fills and switch tint: ink in light, a mid grey in dark so a white thumb still reads.
    static var ink: Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .systemGray2 : .label })
    }
    /// Type on `ink`.
    static var onInk: Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .white : .systemBackground })
    }
    static var card: Color { Color(.secondarySystemGroupedBackground) }
    static var hairline: Color { Color(.separator) }
    static let minTarget: CGFloat = 44
}

// MARK: Views

/// Compact: one column, Sources pushed. Regular: two columns, Sources in the second.
struct ListenerControlsMockRoot: View {
    let startsOnSources: Bool
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            ListenerControlsMockView(onOpenSources: { path.append("sources") })
                .navigationDestination(for: String.self) { _ in ListenerMockSourcesScreen() }
        }
        .tint(Color.primary)
        .onAppear { if startsOnSources, path.isEmpty { path = ["sources"] } }
    }
}

struct ListenerControlsMockView: View {
    var onOpenSources: () -> Void = {}

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var personality: DJPersonality = .warm
    @State private var language: ListenerMockLanguage = .english
    @State private var spanglish: ListenerMockSpanglish = .light
    @State private var topics = ListenerMockTopic.fixtures

    private var isRegular: Bool { sizeClass == .regular }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if isRegular {
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 20) { personalitySection; languageSection }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        VStack(alignment: .leading, spacing: 20) { topicsSection; sourcesSection(showAll: true) }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                } else {
                    personalitySection
                    languageSection
                    topicsSection
                    sourcesSection(showAll: false)
                }
            }
            // Side inset on top of the window's safe area (ScrollView already honours it).
            .padding(.horizontal, isRegular ? 28 : 16)
            .padding(.vertical, 16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("DJ")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("mock198.controls")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Listener controls")
                .font(.largeTitle.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Text("Changes apply from the next DJ break. The music keeps playing.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label("Mock for #198, not in the app", systemImage: "square.dashed")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("mock198.badge")
        }
    }

    // MARK: Personality (real options: `DJPersonality`)

    private var personalitySection: some View {
        ListenerMockSection(title: "Personality", symbol: "person.wave.2",
                            footer: "Changes the words, not the voice or the facts.") {
            ForEach(Array(DJPersonality.allCases.enumerated()), id: \.element) { index, option in
                if index > 0 { ListenerMockDivider() }
                Button { personality = option } label: {
                    HStack(spacing: 12) {
                        Image(systemName: Self.symbol(for: option))
                            .font(.body.weight(.medium))
                            .frame(width: 28)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.title).font(.body.weight(.semibold))
                            Text(Self.mockDescription(for: option))
                                .font(.footnote).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: personality == option ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(personality == option ? Color.primary : Color.secondary)
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, minHeight: ListenerMockStyle.minTarget, alignment: .leading)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(personality == option ? .isSelected : [])
                .accessibilityIdentifier("mock198.personality.\(option.rawValue)")
            }
        }
    }

    static func symbol(for p: DJPersonality) -> String {
        switch p {
        case .warm: "sun.max"
        case .upbeat: "arrow.up.right"
        case .laidBack: "moon"
        case .minimal: "minus"
        }
    }

    /// MOCK COPY, from docs/dj-persona.md's table (today's `honestDescription` says less).
    static func mockDescription(for p: DJPersonality) -> String {
        switch p {
        case .warm: "The house style. Relaxed and friendly."
        case .upbeat: "Brighter and more forward, never hype."
        case .laidBack: "Softer, slower words."
        case .minimal: "Names only. The shortest breaks."
        }
    }

    // MARK: Language (mock only: #196)

    private var languageSection: some View {
        ListenerMockSection(title: "Language", symbol: "character.bubble",
                            footer: "Spanish uses a Spanish voice installed on this device. The accent depends on the voices you have.") {
            VStack(alignment: .leading, spacing: 10) {
                ListenerMockSegmented(label: "DJ language", options: ListenerMockLanguage.allCases, title: \.title,
                                      selection: $language, idPrefix: "mock198.language")
                ListenerMockDivider()
                Text("Spanglish").font(.subheadline.weight(.semibold))
                ListenerMockSegmented(label: "Spanglish", options: ListenerMockSpanglish.allCases, title: \.title,
                                      selection: $spanglish, idPrefix: "mock198.spanglish")
                Text(spanglish.detail)
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: What the DJ talks about

    private var topicsSection: some View {
        ListenerMockSection(title: "What the DJ talks about", symbol: "text.bubble",
                            footer: "Each source has its own switch. Off means the DJ never mentions it.") {
            ForEach(topics.indices, id: \.self) { index in
                let topic = topics[index]
                if index > 0 { ListenerMockDivider() }
                Toggle(isOn: $topics[index].isOn) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: topic.symbol)
                            .font(.body.weight(.medium))
                            .frame(width: 28)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(topic.title).font(.body.weight(.semibold))
                            Label(topic.source, systemImage: topic.isAvailable ? "link" : "nosign")
                                .labelStyle(ListenerMockInlineLabel())
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.secondary)
                            Text(topic.detail)
                                .font(.footnote).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .tint(ListenerMockStyle.ink)
                .disabled(!topic.isAvailable)
                .frame(minHeight: ListenerMockStyle.minTarget)
                .padding(.vertical, 8)
                .accessibilityIdentifier("mock198.topic.\(topic.id)")
            }
        }
    }

    // MARK: Sources

    @ViewBuilder
    private func sourcesSection(showAll: Bool) -> some View {
        let entries = showAll ? ListenerMockSourceEntry.fixtures : Array(ListenerMockSourceEntry.fixtures.prefix(2))
        ListenerMockSection(title: "Sources", symbol: "list.bullet.rectangle",
                            footer: "What the DJ said this session and where each fact came from.") {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { ListenerMockDivider() }
                ListenerMockSourceRow(entry: entry)
            }
            if !showAll {
                ListenerMockDivider()
                Button(action: onOpenSources) {
                    HStack {
                        Text("All sources").font(.body.weight(.semibold))
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, minHeight: ListenerMockStyle.minTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("mock198.allSources")
            }
        }
    }
}

/// Sources, pushed from the compact list.
struct ListenerMockSourcesScreen: View {
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("What the DJ said this session and where each fact came from. Lines without a source are just the DJ talking.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ListenerMockSection(title: "This session", symbol: "clock", footer: nil) {
                    ForEach(Array(ListenerMockSourceEntry.fixtures.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { ListenerMockDivider() }
                        ListenerMockSourceRow(entry: entry)
                    }
                }
                Label("Mock for #198, not in the app", systemImage: "square.dashed")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, sizeClass == .regular ? 28 : 16)
            .padding(.vertical, 16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Sources")
        .navigationBarTitleDisplayMode(.large)
        .accessibilityIdentifier("mock198.sources")
    }
}

struct ListenerMockSourceRow: View {
    let entry: ListenerMockSourceEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: entry.symbol)
                .font(.body.weight(.medium))
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.kind).font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Text(entry.time).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text("\u{201C}\(entry.line)\u{201D}")
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                Label(entry.source, systemImage: "link")
                    .labelStyle(ListenerMockInlineLabel())
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                if let link = entry.linkTitle {
                    // Mock: no URL is opened. The real row opens the provider's page.
                    Button {} label: {
                        HStack(spacing: 4) {
                            Text(link).underline()
                            Image(systemName: "arrow.up.right").accessibilityHidden(true)
                        }
                        .font(.footnote.weight(.semibold))
                        .frame(minHeight: ListenerMockStyle.minTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("mock198.source.\(entry.id).link")
                }
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mock198.source.\(entry.id)")
    }
}

/// A titled card: header with an SF Symbol, grouped rows, optional footer.
struct ListenerMockSection<Content: View>: View {
    let title: String
    let symbol: String
    let footer: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 14)
                .background(ListenerMockStyle.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(ListenerMockStyle.hairline.opacity(0.6), lineWidth: 0.5)
                }
            if let footer {
                Text(footer)
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

struct ListenerMockDivider: View {
    var body: some View { Rectangle().fill(ListenerMockStyle.hairline).frame(height: 0.5) }
}

/// Icon and title on one baseline, the icon small.
struct ListenerMockInlineLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            configuration.icon.imageScale(.small).accessibilityHidden(true)
            configuration.title
        }
    }
}

/// A monochrome segmented choice with 44 pt targets (the system segmented control is 32 pt).
/// Side by side when it fits, stacked at large text sizes.
struct ListenerMockSegmented<Option: Identifiable & Hashable>: View {
    let label: String
    let options: [Option]
    let title: KeyPath<Option, String>
    @Binding var selection: Option
    let idPrefix: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) { buttons }
                .padding(3)
                .background(Color(.tertiarySystemFill), in: Capsule())
            VStack(spacing: 4) { buttons }
                .padding(3)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private var buttons: some View {
        ForEach(options) { option in
            let selected = option == selection
            Button { selection = option } label: {
                Text(option[keyPath: title])
                    .font(.subheadline.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: ListenerMockStyle.minTarget)
                    .foregroundStyle(selected ? ListenerMockStyle.onInk : Color.primary)
                    .background { if selected { Capsule().fill(ListenerMockStyle.ink) } }
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("\(idPrefix).\(option.id)")
        }
    }
}
#endif
