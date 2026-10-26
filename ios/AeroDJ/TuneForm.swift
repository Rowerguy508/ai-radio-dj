import AeroDJCore
import SwiftUI

/// Made-up shared preview container: loads Fry's model asynchronously, then
/// renders a TuneForm (ui-contract.md §2.4). Status per control is read from
/// `model.status(for:)`; nothing here invents consent or connected state.
struct TuneFormPreviewLoader: View {
    @State private var model: StationConfigurationModel?

    var body: some View {
        Group {
            if let model {
                TuneForm(model: model)
            } else {
                ProgressView()
            }
        }
        .task { model = await StationConfigurationModel.preview() }
    }
}

/// The station tuner: every config control with its honest status and fate
/// (idle / saving / pending-boundary / consent-required / error). Editing is
/// disabled and the reason shown when settings aren't loaded or are newer.
struct TuneForm: View {
    let model: StationConfigurationModel

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                if case .failed(.newerVersion) = model.loadState {
                    settingsUnavailable("Update AeroDJ to change these settings.",
                                        state: .readOnlyNewerVersion)
                } else if case .failed = model.loadState {
                    settingsUnavailable("Loading your station settings.", state: .notLoaded)
                } else if case .notLoaded = model.loadState {
                    settingsUnavailable("Loading your station settings.", state: .notLoaded)
                } else {
                    controlSection
                }
            }
            .padding(.bottom, 16)
        }
    }

    @ViewBuilder
    private var controlSection: some View {
        let displayed = model.displayed

        tuneGroup("Genres") {
            ForEach(Array(displayed.genres.enumerated()), id: \.offset) { _, g in
                tagChip(g)
            }
            if displayed.genres.isEmpty {
                Text("No genres yet.").font(.caption).foregroundStyle(.secondary)
            }
        }

        tuneGroup("Moods") {
            ForEach(Array(displayed.moods.enumerated()), id: \.offset) { _, m in
                tagChip(m)
            }
            if displayed.moods.isEmpty {
                Text("No moods yet.").font(.caption).foregroundStyle(.secondary)
            }
        }

        energyControl(displayed.energy)
        discoveryControl(displayed.discovery)

        tuneGroup("DJ personality") {
            ForEach(DJPersonality.allCases, id: \.self) { p in
                Button {
                    Task { await model.setPersonality(p) }
                } label: {
                    HStack {
                        Text(title(for: p)).font(.subheadline)
                        Spacer()
                        if displayed.personality == p {
                            Image(systemName: "checkmark").font(.subheadline.weight(.semibold))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }

        tuneGroup("Commentary") {
            ForEach(CommentaryFrequency.allCases, id: \.self) { c in
                Button {
                    Task { await model.setCommentary(c) }
                } label: {
                    HStack {
                        Text(title(for: c)).font(.subheadline)
                        Spacer()
                        if displayed.commentary == c {
                            Image(systemName: "checkmark").font(.subheadline.weight(.semibold))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }

        briefingControl(displayed.briefing)
    }

    private func tuneGroup(_ name: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(name)
                .font(.subheadline.weight(.semibold))
            content()
        }
    }

    private func tagChip(_ tag: String) -> some View {
        Text(tag)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(.quaternary))
            .lineLimit(1)
    }

    private func energyControl(_ energy: Double) -> some View {
        statusControl("Energy", setting: .energy) {
            Slider(value: Binding(
                get: { model.displayed.energy },
                set: { newValue in Task { await model.setEnergy(newValue) } }
            ), in: 0...1)
            HStack {
                Text("Calm").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("High energy").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func discoveryControl(_ discovery: Double) -> some View {
        statusControl("Discovery", setting: .discovery) {
            Slider(value: Binding(
                get: { model.displayed.discovery },
                set: { newValue in Task { await model.setDiscovery(newValue) } }
            ), in: 0...1)
            HStack {
                Text("Favourites").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("New music").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func briefingControl(_ briefing: BriefingPreferences) -> some View {
        statusControl("Briefing", setting: .briefing) {
            Toggle("Morning briefing", isOn: Binding(
                get: { model.displayed.briefing.enabled },
                set: { newValue in Task {
                    await model.setBriefing { $0.enabled = newValue }
                } }
            ))
        }
    }

    @ViewBuilder
    private func statusControl(_ name: String, setting: StationSetting,
                               @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(name).font(.subheadline.weight(.semibold))
                Spacer()
                statusBadge(for: model.status(for: setting))
            }
            content()
        }
    }

    @ViewBuilder
    private func statusBadge(for status: StationControlStatus) -> some View {
        switch status {
        case .idle:
            EmptyView()
        case .saving:
            labelBadge("Saving…")
        case .pendingBoundary(let timing):
            labelBadge(copyForBoundary(timing))
        case .consentRequired(.denied):
            labelBadge("Access is off")
        case .consentRequired(.revoked):
            labelBadge("Revoked")
        case .consentRequired(.notRequested):
            labelBadge("Consent needed")
        case .consentRequired(.granted):
            EmptyView()
        case .error(let err):
            labelBadge(errorCopy(err), role: .destructive)
        }
    }

    @ViewBuilder
    private func labelBadge(_ text: String, role: ButtonRole? = nil) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(role == .destructive ? Color.red : Color.secondary)
            .background(Capsule().fill(.quaternary).padding(-6))
            .padding(6)
            .lineLimit(1)
    }

    private func copyForBoundary(_ timing: StationChangeTiming) -> String {
        switch timing {
        case .nextSongBoundary: "Applies after this song"
        case .nextDJBreak: "Applies at the next DJ break"
        case .nextBriefing: "Applies to the next briefing"
        case .immediate: "Applies now"
        }
    }

    private func errorCopy(_ error: StationControlError) -> String {
        switch error {
        case .notLoaded: "Loading your station settings"
        case .readOnlyNewerVersion: "Update AeroDJ to change this"
        case .saveFailed: "Could not save"
        case .reductionNotSaved: "Will save with next change"
        }
    }

    private func settingsUnavailable(_ message: String, state: StationControlError) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Station settings aren't editable right now.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
    }

    private func title(for personality: DJPersonality) -> String {
        switch personality {
        case .warm: "Warm"
        case .upbeat: "Upbeat"
        case .laidBack: "Laid-back"
        case .minimal: "Minimal"
        }
    }

    private func title(for cadence: CommentaryFrequency) -> String {
        switch cadence {
        case .off: "No commentary"
        case .rare: "Rarely"
        case .occasional: "Occasional"
        case .frequent: "Frequently"
        }
    }
}

#Preview("Tune form") {
    TuneFormPreviewLoader()
}
