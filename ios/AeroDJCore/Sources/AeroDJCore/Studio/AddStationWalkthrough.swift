import Foundation

// Add-station walkthrough step logic (-Nova). Pure: which step is complete, when Next, Back and
// Save are enabled, and which name will be saved. The picks, search and save itself belong to
// Atlas's `StationCreationModel`; this only reads a snapshot of it, so it runs on Linux.
//
// Steps follow what `StationCreationRequest` can carry: a source kind, the picks, a discovery
// level, an optional DJ personality and talk level (`nil` keeps the Tune controls' values), and
// a name. There is no voice step: a recipe doesn't store a voice (it's chosen in Tune), so the
// review step shows it read-only.

/// One screen of the walkthrough, in order. Raw values are the 1-based step numbers used in
/// accessibility identifiers (`addStation.step.<n>`). Renumbered once, before release, when the
/// DJ and talk steps were added; don't renumber again after it ships.
public enum AddStationStep: Int, CaseIterable, Sendable, Hashable, Comparable {
    case kind = 1
    case picks = 2
    case level = 3
    case personality = 4
    case talk = 5
    case name = 6
    case review = 7

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var number: Int { rawValue }
    public var next: AddStationStep? { AddStationStep(rawValue: rawValue + 1) }
    public var previous: AddStationStep? { AddStationStep(rawValue: rawValue - 1) }

    /// Short title for the step indicator and the screen heading. Fixed copy.
    public var title: String {
        switch self {
        case .kind: "Start from"
        case .picks: "Pick"
        case .level: "Discovery"
        case .personality: "DJ"
        case .talk: "Talk"
        case .name: "Name"
        case .review: "Review"
        }
    }

    /// VoiceOver label for the step indicator: "Step 2 of 7, Pick".
    public var accessibilityLabel: String {
        "Step \(rawValue) of \(Self.allCases.count), \(title)"
    }
}

/// What the walkthrough needs to know about the flow right now. Built from `StationCreationModel`
/// (`kind`, `validationError`, `suggestedName`, `isSaving`) plus the name field and existing recipes.
public struct AddStationProgress: Equatable, Sendable {
    public var kind: StationCreationKind?
    /// `StationCreationModel.validationError`: nil when the picks can be saved.
    public var pickError: StationCreationError?
    public var level: StationDiscoveryLevel?
    /// What the listener typed in the name field ("" when untouched).
    public var typedName: String
    /// `StationCreationModel.suggestedName`, used when the field is blank.
    public var suggestedName: String?
    /// Names already saved, compared case-insensitively like `StationRecipeLibrary`.
    public var existingNames: [String]
    public var isSaving: Bool

    public init(kind: StationCreationKind? = nil, pickError: StationCreationError? = .noSeeds,
                level: StationDiscoveryLevel? = nil, typedName: String = "", suggestedName: String? = nil,
                existingNames: [String] = [], isSaving: Bool = false) {
        self.kind = kind
        self.pickError = pickError
        self.level = level
        self.typedName = typedName
        self.suggestedName = suggestedName
        self.existingNames = existingNames
        self.isSaving = isSaving
    }
}

public enum AddStationWalkthrough {
    /// The name Save will use: the typed name when it isn't blank, otherwise the suggestion,
    /// normalized by the recipe name rules. Fails with the recipe error the library would return.
    public static func resolvedName(_ p: AddStationProgress) -> Result<String, StationRecipeError> {
        let typed = p.typedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = typed.isEmpty ? (p.suggestedName ?? "") : typed
        switch StationRecipe.normalizedName(raw) {
        case .failure(let e): return .failure(e)
        case .success(let name):
            let taken = p.existingNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
            return taken ? .failure(.duplicateName) : .success(name)
        }
    }

    /// The name's problem for inline copy, or nil when it can be saved.
    public static func nameError(_ p: AddStationProgress) -> StationRecipeError? {
        if case .failure(let e) = resolvedName(p) { return e }
        return nil
    }

