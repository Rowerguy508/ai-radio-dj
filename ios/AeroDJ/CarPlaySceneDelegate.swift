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

/// The car UI. Station rows and now playing come from `CarPlayScreen`. A created
/// station starts through `openCreatedStation(.userTap)`, a built-in one through
/// `openBuiltInStation(.userTap)` (#454: the same start path). Next and previous are not handled here.
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
    private var listIdentity: CarPlayListIdentity?
    private var lastPublication: CarPlayNowPlayingPublication?
    private let bridge = CarPlayNowPlayingBridge()
    /// #438: only the latest pick may push Now Playing or show a start notice.
    private var picks = CarPlayPickTracker()
    /// #438: the start notice on screen, if any.
    private var startNotice: CPAlertTemplate?

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
        startNotice = nil
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
        let step = CarPlayPublicationStep.next(from: lastPublication, to: model.publication)
        lastPublication = model.publication
        switch step {
        case .keep:
            break
        case .apply(let fields):
            bridge.apply(fields)
        case .withdraw:
            // #449: the song is gone. A fetch still running for it must not set an image later.
            bridge.cancel()
        }
    }

    private func projected() -> CarPlayScreenModel {
        let dependencies = AppRuntime.dependencies
        let music = dependencies.playback
        let builtIn = Station.defaultStations.map {
            CarPlayBuiltInStation(id: $0.id.uuidString, name: $0.name, detail: $0.description)
        }
        let created = CreatedStations.entries(from: dependencies.studio.recipes.recipes)
        return CarPlayScreen.project(builtIn: builtIn, created: created, snapshot: music.snapshot,
                                     opened: opened, access: access(music.authState))
    }

    fileprivate func pick(_ row: CarPlayStationRow) async {
        let pick = picks.begin()
        dismissStartNotice()
        opened = StationRef(id: row.id, name: row.name)
        let dependencies = AppRuntime.dependencies
        let music = dependencies.playback
        var outcome: CreatedStationOpenOutcome?
        switch CarPlayScreen.effect(for: row.pick, transport: music.snapshot.transport) {
        case .openCreatedStation(let id):
            if let queue = dependencies.stationQueue {
                outcome = await queue.openCreatedStation(.userTap, recipeID: id, studio: dependencies.studio)
            } else {
                await music.authorize()
                _ = await dependencies.studio.applyRecipe(id)
            }
        case .openBuiltInStation:
            // #454: the phone's built-in tap, the same start path as a created station. It plays
            // the station's own seeds (`BuiltInStations`, #442), a re-tap on the paused active station resumes it (Fry N4).
            if let queue = dependencies.stationQueue, let id = UUID(uuidString: row.id) {
                outcome = await queue.openBuiltInStation(.userTap, stationID: id, studio: dependencies.studio)
            } else {
                await music.authorize()
            }
        }
        render()
        // #438: a start that failed says so on the car (fixed copy plus the row's name) instead of
        // pushing an empty Now Playing. A pick a newer one replaced does nothing.
        switch picks.finish(pick, outcome: outcome, stationName: row.name, access: access(music.authState)) {
        case .stale:
            break
        case .showNowPlaying:
            showNowPlaying()
        case .notice(let notice):
            showStartNotice(notice, retrying: row)
        }
    }

    /// #438: a CarPlay alert with the fixed start-failure copy. Try Again re-runs the same pick.
    private func showStartNotice(_ notice: CarPlayStartNotice, retrying row: CarPlayStationRow) {
        guard let interfaceController else { return }
        dismissStartNotice()
        var actions: [CPAlertAction] = []
        if notice.offersRetry {
            actions.append(CPAlertAction(title: CarPlayStartNotice.retryTitle, style: .default) { _ in
                let picked = row
                Task { @MainActor in
                    await CarPlaySession.shared.pick(picked)
                }
            })
        }
        actions.append(CPAlertAction(title: CarPlayStartNotice.dismissTitle, style: .cancel) { _ in
            Task { @MainActor in
                CarPlaySession.shared.dismissStartNotice()
            }
        })
        let alert = CPAlertTemplate(titleVariants: notice.titleVariants, actions: actions)
        startNotice = alert
        interfaceController.presentTemplate(alert, animated: true, completion: nil)
    }

    /// Takes down the start notice if it is still the one presented.
    private func dismissStartNotice() {
        guard let alert = startNotice else { return }
        startNotice = nil
        guard let interfaceController, interfaceController.presentedTemplate === alert else { return }
        interfaceController.dismissTemplate(animated: false, completion: nil)
    }

    private func showNowPlaying() {
        guard let interfaceController else { return }
        let nowPlaying = CPNowPlayingTemplate.shared
        if interfaceController.topTemplate === nowPlaying { return }
        interfaceController.pushTemplate(nowPlaying, animated: true, completion: nil)
    }

    private func updateList(_ model: CarPlayScreenModel) {
        guard let interfaceController else { return }
        let identity = CarPlayListIdentity(model)
        guard identity != listIdentity || listTemplate == nil else { return }
        listIdentity = identity

        var sections: [CPListSection] = []
        let reportedLimit = CPListTemplate.maximumItemCount
        var budget = reportedLimit > 0 ? reportedLimit : model.rows.count + model.sections.count + 1
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
        for section in model.sections {
            var items: [CPListItem] = []
            if let hint = section.hint, budget > 0 {
                let item = CPListItem(text: hint, detailText: nil, image: UIImage(systemName: "plus"))
                item.handler = { _, done in done() }
                items.append(item)
                budget -= 1
            }
            for row in section.rows where budget > 0 {
                items.append(listItem(row))
                budget -= 1
            }
            guard !items.isEmpty else { continue }
            sections.append(CPListSection(items: items, header: section.title, sectionIndexTitle: nil))
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

    private func listItem(_ row: CarPlayStationRow) -> CPListItem {
        let item = CPListItem(text: row.name, detailText: row.detail, image: UIImage(systemName: row.symbol.rawValue))
        item.isPlaying = row.showsPlayingIndicator
        item.playingIndicatorLocation = .trailing
        item.handler = { _, done in
            done()
            let picked = row
            Task { @MainActor in
                await CarPlaySession.shared.pick(picked)
            }
        }
        return item
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

