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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(LocalAreaConsentCopy.title).font(.title2.bold())
            Text(LocalAreaConsentCopy.body).font(.body).foregroundStyle(.secondary)
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
        .modifier(WideTargets(isOn: appWide != nil))
        .padding(24)
        .padding(.leading, CGFloat(appWide?.leadingInset ?? 0))
        .padding(.trailing, CGFloat(appWide?.trailingInset ?? 0))
        .interactiveDismissDisabled(false)
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
