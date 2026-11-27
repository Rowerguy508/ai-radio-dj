import Foundation

/// Pure layout decision for the Open-Duo Landscape horizontal Onboarding / Consent flows
/// (#461 PR 4, mockup `04-onboarding-duo.png`).
///
/// Layout only: `LocalAreaConsentCopy` and `CloudVoiceConsentCopy` wording, version numbers,
/// and button actions stay 100% verbatim and untouched.
///
/// On iPhone, closed Duo, Open-Duo Portrait (`640 × 820 pt`, `duoWideLocalArea`), narrow Split
/// View, and accessibility text sizes, onboarding screens stay `.singleColumn` so existing phone
/// and Duo-portrait snapshots remain byte-identical.
///
/// On Open-Duo Landscape (`820 × 640 pt`) and other wide landscape containers, onboarding uses
/// `.twoPane`: disclosure copy on the left (`370 pt`), a 32 pt center fold gutter aligned to
/// device midpoint (`[394, 426]`, centered on `x = 410 pt`), and primary/secondary actions on
/// the right (`370 pt`, ≥ 44 pt hit targets).
///
/// -Nova
public enum OnboardingDuoLayout {
    public static let minWideWidth: Double = 700
    public static let minWideHeight: Double = 520
    public static let minPaneWidth: Double = 280
    public static let gutterWidth: Double = 32
    public static let targetSideInset: Double = 24

    public static let localAreaTwoPaneID = "onboarding.localArea.twoPane"
    public static let localAreaCopyPaneID = "onboarding.localArea.pane.copy"
    public static let localAreaActionsPaneID = "onboarding.localArea.pane.actions"
    public static let consentTwoPaneID = "onboarding.consent.twoPane"
    public static let consentCopyPaneID = "onboarding.consent.pane.copy"
    public static let consentActionsPaneID = "onboarding.consent.pane.actions"

    public enum Mode: String, Equatable, Sendable {
        case singleColumn
        case twoPane
    }

    public struct Input: Equatable, Sendable {
        public var containerWidth: Double
        public var containerHeight: Double
        public var accessibilityTextSize: Bool
        /// Optional vertical fold center in container coordinates; defaults to `containerWidth / 2`
        /// (`x = 410 pt` on an `820 × 640 pt` Open-Duo Landscape window).
        public var foldCenterX: Double?

        public init(containerWidth: Double,
                    containerHeight: Double,
                    accessibilityTextSize: Bool = false,
                    foldCenterX: Double? = nil) {
            self.containerWidth = containerWidth
            self.containerHeight = containerHeight
            self.accessibilityTextSize = accessibilityTextSize
            self.foldCenterX = foldCenterX
        }
    }

    public struct Decision: Equatable, Sendable {
        public let mode: Mode
        public let leadingPadding: Double
        public let leftPaneWidth: Double
        public let gutterWidth: Double
        public let rightPaneWidth: Double
        public let trailingPadding: Double

        public init(mode: Mode,
                    leadingPadding: Double = 0,
                    leftPaneWidth: Double = 0,
                    gutterWidth: Double = 0,
                    rightPaneWidth: Double = 0,
                    trailingPadding: Double = 0) {
            self.mode = mode
            self.leadingPadding = leadingPadding
            self.leftPaneWidth = leftPaneWidth
            self.gutterWidth = gutterWidth
            self.rightPaneWidth = rightPaneWidth
            self.trailingPadding = trailingPadding
        }

        public var gutterMinX: Double { leadingPadding + leftPaneWidth }
        public var gutterMaxX: Double { gutterMinX + gutterWidth }
        public var gutterMidX: Double { gutterMinX + gutterWidth / 2 }
        public var totalWidth: Double {
            leadingPadding + leftPaneWidth + gutterWidth + rightPaneWidth + trailingPadding
        }

        public var decisionText: String {
            switch mode {
            case .singleColumn:
                return "singleColumn"
            case .twoPane:
                return "twoPane \(Int(leftPaneWidth.rounded()))/\(Int(rightPaneWidth.rounded()))"
            }
        }
    }

    public static let duoLandscape = Input(containerWidth: 820, containerHeight: 640)
    public static let duoPortrait = Input(containerWidth: 640, containerHeight: 820)

    public static func decide(_ input: Input) -> Decision {
        let width = input.containerWidth
        let height = input.containerHeight

        guard !input.accessibilityTextSize,
              width.isFinite, height.isFinite,
              width >= minWideWidth,
              height >= minWideHeight,
              width > height else {
            return Decision(mode: .singleColumn)
        }

        let leading = targetSideInset
        let trailing = targetSideInset
        let foldX = input.foldCenterX ?? (width / 2)

        let left = foldX - leading - (gutterWidth / 2)
        let right = width - leading - left - gutterWidth - trailing

        guard left >= minPaneWidth, right >= minPaneWidth else {
            return Decision(mode: .singleColumn)
        }

        return Decision(mode: .twoPane,
                        leadingPadding: leading,
                        leftPaneWidth: left,
                        gutterWidth: gutterWidth,
                        rightPaneWidth: right,
                        trailingPadding: trailing)
    }
}
