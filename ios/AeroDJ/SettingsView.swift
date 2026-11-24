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
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var containerSize: CGSize = .zero
    @State private var selectedCategory: SettingsMasterDetailLayout.Category = .playback

    private var availableCategories: [SettingsMasterDetailLayout.Category] {
        SettingsMasterDetailLayout.availableCategories(
            hasRatings: songRating != nil,
            hasPersonalDataReset: personalDataReset != nil
        )
    }

    private var activeCategory: SettingsMasterDetailLayout.Category {
        SettingsMasterDetailLayout.resolvedSelection(
            selectedCategory,
            hasRatings: songRating != nil,
            hasPersonalDataReset: personalDataReset != nil
        )
    }

    var body: some View {
        SplitBarHost(preferred: .trailing) { insets in
            let decision = SettingsMasterDetailLayout.decide(.init(
                containerWidth: containerSize.width,
                containerHeight: containerSize.height,
                accessibilityTextSize: typeSize.isAccessibilitySize,
                hasSplitInsets: insets != nil
            ))
            Group {
                if decision.mode == .masterDetail {
                    masterDetailBody(decision)
                } else {
                    singleColumnBody(insets: insets)
                }
            }
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { newSize in
                containerSize = newSize
            }
        }
    }

    private func singleColumnBody(insets: SplitInsets?) -> some View {
        NavigationStack {
            Form {
                TalkoverSettingsRow(isTestStation: isTestStation)
                StationsLayoutSettingsSection()
                if let songRating { StationRatingsSettingsSection(controller: songRating) }
                if let personalDataReset { PersonalDataResetSection(purger: personalDataReset) }
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

    /// Open-Duo Landscape master-detail Settings (#461 PR 2, mockup 01-settings-duo.png):
    /// categories on the left, selected category's controls on the right, 32 pt center gutter
    /// aligned to device midpoint (x = 410 pt), and a 56 pt trailing rail holding Done (>= 44 pt).
    /// -Nova
    private func masterDetailBody(_ decision: SettingsMasterDetailLayout.Decision) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Color.clear.frame(width: CGFloat(decision.leadingPadding))

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Settings")
                        .font(.title2.weight(.bold))
                        .padding(.top, 16)
                        .padding(.bottom, 6)
                        .accessibilityAddTraits(.isHeader)

                    ForEach(availableCategories) { category in
                        let isSelected = category == activeCategory
                        Button {
                            selectedCategory = category
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: category.systemImage)
                                    .font(.system(size: 16, weight: .semibold))
                                    .frame(width: 28, height: 28)
                                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(category.title)
                                        .font(.body.weight(isSelected ? .semibold : .regular))
                                        .foregroundStyle(Color.primary)
                                    Text(category.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(Color.secondary)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.secondary.opacity(isSelected ? 0.9 : 0.4))
                                    .accessibilityHidden(true)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(isSelected ? Color.primary.opacity(0.10) : Color(.secondarySystemGroupedBackground))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(isSelected ? 0.16 : 0.06), lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                        .accessibilityIdentifier("settings.category.\(category.rawValue)")
                    }
                }
                .padding(.bottom, 16)
            }
            .frame(width: CGFloat(decision.masterWidth))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.master")

            Color.clear
                .frame(width: CGFloat(decision.gutterWidth))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                Text(activeCategory.title)
                    .font(.title3.weight(.semibold))
                    .padding(.top, 18)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                    .accessibilityAddTraits(.isHeader)

                Form {
                    switch activeCategory {
                    case .playback:
                        TalkoverSettingsRow(isTestStation: isTestStation)
                    case .stationsLayout:
                        StationsLayoutSettingsSection()
                    case .ratings:
                        if let songRating { StationRatingsSettingsSection(controller: songRating) }
                    case .privacy:
                        if let personalDataReset { PersonalDataResetSection(purger: personalDataReset) }
                    }
                }
                // Override any outer `.appWideScreen(.settings, formMargins: true)` inset so the
                // 318 pt detail pane uses its full width cleanly without overlapping #602.
                .contentMargins(.horizontal, 8, for: .scrollContent)
                .scrollContentBackground(.hidden)
            }
            .frame(width: CGFloat(decision.detailWidth), alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.detail")

            Color.clear.frame(width: CGFloat(decision.trailingPadding))

            settingsTrailingRail(width: CGFloat(decision.railWidth))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.systemGroupedBackground))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.masterDetail")
    }

    private func settingsTrailingRail(width: CGFloat) -> some View {
        VStack(spacing: 12) {
            Button {
                isPresented = false
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.accentColor))
                    .foregroundStyle(Color.white)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel("Done")
            .accessibilityIdentifier("settings.done")

            Spacer(minLength: 8)
        }
        .padding(.vertical, 12)
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(Color(.secondarySystemBackground).opacity(0.65))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.rail")
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
