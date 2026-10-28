#if AERODJ_P0_DIAG
// TEMPORARY P0 Experiment A: MusicKit Direct Mode screen (remove with #121 / #133) -Atlas
import AeroDJCore
import SwiftUI
import UIKit

struct DirectModeView: View {
    @StateObject private var controller = DirectModeController()
    @State private var normalNextLaunch = UserDefaults.standard.bool(forKey: DirectModeLaunch.normalOnceKey)

    private var m: DirectModeMachine { controller.machine }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("P0 DIAGNOSTIC BUILD · Direct Mode · not for App Store")
                    .font(.caption.bold()).foregroundStyle(.white)
                    .padding(6).frame(maxWidth: .infinity).background(.red)
                    .accessibilityIdentifier(DirectModeLaunch.buildMarker)

                Text(m.everPlaying ? "PLAYING REACHED" : "NOT YET PLAYING")
                    .font(.largeTitle.bold()).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .background(m.everPlaying ? Color.green : Color.gray)
                    .accessibilityIdentifier("directMode.everPlaying")

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    row("Old MusicKitService", CompositionRootProbe.dependenciesBuilt ? "STARTED" : "never started")
                    row("Position", Self.clock(m.position))
                    row("Moved past 0:00", m.positionEverAdvanced ? "yes" : "no")
                    row("Status", m.status.rawValue)
                    row("Song", m.entryIndex.map { Self.songLabel($0, m.songSet) } ?? (m.queueLoaded ? "OTHER" : "none"))
                    row("Song set", m.songSet.rawValue)
                    row("Heard after play", m.heardAfterPlay.map { String(format: "%.1f s", $0) } ?? "not yet")
                    row("Unexpected queue", m.unexpectedQueueSeen ? "YES" : "no")
                    row("Authorization", m.authorization.rawValue)
                    row("canPlayCatalogContent", m.canPlayCatalogContent.map { $0 ? "true" : "false" } ?? "unknown")
                    row("Route", m.route.rawValue)
                    row("Catalog lookup", controller.lookupFound.map { "\($0) of \(DirectModeSongs.ids(for: m.songSet).count)" } ?? "not loaded")
                    row("Command in flight", m.inFlight?.rawValue ?? "none")
                    row("Last error", m.lastError?.description ?? "none")
                }
                .font(.body.monospaced())

                Picker("Songs", selection: Binding(get: { m.songSet }, set: { controller.selectSongSet($0) })) {
                    Text("A then B").tag(DirectModeSongSet.standard)
                    Text("Loud from 0:00, then A").tag(DirectModeSongSet.loudFirst)
                }
                .pickerStyle(.segmented)
                .disabled(m.queueLoaded || m.inFlight == .load)
                .accessibilityIdentifier("directMode.songSet")

                HStack {
                    button("Load", .load, controller.load)
                    button("Play", .play, controller.play)
                    button("Pause", .pause, controller.pause)
                }
                HStack {
                    button("Resume", .resume, controller.resume)
                    button("Next song", .next, controller.next)
                }

                Button("I hear it", action: controller.markHeard)
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .buttonStyle(.borderedProminent).tint(.orange)
                    .disabled(m.playRequestedAt == nil)
                    .accessibilityIdentifier("directMode.heard")

                DirectModeLayerPanel(host: controller.layers)
                DirectModeSessionLayerPanel(host: controller.session)

                Toggle("Next launch: normal app (once)", isOn: $normalNextLaunch)
                    .onChange(of: normalNextLaunch) { _, on in
                        UserDefaults.standard.set(on, forKey: DirectModeLaunch.normalOnceKey)
                    }

                HStack {
                    Text("Log (newest first)").font(.headline)
                    Spacer()
                    Button("Copy log") {
                        UIPasteboard.general.string = (["oldMusicKitService=\(CompositionRootProbe.dependenciesBuilt ? "started" : "neverStarted")"]
                            + DirectModePlayPathTrace.mergedLog(m.log, controller.layers.stack.trace, controller.session.layer.trace, controller.servicePath.trace.entries)).joined(separator: "\n")
                    }
                }
                ForEach(Array(DirectModePlayPathTrace.mergedLog(m.log, controller.layers.stack.trace, controller.session.layer.trace, controller.servicePath.trace.entries).enumerated().reversed()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced())
                }
            }
            .padding()
        }
        .onAppear { controller.start() }
        .onDisappear { controller.stop() }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }

    private func button(_ title: String, _ command: DirectModeCommand, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .disabled(m.refusal(command) != nil)
            .accessibilityIdentifier("directMode.\(command.rawValue)")
    }

    private static func songLabel(_ index: Int, _ set: DirectModeSongSet) -> String {
        switch set {
        case .standard: return index == 0 ? "A" : "B"
        case .loudFirst: return index == 0 ? "LOUD" : "A"
        }
    }

    private static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
#endif
