import AeroDJCore
import SwiftUI

// Add-station walkthrough (-Nova): a guided sheet from the Stations screen's + button.
// Seven steps: start from (artists, genre or playlist), pick, discovery level, DJ personality
// and talk level (both optional; "Keep current tuning" leaves them nil), name, review.
//
// Owns no data. Search, picks, validation and Save are Atlas's `StationCreationModel`, and Save
// goes through `studio.saveRecipe(named:from:applying:)` with `applying: false`, so the live
// station and the song that's playing never change. Step rules are `AddStationWalkthrough`
// (AeroDJCore, Linux-tested). Picks and library playlists stay in memory and are never logged.

/// Near-black canvas and neutral greys for the walkthrough. No amber: nothing here is on air.
enum AddStationStyle {
    static let canvas = Color(red: 6 / 255, green: 6 / 255, blue: 7 / 255) // #060607
    static let cardRadius: CGFloat = 22
    static let controlRadius: CGFloat = 16
    static let hairline = Color.white.opacity(0.10)
    static let selectedStroke = Color.white.opacity(0.85)
    static let secondary = Color.white.opacity(0.68)
}

/// Dark glass card: the system material in a continuous (squircle) shape plus a 1 pt hairline.
/// `aeroGlass` isn't on this base yet; once it lands this can route through it.
private struct AddStationCard: ViewModifier {
    var selected = false
    var radius = AddStationStyle.cardRadius
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                if reduceTransparency {
                    shape.fill(Color(white: 0.11))
                } else {
                    shape.fill(.ultraThinMaterial)
                }
            }
            .overlay {
                shape.strokeBorder(selected ? AddStationStyle.selectedStroke : AddStationStyle.hairline,
                                   lineWidth: selected ? 1.5 : 1)
            }
            .contentShape(shape)
    }
}

private extension View {
    func addStationCard(selected: Bool = false, radius: CGFloat = AddStationStyle.cardRadius) -> some View {
        modifier(AddStationCard(selected: selected, radius: radius))
    }

    /// Staggered pop-in: a spring scale-and-fade, `index` × 50 ms late. Reduce Motion: fade only.
    func popIn(_ index: Int) -> some View { modifier(PopIn(index: index)) }
}

private struct PopIn: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown || reduceMotion ? 1 : 0.94)
            .offset(y: shown || reduceMotion ? 0 : 8)
            .onAppear {
                let delay = Double(min(index, 8)) * 0.05
                let animation: Animation = reduceMotion
                    ? .easeInOut(duration: 0.2).delay(delay)
                    : .spring(response: 0.42, dampingFraction: 0.78).delay(delay)
                withAnimation(animation) { shown = true }
            }
    }
}

/// The + on the Stations screen. Shown only when the app has seed search (never in the Test Station).
struct AddStationToolbarButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Add station", systemImage: "plus")
        }
        .accessibilityLabel("Add station")
        .accessibilityHint("Build a new station from artists, a genre or a playlist")
        .accessibilityIdentifier("addStation.plus")
    }
}

struct AddStationWalkthroughView: View {
    let studio: StudioPresentationModel
    let creation: StationCreationModel
    let onClose: () -> Void

    @State private var step: AddStationStep
    @State private var chosenKind: StationCreationKind?
    @State private var typedName = ""
    @State private var query = ""
    @State private var browsingLibrary = false
    @State private var searchAttempt = 0
    @State private var forward = true
    @State private var savedName: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var headingFocused: Bool

    init(studio: StudioPresentationModel, creation: StationCreationModel,
         initialStep: AddStationStep = .kind, initialKind: StationCreationKind? = nil,
         onClose: @escaping () -> Void) {
        self.studio = studio
        self.creation = creation
        self.onClose = onClose
        _step = State(initialValue: initialStep)
        _chosenKind = State(initialValue: initialKind ?? (initialStep > .kind ? creation.kind : nil))
    }

