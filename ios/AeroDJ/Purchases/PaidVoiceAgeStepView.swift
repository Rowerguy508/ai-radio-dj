import AeroDJCore
import SwiftUI

// The Pro voice 18+ step (-Nova, on Fry's #267). Model, copy and rules live in AeroDJCore
// (`PaidVoiceAgeStepModel`, `PaidVoiceAgeStepCopy`, PaidVoiceAgeStepTests). Storage is Fry's
// `PaidVoiceAgeStore` (this-device-only Keychain item); nothing here reads or writes it directly.
// Nothing here is logged.

extension View {
    /// The age step where the Pro voice needs it: a sheet that opens on its own once Pro and
    /// consent allow the paid voice and the age is unanswered, plus a toolbar entry to change or
    /// clear the answer later. When neither applies (every free listener, every current build
    /// until the paywall and consent are wired) it adds no toolbar item and never shows a sheet.
    func paidVoiceAgeEntry(_ model: PaidVoiceAgeStepModel) -> some View {
        modifier(PaidVoiceAgeEntry(model: model))
    }
}

private struct PaidVoiceAgeEntry: ViewModifier {
    let model: PaidVoiceAgeStepModel
    @State private var showStep = false
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .toolbar {
                if model.showsChangeEntry {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            model.beginReview()
                            showStep = true
                        } label: {
                            Label(PaidVoiceAgeStepCopy.entryTitle, systemImage: "person.crop.circle.badge.checkmark")
                        }
                        .accessibilityIdentifier("ageStep.entry")
                        .accessibilityValue(PaidVoiceAgeStepCopy.currentAnswer(model.answer))
                    }
                }
            }
            .sheet(isPresented: $showStep, onDismiss: { model.dismiss() }) {
                PaidVoiceAgeStepSheet(model: model) { showStep = false }
            }
            .task { await refreshAndOffer() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await refreshAndOffer() }
            }
    }

    private func refreshAndOffer() async {
        await model.refresh()
        if model.offersStep, !showStep {
            model.beginReview()
            showStep = true
        }
    }
}

/// The sheet: the question, Yes / No, and (once answered) the current answer and Clear.
/// After a write it shows the result line and Done. "Not now" and a swipe store nothing.
struct PaidVoiceAgeStepSheet: View {
    let model: PaidVoiceAgeStepModel
    let close: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                PaidVoiceAgeStepContent(model: model)
                    .padding(20)
                    .frame(maxWidth: 560, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .navigationTitle(PaidVoiceAgeStepCopy.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if model.confirmation == nil {
                        Button(PaidVoiceAgeStepCopy.notNow) {
                            model.dismiss()
                            close()
                        }
                        .accessibilityIdentifier("ageStep.notNow")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.confirmation != nil {
                        Button(PaidVoiceAgeStepCopy.done) { close() }
                            .accessibilityIdentifier("ageStep.done")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// The step's body inside the sheet (also what the Debug capture `StudioCaptureScenario.ageStep` shows).
struct PaidVoiceAgeStepContent: View {
    let model: PaidVoiceAgeStepModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.largeTitle)
                .foregroundStyle(AeroDJPalette.accentText)
                .accessibilityHidden(true)
            Text(PaidVoiceAgeStepCopy.title)
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("ageStep.title")
            Text(PaidVoiceAgeStepCopy.detail)
                .font(.body)
                .foregroundStyle(AeroDJPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let confirmation = model.confirmation {
                Label(confirmation, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AeroDJPalette.statusPositive)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ageStep.confirmation")
            } else {
                if model.answer != .unanswered {
                    Text(PaidVoiceAgeStepCopy.currentAnswer(model.answer))
                        .font(.subheadline)
                        .foregroundStyle(AeroDJPalette.secondaryText)
                        .accessibilityIdentifier("ageStep.current")
                }
                VStack(spacing: 10) {
                    Button {
                        Task { await model.answer(isAdult: true) }
                    } label: {
                        Text(PaidVoiceAgeStepCopy.yes).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("ageStep.yes")
                    Button {
                        Task { await model.answer(isAdult: false) }
                    } label: {
                        Text(PaidVoiceAgeStepCopy.no).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityIdentifier("ageStep.no")
                    if model.answer != .unanswered {
                        Button(PaidVoiceAgeStepCopy.clear, role: .destructive) {
                            Task { await model.clearAnswer() }
                        }
                        .controlSize(.small)
                        .accessibilityIdentifier("ageStep.clear")
                    }
                }
            }
            Text(PaidVoiceAgeStepCopy.footer)
                .font(.footnote)
                .foregroundStyle(AeroDJPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("ageStep.footer")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ageStep")
    }
}
