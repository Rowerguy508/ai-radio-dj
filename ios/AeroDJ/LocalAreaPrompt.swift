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
        .padding(24)
        .interactiveDismissDisabled(false)
    }

    private func saveTyped() {
        if store.chooseManual(place) { onDone() } else { rejected = true }
    }
}
