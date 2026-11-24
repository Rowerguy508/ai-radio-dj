import AeroDJCore
import SwiftUI

/// #200 (-Echo): the opt-in explainer shown before the system location prompt. Minimal on
/// purpose: Fry owns station settings and consent UI, so this is not presented anywhere yet
/// (handoff: Tune → DJ). It records into `LocalAreaStore` only:
/// - "Use approximate location": `chooseApproximate()`, then the when-in-use system prompt.
/// - "Enter a city or ZIP instead": a validated typed place, stored on the device.
/// - "Not now": `decline()`. Swiping away leaves it undecided, which allows nothing. Either way
/// weather and local-news lines are omitted.
struct LocalAreaPrompt: View {
    let store: LocalAreaStore
    let location: CoarseDeviceLocation
    var onDone: () -> Void

    @State private var typing = false
    @State private var place = ""
    @State private var rejected = false
    /// #465 item 10 (onboarding): nil on every phone and narrow split, which adds 0 pt and
    /// keeps this prompt exactly as it was. Wide: holds the column at 560 pt. Layout only;
    /// the copy, the consent version and every action are unchanged (Sentinel, #509).
    @Environment(\.appWideLayout) private var appWide
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        GeometryReader { proxy in
            let layout = OnboardingDuoLayout.decide(.init(
                containerWidth: Double(proxy.size.width),
                containerHeight: Double(proxy.size.height),
                accessibilityTextSize: dynamicTypeSize.isAccessibilitySize))
            if layout.mode == .twoPane {
                twoPaneBody(layout)
            } else {
                singleColumnBody
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .interactiveDismissDisabled(false)
    }

    @ViewBuilder
    private var copyBlock: some View {
        Text(LocalAreaConsentCopy.title).font(.title2.bold())
        Text(LocalAreaConsentCopy.body).font(.body).foregroundStyle(.secondary)
    }

    private var singleColumnBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            copyBlock
            actionButtons
        }
        .modifier(WideTargets(isOn: appWide != nil))
        .padding(24)
        .padding(.horizontal, CGFloat(appWide?.sideInset ?? 0))
    }

    /// #461 PR 4 (-Nova): Open-Duo Landscape (`820 × 640 pt`) horizontal two-pane onboarding
    /// (`04-onboarding-duo.png`). Copy stays verbatim (`LocalAreaConsentCopy`) on the left,
    /// actions stay identical on the right, and a 32 pt center gutter clears the fold (`x = 410 pt`).
    private func twoPaneBody(_ layout: OnboardingDuoLayout.Decision) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: layout.leadingPadding)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    copyBlock
                }
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: layout.leftPaneWidth)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(OnboardingDuoLayout.localAreaCopyPaneID)

            Color.clear
                .frame(width: layout.gutterWidth)
                .accessibilityHidden(true)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    actionButtons
                }
                .modifier(WideTargets(isOn: true))
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: layout.rightPaneWidth)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(OnboardingDuoLayout.localAreaActionsPaneID)

            Color.clear.frame(width: layout.trailingPadding)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(OnboardingDuoLayout.localAreaTwoPaneID)
    }

    @ViewBuilder
    private var actionButtons: some View {
        if typing {
            TextField(LocalAreaConsentCopy.placeFieldPrompt, text: $place)
                .textContentType(.addressCityAndState)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit(saveTyped)
                .accessibilityIdentifier("localArea.place")
            if rejected {
                Text("Use letters, numbers, spaces and commas only.").font(.footnote).foregroundStyle(.red)
            }
            Button("Save", action: saveTyped).buttonStyle(.borderedProminent)
                .accessibilityIdentifier("localArea.save")
        } else {
            Button(LocalAreaConsentCopy.useApproximate) {
                store.chooseApproximate()
                Task {
                    await location.requestWhenInUse()
                    // The system prompt was declined: offer the typed fallback instead.
                    if location.isAuthorized { onDone() } else { typing = true }
                }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("localArea.approximate")
            Button(LocalAreaConsentCopy.enterPlace) { typing = true }
                .accessibilityIdentifier("localArea.manual")
        }
        Button(LocalAreaConsentCopy.notNow) {
            store.decline()
            onDone()
        }
        .accessibilityIdentifier("localArea.notNow")
    }

    private func saveTyped() {
        if store.chooseManual(place) { onDone() } else { rejected = true }
    }
}

/// #515 N1 (Fry): 44 pt targets on the wide path only. Phones and narrow split get the view
/// unchanged, so their snapshots stay byte-identical. Wide: the prominent buttons go to the
/// large control size and the plain text buttons get a 44 pt tall, fully tappable row. Same
/// labels, same actions; layout only.
private struct WideTargets: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if isOn {
            content.buttonStyle(WideTextButtonStyle()).controlSize(.large)
        } else {
            content
        }
    }
}

private struct WideTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.tint)
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.5 : 1)
    }
}
