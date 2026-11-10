import AeroDJCore
@preconcurrency import CarPlay
import Combine
import MediaPlayer
import Observation
import UIKit

/// CarPlay audio scene (#438). List template to pick a station, now-playing template
/// for the song. The phone's SwiftUI studio is not put on the car.
///
/// The system calls the delegate on the main thread. The controller is parked in a
/// nonisolated slot before the hop so the task does not capture it.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        CarPlaySession.handOff(interfaceController)
        Task { @MainActor in
            await CarPlaySession.shared.didConnect()
        }
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        Task { @MainActor in
            CarPlaySession.shared.didDisconnect()
        }
    }
}

/// The car UI. Station rows and now playing come from `CarPlayScreen`. A row starts
/// through `openCreatedStation(.userTap)`, the phone's created-station tap. Next and
/// previous are not handled here: next is the remote command already installed, and
/// previous stays disabled.
@MainActor
final class CarPlaySession {
    static let shared = CarPlaySession()

    nonisolated(unsafe) private static var handedController: CPInterfaceController?

    nonisolated static func handOff(_ controller: CPInterfaceController) {
        handedController = controller
    }

    private var interfaceController: CPInterfaceController?
    private var listTemplate: CPListTemplate?
    private var opened: StationRef?
    private var watchers = Set<AnyCancellable>()
    private var watchGeneration = 0
    private var listIdentity: ListIdentity?
    private var lastPublication: CarPlayNowPlayingPublication?
    private let bridge = CarPlayNowPlayingBridge()

    private var isConnected: Bool { interfaceController != nil }

    private init() {}

    func didConnect() async {
        guard let controller = Self.handedController else { return }
        Self.handedController = nil
        let generation = watchGeneration
        await AppRuntime.startIfNeeded()
        // A disconnect during startup bumped the generation. Leave the car UI down.
        guard watchGeneration == generation else { return }
        interfaceController = controller
        MPRemoteCommandCenter.shared().previousTrackCommand.isEnabled = CarPlayTransport.previousTrackEnabled
        CPNowPlayingTemplate.shared.isAlbumArtistButtonEnabled = false
        watchPlayback()
        watchRecipes()
        render()
    }

    func didDisconnect() {
        watchGeneration += 1
        watchers.removeAll()
        interfaceController = nil
        listTemplate = nil
        listIdentity = nil
        lastPublication = nil
        bridge.cancel()
    }

    private func watchPlayback() {
        let music = AppRuntime.dependencies.playback
        music.$snapshot.sink { _ in
            Task { @MainActor in CarPlaySession.shared.render() }
        }.store(in: &watchers)
        music.$authState.sink { _ in
            Task { @MainActor in CarPlaySession.shared.render() }
        }.store(in: &watchers)
    }

    private func watchRecipes() {
        watchGeneration += 1
        let generation = watchGeneration
        let library = AppRuntime.dependencies.studio.recipes
        withObservationTracking {
            _ = library.recipes
        } onChange: {
            Task { @MainActor in
                guard CarPlaySession.shared.watchGeneration == generation,
                      CarPlaySession.shared.isConnected else { return }
                CarPlaySession.shared.render()
                CarPlaySession.shared.watchRecipes()
            }
        }
    }

    private func render() {
        guard isConnected else { return }
        let model = projected()
        updateList(model)
        if let publication = model.publication, publication != lastPublication {
            lastPublication = publication
            bridge.apply(publication.fields)
        }
    }

    private func projected() -> CarPlayScreenModel {
        let dependencies = AppRuntime.dependencies
        let music = dependencies.playback
        let created = CreatedStations.entries(from: dependencies.studio.recipes.recipes)
        return CarPlayScreen.project(created: created, snapshot: music.snapshot,
                                     opened: opened, access: access(music.authState))
    }

    fileprivate func pick(_ row: CarPlayStationRow) async {
        opened = StationRef(id: row.id, name: row.name)
        let dependencies = AppRuntime.dependencies
        let music = dependencies.playback
        switch CarPlayScreen.effect(for: row.pick) {
        case .openCreatedStation(let id):
            if let queue = dependencies.stationQueue {
                _ = await queue.openCreatedStation(.userTap, recipeID: id, studio: dependencies.studio)
            } else {
                await music.authorize()
                _ = await dependencies.studio.applyRecipe(id)
            }
        }
        render()
        showNowPlaying()
    }

    private func showNowPlaying() {
        guard let interfaceController else { return }
        let nowPlaying = CPNowPlayingTemplate.shared
        if interfaceController.topTemplate === nowPlaying { return }
        interfaceController.pushTemplate(nowPlaying, animated: true, completion: nil)
    }

    private func updateList(_ model: CarPlayScreenModel) {
        guard let interfaceController else { return }
        let identity = ListIdentity(ids: model.rows.map(\.id), names: model.rows.map(\.name),
                                    notice: model.accessNotice, hasNowPlaying: model.nowPlaying != nil)
        guard identity != listIdentity || listTemplate == nil else { return }
        listIdentity = identity

        var sections: [CPListSection] = []
        let reportedLimit = CPListTemplate.maximumItemCount
        var budget = reportedLimit > 0 ? reportedLimit : model.rows.count + 1
        if let notice = model.accessNotice, budget > 0 {
            let item = CPListItem(text: notice, detailText: nil)
            item.handler = { _, done in
                done()
                Task { @MainActor in
                    await AppRuntime.dependencies.playback.authorize()
                }
            }
            sections.append(CPListSection(items: [item]))
            budget -= 1
        }
        let rows = budget > 0 ? Array(model.rows.prefix(budget)) : []
        if rows.isEmpty, let message = model.emptyMessage, budget > 0 {
            let item = CPListItem(text: message, detailText: nil)
            item.handler = { _, done in done() }
            sections.append(CPListSection(items: [item]))
        } else if !rows.isEmpty {
            let items = rows.map { row in
                let item = CPListItem(text: row.name, detailText: nil)
                item.handler = { _, done in
                    done()
                    let picked = row
                    Task { @MainActor in
                        await CarPlaySession.shared.pick(picked)
                    }
                }
                return item
            }
            sections.append(CPListSection(items: items))
        }

        let nowPlayingButton = CPBarButton(title: "Now Playing") { _ in
            Task { @MainActor in
                CarPlaySession.shared.showNowPlaying()
            }
        }
        if let listTemplate {
            listTemplate.updateSections(sections)
            listTemplate.trailingNavigationBarButtons = model.nowPlaying == nil ? [] : [nowPlayingButton]
        } else {
            let list = CPListTemplate(title: "Stations", sections: sections)
            list.trailingNavigationBarButtons = model.nowPlaying == nil ? [] : [nowPlayingButton]
            self.listTemplate = list
            interfaceController.setRootTemplate(list, animated: true, completion: nil)
        }
    }

    private func access(_ state: MusicKitService.AuthState) -> PlaybackAccess {
        switch state {
        case .unknown: .checking
        case .notDetermined: .needsAuthorization
        case .authorized: .authorized
        case .denied: .denied
        case .notSubscribed: .subscriptionRequired
        }
    }
}

private struct ListIdentity: Equatable {
    let ids: [String]
    let names: [String]
    let notice: String?
    let hasNowPlaying: Bool
}