    private var progress: AddStationProgress {
        AddStationProgress(kind: chosenKind, pickError: creation.validationError, level: creation.level,
                           typedName: typedName, suggestedName: creation.suggestedName,
                           existingNames: studio.recipes.recipes.map(\.name), isSaving: creation.isSaving)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                StepIndicator(current: step, complete: { AddStationWalkthrough.isComplete($0, progress) })
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(heading)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityFocused($headingFocused)
                        stepContent
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // New identity per step, so the transition and pop-ins rerun.
                    .id(step)
                    .transition(stepTransition)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("addStation.step.\(step.number)")
                }
                footer
            }
            .background(AddStationStyle.canvas.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(savedName == nil ? "Cancel" : "Done") { onClose() }
                        .disabled(creation.isSaving)
                        .accessibilityIdentifier("addStation.cancel")
                }
            }
            .toolbarBackground(AddStationStyle.canvas, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle("New station")
        }
        .preferredColorScheme(.dark)
        .tint(.white)
        .interactiveDismissDisabled(creation.isSaving)
    }

    private var heading: String {
        if savedName != nil { return "Station saved" }
        switch step {
        case .kind: return "What should it start from?"
        case .picks: return chosenKind.map { "Pick \($0 == .artists ? "artists" : "a \($0.title.lowercased())")" } ?? "Pick"
        case .level: return "How adventurous?"
        case .personality: return "Which DJ style?"
        case .talk: return "How much should the DJ talk?"
        case .name: return "Name your station"
        case .review: return "Check it over"
        }
    }

    private var stepTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                           removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .kind: kindStep
        case .picks: picksStep
        case .level: levelStep
        case .personality: personalityStep
        case .talk: talkStep
        case .name: nameStep
        case .review: reviewStep
        }
    }

    // MARK: Step 1: start from

    private var kindStep: some View {
        VStack(spacing: 10) {
            ForEach(Array(StationCreationKind.allCases.enumerated()), id: \.element) { index, kind in
                ChoiceCard(title: kind.title, detail: AddStationWalkthrough.kindSummary(kind),
                           systemImage: icon(for: kind), selected: chosenKind == kind) {
                    if chosenKind != kind {
                        creation.setKind(kind)
                        query = ""
                        browsingLibrary = false
                    }
                    chosenKind = kind
                }
                .accessibilityIdentifier("addStation.kind.\(kind.rawValue)")
                .popIn(index)
            }
        }
    }

    private func icon(for kind: StationCreationKind) -> String {
        switch kind {
        case .artists: "person.2"
        case .genre: "guitars"
        case .playlist: "music.note.list"
        }
    }

    // MARK: Step 2: pick

    private var picksStep: some View {
        let kind = chosenKind ?? creation.kind
        return VStack(alignment: .leading, spacing: 12) {
            Text(AddStationWalkthrough.pickHint(for: kind))
                .font(.subheadline)
                .foregroundStyle(AddStationStyle.secondary)
                .popIn(0)
            if kind == .playlist {
                Picker("Playlists from", selection: $browsingLibrary) {
                    Text("Apple Music").tag(false)
                    Text("Your library").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("addStation.playlistSource")
                .popIn(1)
            }
            if !(kind == .playlist && browsingLibrary) {
                searchField(kind).popIn(1)
            }
            if !creation.selected.isEmpty { selectedChips.popIn(2) }
            if let restriction = creation.reachRestriction {
                Label(restriction.message, systemImage: "lock.iphone")
                    .font(.caption)
                    .foregroundStyle(AddStationStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            resultsList
        }
        // Genres list on arrival (fetched once through `GenreProviding`, then filtered on the
        // device as you type); library playlists load when that tab is chosen. Catalog search
        // waits 300 ms after typing stops. All through `StationCreationModel`, never a new route.
        .task(id: SearchKey(kind: kind, query: query, library: browsingLibrary, attempt: searchAttempt)) {
            if kind == .playlist && browsingLibrary {
                await creation.loadLibraryPlaylists()
                return
            }
            if kind != .genre {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
            }
            await creation.search(query)
        }
    }

    private struct SearchKey: Hashable {
        let kind: StationCreationKind
        let query: String
        let library: Bool
        /// Bumped by "Try again" so a failed load reruns with the same query.
        let attempt: Int
    }

    private func searchField(_ kind: StationCreationKind) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(AddStationStyle.secondary).accessibilityHidden(true)
            TextField(kind == .genre ? "Filter genres" : (kind == .artists ? "Search artists" : "Search playlists"),
                      text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .foregroundStyle(.white)
                .accessibilityIdentifier("addStation.search")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(AddStationStyle.secondary)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
        .addStationCard(radius: AddStationStyle.controlRadius)
    }

    private var selectedChips: some View {
        FlowLayout(spacing: 8) {
            ForEach(creation.selected, id: \.key) { seed in
                Button { creation.toggle(seed) } label: {
                    HStack(spacing: 6) {
                        Text(seed.name).lineLimit(1)
                        Image(systemName: "xmark").font(.caption2.weight(.bold)).accessibilityHidden(true)
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AddStationStyle.canvas)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.white))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(seed.name)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Picked")
    }

    @ViewBuilder
    private var resultsList: some View {
        switch creation.phase {
        case .idle:
            EmptyView()
        case .searching where creation.results.isEmpty:
            Group {
                if creation.isLoadingGenres { ProgressView("Loading genres") } else { ProgressView() }
            }
                .tint(.white).foregroundStyle(AddStationStyle.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 20)
                .accessibilityLabel(creation.isLoadingGenres ? "Loading genres" : "Searching")
        case .empty:
            Text(creation.kind == .genre
                 ? (query.isEmpty ? "No genres are available right now." : "No genres match. Try another word.")
                 : "No matches. Try another name.")
                .font(.subheadline).foregroundStyle(AddStationStyle.secondary)
                .accessibilityIdentifier("addStation.empty")
        case .failed(let message):
            if let message {
                VStack(alignment: .leading, spacing: 10) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.subheadline).foregroundStyle(AddStationStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // Genres: one explicit refetch (typing never refetches after a failure).
                    Button("Try again") {
                        if creation.kind == .genre {
                            Task { await creation.retryGenres(matching: query) }
                        } else {
                            searchAttempt += 1
                        }
                    }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .accessibilityIdentifier("addStation.retry")
                }
            }
        case .notAuthorized:
            // Never prompts here: access is granted from a station (Allow) or Settings.
            Text(GenrePickerCopy.connectAppleMusic)
                .font(.subheadline).foregroundStyle(AddStationStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("addStation.genres.connect")
        case .searching, .results:
            VStack(spacing: 8) {
                if creation.resultsSource == .libraryPlaylists {
                    Text("Your playlists").font(.footnote.weight(.semibold))
                        .foregroundStyle(AddStationStyle.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)
                }
                ForEach(Array(creation.results.enumerated()), id: \.element.id) { index, row in
                    resultRow(row).popIn(min(index, 6) + 2)
                }
            }
        }
    }

    private func resultRow(_ row: StationSeedSearchResult) -> some View {
        let picked = creation.isSelected(row.seed)
        let blocked = !picked && !creation.canPickMore && creation.kind.maxSeeds > 1
        return Button { creation.toggle(row.seed) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.seed.name).font(.body.weight(.medium)).foregroundStyle(.white).lineLimit(1)
                    if let subtitle = row.subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(AddStationStyle.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: picked ? "checkmark.circle.fill" : "plus.circle")
                    .font(.title3)
                    .foregroundStyle(picked ? Color.white : AddStationStyle.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .addStationCard(selected: picked, radius: AddStationStyle.controlRadius)
        }
        .buttonStyle(.plain)
        .disabled(blocked)
        .opacity(blocked ? 0.45 : 1)
        .accessibilityLabel([row.seed.name, row.subtitle].compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue(picked ? "Picked" : "")
        .accessibilityHint(blocked ? "You've picked the most artists allowed" : (picked ? "Double-tap to remove" : "Double-tap to pick"))
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    // MARK: Step 3: discovery level

    private var levelStep: some View {
        VStack(spacing: 10) {
            ForEach(Array(StationDiscoveryLevel.allCases.enumerated()), id: \.element) { index, level in
                ChoiceCard(title: level.title, detail: level.summary, systemImage: levelIcon(level),
                           selected: creation.level == level) {
                    creation.level = level
                }
                .accessibilityIdentifier("addStation.level.\(level.rawValue)")
                .popIn(index)
            }
            if creation.reachRestriction != nil {
                Text("Your library pick plays only itself at any level.")
                    .font(.caption).foregroundStyle(AddStationStyle.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .popIn(3)
            }
        }
    }

    private func levelIcon(_ level: StationDiscoveryLevel) -> String {
        switch level {
        case .familiar: "heart"
        case .balanced: "circle.lefthalf.filled"
        case .adventurous: "safari"
        }
    }

    // MARK: Step 4: DJ personality (optional)

    private var personalityStep: some View {
        let current = studio.station.displayed.personality
        return VStack(spacing: 10) {
            ForEach(Array(AddStationTuning.personalityOptions.enumerated()), id: \.offset) { index, option in
                ChoiceCard(title: AddStationTuning.title(option),
                           detail: AddStationTuning.detail(option, current: current),
                           systemImage: option == nil ? "slider.horizontal.3" : "person.wave.2",
                           selected: creation.personality == option) {
                    creation.personality = option
                }
                .accessibilityIdentifier("addStation.personality.\(AddStationTuning.idSuffix(option))")
                .popIn(index)
            }
        }
    }

    // MARK: Step 5: talk level (optional)

    private var talkStep: some View {
        let current = studio.station.displayed.commentary
        return VStack(spacing: 10) {
            ForEach(Array(AddStationTuning.talkOptions.enumerated()), id: \.offset) { index, option in
                // Each detail is the Tune copy, i.e. the planner's delivered share (Chatty: every song, #165).
                ChoiceCard(title: AddStationTuning.title(option),
                           detail: AddStationTuning.detail(option, current: current),
                           systemImage: talkIcon(option),
                           selected: creation.commentary == option) {
                    creation.commentary = option
                }
                .accessibilityIdentifier("addStation.talk.\(AddStationTuning.idSuffix(option))")
                .popIn(index)
            }
        }
    }

    private func talkIcon(_ option: CommentaryFrequency?) -> String {
        switch option {
        case nil: "slider.horizontal.3"
        case .off: "speaker.slash"
        case .rare: "bubble.left"
        case .occasional, .frequent: "bubble.left.and.bubble.right"
        case .chatty: "quote.bubble"
        }
    }

    // MARK: Step 6: name

    private var nameStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(creation.suggestedName ?? "Station name", text: $typedName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .submitLabel(.next)
                .onSubmit { goNext() }
                .padding(.horizontal, 16)
                .frame(minHeight: 56)
                .addStationCard(radius: AddStationStyle.controlRadius)
                .accessibilityLabel("Station name")
                .accessibilityIdentifier("addStation.name")
                .popIn(0)
            Group {
                if let error = AddStationWalkthrough.nameError(progress),
                   !(error == .emptyName && typedName.isEmpty && creation.suggestedName == nil) {
                    Label(error.userMessage, systemImage: "exclamationmark.circle")
                } else if typedName.trimmingCharacters(in: .whitespaces).isEmpty, let suggested = creation.suggestedName {
                    Text("Leave it blank to use \u{201C}\(suggested)\u{201D}.")
                }
            }
            .font(.caption)
            .foregroundStyle(AddStationStyle.secondary)
            .popIn(1)
        }
    }

    // MARK: Step 7: review and save

    @ViewBuilder
    private var reviewStep: some View {
        if let savedName {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.white)
                    .accessibilityHidden(true)
                Text("\u{201C}\(savedName)\u{201D} is in your Stations list. Open it there when you want it. Nothing that's playing changed.")
                    .font(.subheadline).foregroundStyle(AddStationStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .addStationCard()
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("addStation.saved")
            .popIn(0)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                AddStationSummaryCard(
                    name: (try? AddStationWalkthrough.resolvedName(progress).get()) ?? "",
                    kind: chosenKind ?? creation.kind,
                    picks: creation.selected.map(\.name),
                    level: creation.level,
                    restriction: creation.reachRestriction,
                    personality: AddStationTuning.reviewValue(creation.personality,
                                                              current: studio.station.displayed.personality),
                    talk: AddStationTuning.reviewValue(creation.commentary,
                                                       current: studio.station.displayed.commentary))
                .popIn(0)
                if let error = creation.saveError {
                    Label(error.userMessage, systemImage: "exclamationmark.triangle")
                        .font(.subheadline).foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("addStation.error")
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if savedName == nil, step.previous != nil {
                Button { goBack() } label: {
                    Text("Back").frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .addStationCard(radius: AddStationStyle.controlRadius)
                .disabled(!AddStationWalkthrough.canGoBack(from: step, progress))
                .accessibilityIdentifier("addStation.back")
            }
            if savedName != nil {
                primaryButton("Done", id: "addStation.done", enabled: true) { onClose() }
            } else if step == .review {
                primaryButton(creation.isSaving ? "Saving…" : "Save station", id: "addStation.save",
                              enabled: AddStationWalkthrough.canSave(on: step, progress)) { save() }
                    .accessibilityHint("Adds it to your Stations list. What's playing doesn't change.")
            } else {
                primaryButton("Next", id: "addStation.next",
                              enabled: AddStationWalkthrough.canGoNext(from: step, progress)) { goNext() }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .background(AddStationStyle.canvas)
    }

    private func primaryButton(_ title: String, id: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 50)
                .foregroundStyle(AddStationStyle.canvas)
                .background(RoundedRectangle(cornerRadius: AddStationStyle.controlRadius, style: .continuous)
                    .fill(Color.white.opacity(enabled ? 1 : 0.35)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityIdentifier(id)
    }

    private func move(to target: AddStationStep) {
        forward = target > step
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.86)) {
            step = target
        }
        headingFocused = true
    }

    private func goNext() {
        guard AddStationWalkthrough.canGoNext(from: step, progress), let next = step.next else { return }
        move(to: next)
    }

    private func goBack() {
        guard AddStationWalkthrough.canGoBack(from: step, progress), let previous = step.previous else { return }
        move(to: previous)
    }

    private func save() {
        guard AddStationWalkthrough.canSave(on: step, progress),
              case .success(let name) = AddStationWalkthrough.resolvedName(progress) else { return }
        Task {
            // `StationCreationModel.save` → `studio.saveRecipe(named:from:applying:)`. Never applies.
            if case .success(let recipe) = await creation.save(named: name, applying: false) {
                withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.8)) {
                    savedName = recipe.name
                }
                headingFocused = true
            }
        }
    }
}

/// One segment per step: done, current (wider) and upcoming. Neutral only.
private struct StepIndicator: View {
    let current: AddStationStep
    let complete: (AddStationStep) -> Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            ForEach(AddStationStep.allCases, id: \.self) { step in
                Capsule()
                    .fill(fill(step))
                    .frame(width: step == current ? 28 : 14, height: 6)
            }
            Spacer(minLength: 8)
            Text(current.title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(AddStationStyle.secondary)
        }
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8), value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(current.accessibilityLabel)
        .accessibilityIdentifier("addStation.stepIndicator")
    }

    private func fill(_ step: AddStationStep) -> Color {
        if step == current { return .white }
        if step < current, complete(step) { return .white.opacity(0.55) }
        return .white.opacity(0.18)
    }
}

/// A tappable option card (kind, level, DJ, talk).
private struct ChoiceCard: View {
    let title: String
    let detail: String
    let systemImage: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .frame(width: 28)
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).foregroundStyle(.white)
                    Text(detail).font(.subheadline).foregroundStyle(AddStationStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.white : AddStationStyle.secondary)
                    .accessibilityHidden(true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .addStationCard(selected: selected)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title). \(detail)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The review card: what will be saved. DJ and talk are the walkthrough's choices, or the Tune
/// values marked "(from Tune)". Voice is read-only: a recipe doesn't store one.
struct AddStationSummaryCard: View {
    let name: String
    let kind: StationCreationKind
    let picks: [String]
    let level: StationDiscoveryLevel
    let restriction: StationReachRestriction?
    /// `AddStationTuning.reviewValue` strings.
    let personality: String
    let talk: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(name.isEmpty ? "Untitled station" : name)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(2)
            row("Built from", "\(kind.title): \(picks.joined(separator: ", "))")
            row("Discovery", "\(level.title). \(level.summary)")
            if let restriction { row("Reach", restriction.message) }
            row("DJ", personality)
            row("DJ talk", talk)
            row("Voice", AddStationTuning.voiceNote)
            Text("Adds it to your Stations list. It won't change what's playing.")
                .font(.caption)
                .foregroundStyle(AddStationStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .addStationCard()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("addStation.summary")
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AddStationStyle.secondary)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Previews (synthetic seeds, in memory; no MusicKit, no network)

#if DEBUG
/// Canned seed search for previews only.
private struct PreviewSeedSearch: StationSeedSearching {
    func searchSeeds(_ term: String, kinds: Set<StationSeedKind>, limit: Int) async throws -> [StationSeedSearchResult] {
        if kinds.contains(.playlist) {
            return [StationSeedSearchResult(seed: StationSeed(kind: .playlist, catalogID: "pl.1", name: "[TEST] Sunday Slow"),
                                            subtitle: "Apple Music")]
        }
        return ["Orbitelle", "sleepyfern", "Noelle Ashby", "Lucía Arenas", "The Theo Marlow Quartet", "Jalen Prospero"].enumerated().map {
            StationSeedSearchResult(seed: StationSeed(kind: .artist, catalogID: "\(100 + $0.offset)", name: "[TEST] \($0.element)"))
        }
    }

    func genreSeeds(matching query: String) async throws -> [StationSeedSearchResult] {
        [("14", "Pop"), ("11", "Jazz"), ("7", "Electronic"), ("21", "Rock")].map {
            StationSeedSearchResult(seed: StationSeed(kind: .genre, catalogID: $0.0, name: $0.1))
        }
    }

    func libraryPlaylistSeeds(limit: Int) async throws -> [StationSeedSearchResult] {
        [StationSeedSearchResult(seed: StationSeed(kind: .playlist, catalogID: "lib.1", name: "[TEST] Road Trip", source: .library))]
    }
}

private struct AddStationPreview: View {
    let step: AddStationStep
    var kind: StationCreationKind = .artists
    @State private var loaded: (StudioPresentationModel, StationCreationModel)?

    var body: some View {
        Group {
            if let loaded {
                AddStationWalkthroughView(studio: loaded.0, creation: loaded.1, initialStep: step,
                                          initialKind: step > .kind ? kind : nil) {}
            } else {
                ProgressView()
            }
        }
        .task {
            let studio = await StudioPresentationModel.preview()
            let creation = StationCreationModel(studio: studio, search: PreviewSeedSearch(), kind: kind)
            if step > .picks {
                let seeds = try? await PreviewSeedSearch().searchSeeds("", kinds: [kind.seedKind], limit: 2)
                for row in (seeds ?? []).prefix(2) { creation.toggle(row.seed) }
            }
            loaded = (studio, creation)
        }
    }
}

#Preview("1 Start from") { AddStationPreview(step: .kind) }
#Preview("2 Pick artists") { AddStationPreview(step: .picks) }
#Preview("2 Pick genre") { AddStationPreview(step: .picks, kind: .genre) }
#Preview("3 Discovery") { AddStationPreview(step: .level) }
#Preview("4 DJ") { AddStationPreview(step: .personality) }
#Preview("5 Talk") { AddStationPreview(step: .talk) }
#Preview("6 Name") { AddStationPreview(step: .name) }
#Preview("7 Review") { AddStationPreview(step: .review) }
#endif