    public static func isComplete(_ step: AddStationStep, _ p: AddStationProgress) -> Bool {
        switch step {
        case .kind: p.kind != nil
        case .picks: p.kind != nil && p.pickError == nil
        case .level: p.level != nil
        // Optional: `nil` ("Keep current tuning") is a complete answer.
        case .personality, .talk: true
        case .name: nameError(p) == nil
        case .review: AddStationStep.allCases.filter { $0 != .review }.allSatisfy { isComplete($0, p) }
        }
    }

    /// Next is shown on every step but the last and is enabled once this step is complete.
    public static func canGoNext(from step: AddStationStep, _ p: AddStationProgress) -> Bool {
        step.next != nil && isComplete(step, p) && !p.isSaving
    }

    /// Back is available after the first step, except while a save is running.
    public static func canGoBack(from step: AddStationStep, _ p: AddStationProgress) -> Bool {
        step.previous != nil && !p.isSaving
    }

    /// Save lives on the review step only.
    public static func canSave(on step: AddStationStep, _ p: AddStationProgress) -> Bool {
        step == .review && isComplete(.review, p) && !p.isSaving
    }

    /// The furthest step the listener may jump to from the indicator: the first incomplete
    /// step, or review when everything is done.
    public static func furthestReachable(_ p: AddStationProgress) -> AddStationStep {
        AddStationStep.allCases.first { !isComplete($0, p) } ?? .review
    }

    /// Hint under the picks step: how many may be picked for this kind. Fixed copy.
    public static func pickHint(for kind: StationCreationKind) -> String {
        switch kind {
        case .artists: "Pick up to \(StationCreationRequest.maxArtists) artists."
        case .genre: "Pick one genre."
        case .playlist: "Pick one playlist, from Apple Music or your library."
        }
    }

    /// One-line description for the kind choice. Fixed copy.
    public static func kindSummary(_ kind: StationCreationKind) -> String {
        switch kind {
        case .artists: "One to \(StationCreationRequest.maxArtists) artists you love."
        case .genre: "One Apple Music genre."
        case .playlist: "A playlist, from Apple Music or your library."
        }
    }
}

/// Choices for the optional DJ personality and talk-level steps (-Nova). `nil` is
/// "Keep current tuning": the request leaves the field unset and the station keeps the value the
/// Tune controls show. Copy reuses the Tune strings (`title`, `honestDescription`), so talk shares
/// are the planner's delivered share (Chatty says "every song" with the owner's #165 override).
public enum AddStationTuning {
    public static let keepTitle = "Keep current tuning"

    /// "Keep current tuning" first, then every preset in declaration order.
    public static var personalityOptions: [DJPersonality?] { [nil] + DJPersonality.allCases.map(Optional.some) }
    public static var talkOptions: [CommentaryFrequency?] { [nil] + CommentaryFrequency.allCases.map(Optional.some) }

    public static func title(_ p: DJPersonality?) -> String { p?.title ?? keepTitle }
    public static func title(_ c: CommentaryFrequency?) -> String { c?.title ?? keepTitle }

    /// Detail line. For `nil`, names the Tune value the station will keep.
    public static func detail(_ p: DJPersonality?, current: DJPersonality) -> String {
        p?.honestDescription ?? "Uses your Tune setting: \(current.title)."
    }

    public static func detail(_ c: CommentaryFrequency?, current: CommentaryFrequency) -> String {
        c?.honestDescription ?? "Uses your Tune setting: \(current.title)."
    }

    /// Accessibility identifier suffix: `keep` or the persisted raw value.
    public static func idSuffix(_ p: DJPersonality?) -> String { p?.rawValue ?? "keep" }
    public static func idSuffix(_ c: CommentaryFrequency?) -> String { c?.rawValue ?? "keep" }

    /// Review-card value: the effective setting, marked when it comes from Tune.
    public static func reviewValue(_ p: DJPersonality?, current: DJPersonality) -> String {
        p.map(\.title) ?? "\(current.title) (from Tune)"
    }

    public static func reviewValue(_ c: CommentaryFrequency?, current: CommentaryFrequency) -> String {
        c.map(\.title) ?? "\(current.title) (from Tune)"
    }

    /// Read-only voice row on the review card. A recipe doesn't store a voice.
    public static let voiceNote = "Same voice on every station. Set it in Tune."
}
