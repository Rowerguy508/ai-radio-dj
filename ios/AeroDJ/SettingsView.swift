import AeroDJCore
import SwiftUI

/// App settings sheet (-Fry), opened from the gear on the Stations list. Every build.
/// DJ talk-over & fades (`TalkoverSettingsRow`), then "Stations layout" (the open Duo's three
/// Stations designs, -Nova), then station ratings' "Clear all ratings"
/// (-Nova, PR B; only when the app root set `\.songRating`), then "Delete DJ clips, ratings and
/// location" (Sentinel's #410 n4, -Fry; the app's one purge-all, `PersonalDataReset`).
struct SettingsView: View {
    @Binding var isPresented: Bool
    /// Fixture mode: the talk-over row's unset default is OFF, matching the coordinator.
    let isTestStation: Bool
    /// Nil (previews): no `PersonalDataReset` row.
    var personalDataReset: (any PersonalNarrationResetting)? = nil
    @Environment(\.songRating) private var songRating

    var body: some View {
        SplitBarHost(preferred: .trailing) { insets in
            NavigationStack {
                Form {
                    TalkoverSettingsRow(isTestStation: isTestStation)
                    StationsLayoutSettingsSection()
                    if let songRating { StationRatingsSettingsSection(controller: songRating) }
                    if let personalDataReset { PersonalDataResetSection(purger: personalDataReset) }
                    #if DEBUG
                    // #526 S0a: DEBUG-only developer entry, live mode only (never in captures or
                    // fixture runs). Release does not compile it.
                    if !isTestStation {
                        Section("Developer (DEBUG)") {
                            NavigationLink("S0a AirPlay duck spike") { AirPlayDuckSpikeView() }
                                .accessibilityIdentifier("settings.debug.s0aSpike")
                        }
                    }
                    #endif
                }
                // A Form keeps a 16 pt row margin and lays that out from its own
                // bounds, ignoring the host's safeAreaInset. Same as the split
                // library list. Nil insets is the phone sheet, with no padding.
                .modifier(SplitFormPadding(insets: insets))
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: SplitToolbar.placement(
                        preferred: .trailing, edge: insets?.barEdge,
                        leading: .topBarLeading, trailing: .confirmationAction)) {
                        Button("Done") { isPresented = false }
                            .modifier(SplitMinimumTarget(enabled: insets != nil))
                            .accessibilityIdentifier("settings.done")
                    }
                }
            }
        }
    }
}

/// "Stations layout" (owner, 2026-11-17): which of the three open-Duo Stations designs to show.
/// A plain `UserDefaults.standard` string under `StationsLayoutStyle.defaultsKey`, the same
/// pattern as the talk-over toggle; never the App Group. Unset is A, the tile grid. iPhone and
/// the closed Duo keep the station list whatever is picked (the footer says so).
struct StationsLayoutSettingsSection: View {
    @AppStorage private var raw: String

    init(store: UserDefaults = .standard) {
        _raw = AppStorage(wrappedValue: StationsLayoutStyle.defaultStyle.rawValue,
                          StationsLayoutStyle.defaultsKey, store: store)
    }

    private var selected: StationsLayoutStyle { StationsLayoutStyle.resolve(raw: raw) }

    var body: some View {
        Section {
            ForEach(StationsLayoutStyle.allCases) { style in
                Button {
                    raw = style.rawValue
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(style.title).foregroundStyle(.primary)
                            Text(style.summary).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "checkmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.tint)
                            .opacity(style == selected ? 1 : 0)
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(style == selected ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("settings.stationsLayout.\(style.rawValue)")
            }
        } header: {
            Text("Stations layout")
        } footer: {
            Text("How Stations looks on the open Duo. iPhone and the closed Duo keep the station list.")
        }
    }
}

/// Pads a split Form by the host's extra insets. A nil inset is the phone sheet,
/// returned unchanged.
private struct SplitFormPadding: ViewModifier {
    var insets: SplitInsets?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let insets {
            content
                .padding(.leading, CGFloat(insets.padding.leading))
                .padding(.trailing, CGFloat(insets.padding.trailing))
        } else {
            content
        }
    }
}

/// "Delete DJ clips, ratings and location", with a confirmation. Runs `PersonalDataReset.run`,
/// which publishes the purge-all every data-reset listener already handles. It clears only what
/// `PersonalDataReset.message` lists.
struct PersonalDataResetSection: View {
    let purger: any PersonalNarrationResetting
    @State private var confirming = false
    @State private var deleting = false

    var body: some View {
        Section {
            Button(PersonalDataReset.title, role: .destructive) { confirming = true }
                .disabled(deleting)
                .accessibilityIdentifier(PersonalDataReset.accessibilityIdentifier)
                .confirmationDialog(PersonalDataReset.title, isPresented: $confirming, titleVisibility: .visible) {
                    Button(PersonalDataReset.confirm, role: .destructive) {
                        deleting = true
                        Task {
                            await PersonalDataReset.run(purger)
                            deleting = false
                        }
                    }
                } message: {
                    Text(PersonalDataReset.message)
                }
        } footer: {
            Text(PersonalDataReset.footer)
        }
    }
}

#Preview {
    SettingsView(isPresented: .constant(true), isTestStation: false)
}
