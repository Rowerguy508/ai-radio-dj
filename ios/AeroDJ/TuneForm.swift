import AeroDJCore
import MusicKit
import SwiftUI

/// The Station Tuner (studio-presentation-contract.md, Station Tuner). Every control binds
/// to `station.displayed` and shows its row from `station.tunerRows`: pending vs active,
/// "Applies after this song" and status. Edits go into an unsaved draft until Save; Save
/// never stops the current song. When playback is idle, Save applies immediately.
///
/// Originally written by Claudio (#60); taken over and revised by Fry.
struct TuneForm: View {
    let studio: StudioPresentationModel
    private var model: StationConfigurationModel { studio.station }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                if let blocked = blockedMessage {
                    Label(blocked, systemImage: "lock")
                        .font(.subheadline)
                        .foregroundStyle(AeroDJPalette.secondaryText)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .workspaceCardBackground(Color(.tertiarySystemFill), compactRadius: 12)
                }
                if model.hasUnsavedChanges { UnsavedChangesCard(model: model) }
                if model.hasPendingChanges { PendingChangesCard(model: model) }
                Group {
                    TuneSectionHeader(title: "Sound", detail: StationTunerCopy.musicSelectionNotice)
                    // Suggestions are the storefront's Apple Music genres (`GenreProviding`), not a fixed list.
                    TagControl(row: row(.genres), selected: model.displayed.genres,
                               suggestions: studio.tuneGenres.suggestions,
                               genreStatus: studio.tuneGenres) { tags in Task { await model.setGenres(tags) } }
                    TagControl(row: row(.moods), selected: model.displayed.moods,
                               suggestions: TuneVocabulary.moods) { tags in Task { await model.setMoods(tags) } }
                    LevelControl(row: row(.energy), value: model.displayed.energy, low: "Calm", high: "High energy") { v in
                        Task { await model.setEnergy(v) }
                    }
                    LevelControl(row: row(.discovery), value: model.displayed.discovery, low: "Favourites", high: "New music") { v in
                        Task { await model.setDiscovery(v) }
                    }
                    TuneSectionHeader(title: "DJ", detail: "Applies to future DJ breaks, never the song that's playing.")
                    commentaryControl
                    personalityControl
                    briefingControl
                    CloudVoiceToggleCard()
                    SubscriptionStatusCard()
                }
                .disabled(blockedMessage != nil)
                RecipesSection(studio: studio, editable: blockedMessage == nil)
            }
            .padding(.vertical, 4)
            .padding(.bottom, 16)
        }
        .accessibilityIdentifier("tune.form")
        // Tune can be restored at launch: this reads the Apple Music status (never prompts) and
        // fetches genres only when it is already .authorized (Fry, #214). See TuneGenreSuggestions.
        .task { await studio.tuneGenres.appear(isAuthorized: GenreAccess.isAuthorized) }
    }

    private func row(_ setting: StationSetting) -> StationTunerRow { model.tunerRow(for: setting) }

    /// ui-contract.md §9: not loaded → disabled; newer file → read-only.
    private var blockedMessage: String? {
        switch model.loadState {
        case .notLoaded, .loading: "Loading your station settings"
        case .failed(.newerVersion(_)): "Update AeroDJ to change these settings"
        case .ready, .failed: nil
        }
    }

    private var commentaryControl: some View {
        ControlCard(row: row(.commentary)) {
            Picker("DJ talk", selection: Binding(get: { model.displayed.commentary },
                                                 set: { c in Task { await model.setCommentary(c) } })) {
                ForEach(CommentaryFrequency.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(model.displayed.commentary.honestDescription)
                .font(.caption).foregroundStyle(AeroDJPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var personalityControl: some View {
        ControlCard(row: row(.personality)) {
            Picker("DJ personality", selection: Binding(get: { model.displayed.personality },
                                                        set: { p in Task { await model.setPersonality(p) } })) {
                ForEach(DJPersonality.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(model.displayed.personality.honestDescription)
                .font(.caption).foregroundStyle(AeroDJPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var briefingControl: some View {
        ControlCard(row: row(.briefing)) {
            Toggle("Morning briefing", isOn: Binding(get: { model.displayed.briefing.enabled },
                                                     set: { on in Task { await model.setBriefing { $0.enabled = on } } }))
            Text("Uses only sources you approved in Connections. Music comes first; the briefing may run shorter.")
                .font(.caption).foregroundStyle(AeroDJPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("Briefing sources").font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
            // Requesting a source never grants access; Connections shows whether it is
            // actually readable. Turning one off applies now and purges its narration.
            ForEach(StationIntegration.allCases, id: \.self) { integration in
                let r = row(.integration(integration))
                Toggle(isOn: Binding(get: { model.displayed.requestedIntegrations.contains(integration) },
                                     set: { on in Task { await model.setIntegration(integration, requested: on) } })) {
                    HStack(spacing: 8) {
                        Text(r.title)
                        if model.displayed.requestedIntegrations.contains(integration) {
                            StatusBadge(indicator: TunerIndicator(status: r.status, setting: r.setting))
                        }
                    }
                }
                .font(.subheadline)
            }
        }
    }
}

/// Suggestions only. Tags are free-form and normalized by `StationConfiguration`.
/// Mood suggestions. Genre suggestions come from Apple Music (`StudioPresentationModel.tuneGenres`).
enum TuneVocabulary {
    static let moods = ["calm", "bright", "focused", "dreamy", "energetic", "warm", "melancholy", "late night"]
}

/// Card with the control's title, its displayed value, status and pending copy.
struct ControlCard<Content: View>: View {
    let row: StationTunerRow
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.title).font(.headline)
                Spacer(minLength: 8)
                StatusBadge(indicator: TunerIndicator(status: row.status, setting: row.setting))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(row.accessibilitySummary)
            content
            if let applies = row.appliesCopy {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath").accessibilityHidden(true)
                    Text("\(applies) · \(StationTunerCopy.nowUsing(row.activeSummary))")
                        .lineLimit(2)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(AeroDJPalette.secondaryText)
            }
        }
        .padding(14)
        .workspaceCardBackground(Color(.tertiarySystemFill).opacity(0.6))
    }
}

/// Saved / Pending / Active (or saving, consent, error) as a small labelled chip. Never
/// colour alone: every state has text and an icon.
struct StatusBadge: View {
    let indicator: TunerIndicator

    var body: some View {
        Label(indicator.label, systemImage: icon)
            .font(.caption.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
            .lineLimit(1)
            .accessibilityLabel(indicator.accessibilityLabel)
            .accessibilityIdentifier("tune.indicator")
    }

    private var icon: String {
        switch indicator {
        case .saved: "tray.and.arrow.down"
        case .pending: "clock"
        case .active: "checkmark.circle.fill"
        case .saving: "arrow.triangle.2.circlepath"
        case .needsConsent: "lock"
        case .problem: "exclamationmark.triangle"
        }
    }

    private var color: Color {
        switch indicator {
        case .saved, .saving: AeroDJPalette.secondaryText
        case .pending: AeroDJPalette.statusPending
        case .active: AeroDJPalette.statusPositive
        case .needsConsent: AeroDJPalette.secondaryText
        case .problem: AeroDJPalette.statusProblem
        }
    }
}

/// A group title with one honest line about what the group changes today.
struct TuneSectionHeader: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AeroDJPalette.secondaryText)
                .accessibilityAddTraits(.isHeader)
            Text(detail)
                .font(.caption)
                .foregroundStyle(AeroDJPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }
}

/// Toggleable tag chips (suggestions plus anything already chosen) and a custom tag field.
struct TagControl: View {
    let row: StationTunerRow
    let selected: [String]
    let suggestions: [String]
    /// Genres only: loading / empty / error line for the Apple Music suggestions.
    var genreStatus: TuneGenreSuggestions? = nil
    let onChange: ([String]) -> Void
    @State private var custom = ""

    var body: some View {
        ControlCard(row: row) {
            FlowLayout(spacing: 8) {
                ForEach(allTags, id: \.self) { tag in
                    let isOn = selected.contains(tag)
                    Button {
                        onChange(isOn ? selected.filter { $0 != tag } : selected + [tag])
                    } label: {
                        // Neutral, not accent blue (wireframe 08): selected = 18% fill + hairline
                        // and a heavier weight, so selection reads without colour.
                        Text(tag)
                            .font(.subheadline.weight(isOn ? .semibold : .regular))
                            .padding(.horizontal, 12)
                            .frame(minHeight: 36)
                            .background(Capsule().fill(Color.primary.opacity(isOn ? 0.18 : 0)))
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(isOn ? 0.22 : 0.14), lineWidth: 1))
                            .foregroundStyle(isOn ? Color.primary : Color.primary.opacity(0.7))
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                    .accessibilityHint(isOn ? "Removes \(tag)" : "Adds \(tag)")
                }
            }
            if let genreStatus { GenreSuggestionStatus(model: genreStatus) }
            HStack {
                TextField("", text: $custom,
                          prompt: Text("Add your own").foregroundStyle(.secondary))
                    .textInputAutocapitalization(.never)
                    .onSubmit(addCustom)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .workspaceFieldBackground(Color(.tertiarySystemFill), compactRadius: 8)
                    .accessibilityLabel("Add your own")
                Button("Add", action: addCustom)
                    .disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .font(.subheadline)
        }
    }

    private var allTags: [String] { selected + suggestions.filter { !selected.contains($0) } }

    private func addCustom() {
        let tag = custom.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !tag.isEmpty, !selected.contains(tag) else { custom = ""; return }
        onChange(selected + [tag])
        custom = ""
    }
}

/// Apple Music status for the genre pickers. Reads `currentStatus` only; never calls
/// `MusicAuthorization.request()` or `authorize()`.
enum GenreAccess {
    @MainActor static var isAuthorized: Bool { MusicAuthorization.currentStatus == .authorized }
}

/// Loading, empty, not-connected and error states for the Apple Music genre chips. Custom tags keep working.
struct GenreSuggestionStatus: View {
    let model: TuneGenreSuggestions

    var body: some View {
        switch model.phase {
        case .loaded, .idle, .unavailable:
            EmptyView()
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                Text("Loading Apple Music genres")
            }
            .font(.footnote).foregroundStyle(AeroDJPalette.secondaryText)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("tune.genres.loading")
        case .empty:
            Text("No Apple Music genres to suggest. Add your own below.")
                .font(.footnote).foregroundStyle(AeroDJPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("tune.genres.empty")
        case .notAuthorized:
            // No button and no prompt: access is granted from a station (Allow) or Settings.
            Text(GenrePickerCopy.connectAppleMusic)
                .font(.footnote).foregroundStyle(AeroDJPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("tune.genres.connect")
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(AeroDJPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") { Task { await model.retry(isAuthorized: GenreAccess.isAuthorized) } }
                    .font(.footnote.weight(.semibold))
                    .accessibilityHint("Loads genre suggestions from Apple Music again")
                    .accessibilityIdentifier("tune.genres.retry")
            }
            .accessibilityIdentifier("tune.genres.error")
        }
    }
}

/// A 0–1 slider. It saves once when the drag ends, not on every tick.
struct LevelControl: View {
    let row: StationTunerRow
    let value: Double
    let low: String
    let high: String
    let onCommit: (Double) -> Void
    @State private var draft: Double?

    var body: some View {
        ControlCard(row: row) {
            Slider(value: Binding(get: { draft ?? value }, set: { draft = $0 }), in: 0...1) { editing in
                if !editing, let d = draft {
                    onCommit(d)
                    draft = nil
                }
            }
            .accessibilityLabel(row.title)
            .accessibilityValue("\(Int(((draft ?? value) * 100).rounded())) percent")
            HStack {
                Text(low)
                Spacer()
                Text(high)
            }
            .font(.caption)
            .foregroundStyle(AeroDJPalette.secondaryText)
            .accessibilityHidden(true)
        }
    }
}

/// Unsaved Tune edits. Save schedules them for the next safe boundary (or applies now when
/// idle). Discard reverts the controls. Connections / consent never appear here.
struct UnsavedChangesCard: View {
    let model: StationConfigurationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(StationTunerCopy.unsavedHeader, systemImage: "pencil.line")
                .font(.subheadline.weight(.semibold))
            Text(StationTunerCopy.unsavedDetail(idle: model.playbackActivity == .idle))
                .font(.caption)
                .foregroundStyle(AeroDJPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Save") { Task { await model.saveChanges() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier("tune.save")
                Button("Discard") { model.discardUnsavedChanges() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("tune.discard")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .workspaceCardBackground(Color.primary.opacity(0.07))
        .overlay(NeutralCardHairline())
        .accessibilityElement(children: .contain)
    }
}

/// Saved edits waiting for a safe boundary, with a way to keep what is playing now.
struct PendingChangesCard: View {
    let model: StationConfigurationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(StationTunerCopy.pendingHeader, systemImage: "clock.arrow.circlepath")
                .font(.subheadline.weight(.semibold))
            ForEach(model.tunerRows.filter(\.isPending)) { row in
                Text("\(row.title): \(row.displayedSummary) — \(row.appliesCopy ?? "")")
                    .font(.caption)
                    .foregroundStyle(AeroDJPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Keep current settings") { Task { await model.discardPendingChanges() } }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .workspaceCardBackground(Color.primary.opacity(0.07))
        .overlay(NeutralCardHairline())
        .accessibilityElement(children: .contain)
    }
}

/// Saved station recipes: tuning only, never connections.
struct RecipesSection: View {
    let studio: StudioPresentationModel
    let editable: Bool
    @State private var name = ""
    @State private var message: String?
    @State private var renaming: StationRecipe?
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Station recipes").font(.headline).accessibilityAddTraits(.isHeader)
            Text("A recipe saves the tuning above. It never turns a connection on or off.")
                .font(.caption).foregroundStyle(AeroDJPalette.secondaryText)
            if studio.recipes.recipes.isEmpty {
                Text("No recipes yet.").font(.subheadline).foregroundStyle(AeroDJPalette.secondaryText)
            }
            ForEach(studio.recipes.recipes) { recipe in
                HStack {
                    Text(recipe.name).font(.subheadline).lineLimit(1)
                    Spacer(minLength: 8)
                    Button("Apply") { Task { await apply(recipe) } }
                        .buttonStyle(.bordered).controlSize(.small)
                        .accessibilityLabel("Apply \(recipe.name)")
                    Button {
                        newName = recipe.name
                        renaming = recipe
                    } label: {
                        Label("Rename \(recipe.name)", systemImage: "pencil").labelStyle(.iconOnly).frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderless)
                    Button(role: .destructive) {
                        Task { if case .failure(let e) = await studio.recipes.delete(recipe.id) { message = e.userMessage } }
                    } label: {
                        Label("Delete \(recipe.name)", systemImage: "trash").labelStyle(.iconOnly).frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderless)
                }
                .disabled(!editable)
            }
            HStack {
                TextField("Name this tuning", text: $name)
                Button("Save") {
                    Task {
                        switch await studio.saveRecipe(named: name) {
                        case .success(let r): message = "Saved \"\(r.name)\"."; name = ""
                        case .failure(let e): message = e.userMessage
                        }
                    }
                }
                .disabled(!editable || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .font(.subheadline)
            if let message {
                Text(message).font(.caption).foregroundStyle(AeroDJPalette.secondaryText)
            }
        }
        .padding(14)
        .workspaceCardBackground(Color(.tertiarySystemFill).opacity(0.6))
        .alert("Rename recipe", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") {
                guard let recipe = renaming else { return }
                Task {
                    switch await studio.recipes.rename(recipe.id, to: newName) {
                    case .success(let r): message = "Renamed to \"\(r.name)\"."
                    case .failure(let e): message = e.userMessage
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func apply(_ recipe: StationRecipe) async {
        switch await studio.applyRecipe(recipe.id) {
        case .success(let timings):
            let waits = Set(timings.values).subtracting([.immediate])
            message = waits.isEmpty ? "Applied \"\(recipe.name)\"."
                : "\"\(recipe.name)\" is set. " + waits.map(\.appliesCopy).sorted().joined(separator: "; ") + "."
        case .failure(let e):
            message = e.userMessage
        }
    }
}

/// Wraps chips onto as many lines as needed (iOS 16+ `Layout`).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += lineHeight + spacing; lineHeight = 0 }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += lineHeight + spacing; lineHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

#Preview("Tune") {
    TunePreviewLoader()
}

struct TunePreviewLoader: View {
    @State private var studio: StudioPresentationModel?
    var body: some View {
        Group {
            if let studio { TuneForm(studio: studio).padding() } else { ProgressView() }
        }
        .task { studio = await StudioPresentationModel.preview() }
    }
}

/// 1 pt hairline for the neutral Pending / Unsaved cards (they used to carry a blue tint).
/// Same radius rule as `workspaceCardBackground`: 22 pt in the unfolded Studio, 16 pt elsewhere.
private struct NeutralCardHairline: View {
    @Environment(\.studioPanes) private var studioPanes

    var body: some View {
        RoundedRectangle(cornerRadius: studioPanes ? CGFloat(StudioCornerRadius.card) : 16, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            .allowsHitTesting(false)
    }
}
