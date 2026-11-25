import XCTest
@testable import AeroDJCore

/// #449 (-Atlas): the first CarPlay publish after a reconnect or reset reconciles with the
/// now-playing dictionary that is really there, not with what a fresh gate assumes.
///
/// `Car` mirrors `CarPlayNowPlayingBridge` over a fake dictionary: it reads the observation from
/// the dictionary, runs the gate's commands with the same merge, and keeps the image object it
/// wrote across a reset. Everything is synchronous; no clock, no polling.
final class CarPlayArtworkReconcileTests: XCTestCase {
    private let artworkKey = "artwork"
    private let urlA = URL(string: "https://example.com/a.jpg")!
    private let urlB = URL(string: "https://example.com/b.jpg")!

    /// Stands in for `MPMediaItemArtwork`: compared by identity, tagged with its URL for asserts.
    private final class Image {
        let url: URL?
        init(_ url: URL?) { self.url = url }
    }

    private final class Car {
        let artworkKey: String
        var info: [String: Any]
        var gate = CarPlayArtworkGate()
        var written: (artwork: Image, url: URL)?
        var log: [[CarPlayArtworkGate.Command]] = []

        init(artworkKey: String, info: [String: Any]) {
            self.artworkKey = artworkKey
            self.info = info
        }

        var image: Image? { info[artworkKey] as? Image }

        @discardableResult
        func publish(_ fields: CarPlayNowPlaying) -> [CarPlayArtworkGate.Command] {
            let observed = CarPlayArtworkObservation.observe(current: image, written: written?.artwork,
                                                             writtenURL: written?.url)
            let commands = gate.publish(fields, observed: observed)
            log.append(commands)
            for command in commands {
                switch command {
                case .writeText(let text):
                    info = CarPlayNowPlayingMerge.apply(fields: text, to: info)
                case .clearArtwork:
                    written = nil
                    info.removeValue(forKey: artworkKey)
                case .startFetch:
                    break
                }
            }
            return commands
        }

        /// A download finished with an image.
        @discardableResult
        func arrive(_ token: CarPlayArtworkGate.Token) -> CarPlayArtworkGate.Arrival {
            let arrival = gate.fetchArrived(token)
            if case .setArtwork(let url) = arrival {
                let made = Image(url)
                written = (made, url)
                info[artworkKey] = made
            }
            return arrival
        }

        func disconnect() { gate.reset() }
    }

    private func song(_ name: String, _ url: URL?) -> CarPlayNowPlaying {
        CarPlayNowPlaying(title: "Title \(name)", artist: "Artist \(name)", stationName: "Station \(name)", artworkURL: url)
    }

    private func token(_ commands: [CarPlayArtworkGate.Command],
                       file: StaticString = #filePath, line: UInt = #line) -> CarPlayArtworkGate.Token? {
        for command in commands {
            if case .startFetch(let token) = command { return token }
        }
        XCTFail("no fetch in \(commands)", file: file, line: line)
        return nil
    }

    /// Timing and rate the player owns, plus a key the car code never names.
    private let playerFields: [String: Any] = [
        "elapsedPlaybackTime": 61.5, "playbackDuration": 212.0, "playbackRate": 1.0, "mediaType": 1,
    ]

    /// A connected car that published song A and loaded A's image, then disconnected.
    private func carShowingAThenDisconnected() -> Car {
        let car = Car(artworkKey: artworkKey, info: playerFields)
        guard let tokenA = token(car.publish(song("A", urlA))) else { return car }
        XCTAssertEqual(car.arrive(tokenA), .setArtwork(urlA))
        XCTAssertTrue(car.image?.url == urlA)
        car.disconnect()
        return car
    }

    private func assertTextIsB(_ car: Car, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(car.info[CarPlayNowPlayingMerge.titleKey] as? String, "Title B", file: file, line: line)
        XCTAssertEqual(car.info[CarPlayNowPlayingMerge.artistKey] as? String, "Artist B", file: file, line: line)
        XCTAssertEqual(car.info[CarPlayNowPlayingMerge.stationNameKey] as? String, "Station B", file: file, line: line)
        XCTAssertEqual(car.info["elapsedPlaybackTime"] as? Double, 61.5, file: file, line: line)
        XCTAssertEqual(car.info["playbackDuration"] as? Double, 212.0, file: file, line: line)
        XCTAssertEqual(car.info["playbackRate"] as? Double, 1.0, file: file, line: line)
        XCTAssertEqual(car.info["mediaType"] as? Int, 1, file: file, line: line)
    }

    // MARK: - A -> B after a reconnect, with A's image still in the dictionary

    func testReconnectThenASongWithNoArtworkClearsTheOldImage() {
        let car = carShowingAThenDisconnected()
        let b = song("B", nil)
        XCTAssertEqual(car.publish(b), [.writeText(b), .clearArtwork])
        XCTAssertNil(car.image, "B must not show A's image")
        assertTextIsB(car)
    }

    func testReconnectThenADifferentURLClearsBeforeBLoads() {
        let car = carShowingAThenDisconnected()
        let b = song("B", urlB)
        let commands = car.publish(b)
        XCTAssertEqual(Array(commands.prefix(2)), [.writeText(b), .clearArtwork])
        XCTAssertNil(car.image, "nothing shows while B loads, not A's image")
        assertTextIsB(car)
        guard let tokenB = token(commands) else { return }
        XCTAssertEqual(tokenB.url, urlB)
        XCTAssertEqual(car.arrive(tokenB), .setArtwork(urlB))
        XCTAssertTrue(car.image?.url == urlB)
        assertTextIsB(car)
    }

    func testReconnectThenAFailedDownloadLeavesNoOldImage() {
        let car = carShowingAThenDisconnected()
        guard let tokenB = token(car.publish(song("B", urlB))) else { return }
        car.gate.fetchFailed(tokenB)
        XCTAssertNil(car.image, "a failed B download must not leave A's image up indefinitely")
        assertTextIsB(car)
        // The same URL may try again on the next publish.
        let again = song("B", urlB)
        XCTAssertEqual(token(car.publish(again))?.url, urlB)
    }

    func testAFetchStartedBeforeTheDisconnectCannotSetAnImageAfterIt() {
        let car = Car(artworkKey: artworkKey, info: playerFields)
        guard let oldA = token(car.publish(song("A", urlA))) else { return }
        car.disconnect()
        // B shares A's artwork URL (same album). Its fetch is a new one.
        guard let newB = token(car.publish(song("B", urlA))) else { return }
        XCTAssertNotEqual(oldA, newB, "a token from before the reset must never equal one after it")
        XCTAssertEqual(car.arrive(oldA), .ignore)
        XCTAssertNil(car.image)
        XCTAssertEqual(car.arrive(newB), .setArtwork(urlA))
        assertTextIsB(car)
    }

    func testAFetchStartedBeforeTheDisconnectIsIgnoredWhenBHasNoArtwork() {
        let car = Car(artworkKey: artworkKey, info: playerFields)
        guard let oldA = token(car.publish(song("A", urlA))) else { return }
        car.disconnect()
        car.publish(song("B", nil))
        XCTAssertEqual(car.arrive(oldA), .ignore)
        XCTAssertNil(car.image)
        assertTextIsB(car)
    }

    func testKnownMatchingArtworkIsKeptWithoutAReload() {
        let car = carShowingAThenDisconnected()
        let shown = car.image
        let b = song("B", urlA)
        XCTAssertEqual(car.publish(b), [.writeText(b)], "the image this bridge wrote for this URL stays")
        XCTAssertTrue(car.image === shown)
        assertTextIsB(car)
    }

    func testAnImageTheBridgeDidNotWriteIsClearedEvenForTheSameURL() {
        let car = carShowingAThenDisconnected()
        let foreign = Image(urlA)
        car.info[artworkKey] = foreign
        let b = song("B", urlA)
        let commands = car.publish(b)
        XCTAssertEqual(Array(commands.prefix(2)), [.writeText(b), .clearArtwork])
        XCTAssertNil(car.image)
        XCTAssertEqual(token(commands)?.url, urlA)
    }

    func testAPrepopulatedDictionaryOnFirstConnectIsReconciledToo() {
        var info = playerFields
        info[artworkKey] = Image(urlA)
        info[CarPlayNowPlayingMerge.titleKey] = "Title A"
        let car = Car(artworkKey: artworkKey, info: info)
        let b = song("B", nil)
        XCTAssertEqual(car.publish(b), [.writeText(b), .clearArtwork])
        XCTAssertNil(car.image)
        assertTextIsB(car)
    }

    func testAnEmptyDictionaryAfterReconnectLoadsTheImage() {
        let car = carShowingAThenDisconnected()
        car.info.removeValue(forKey: artworkKey)
        let b = song("B", urlA)
        let commands = car.publish(b)
        XCTAssertEqual(commands.first, .writeText(b))
        XCTAssertFalse(commands.contains(.clearArtwork), "nothing to clear")
        XCTAssertEqual(token(commands)?.url, urlA, "the image the gate thought was there is gone, so load it")
    }

    func testOnlyTheFirstPublishAfterAResetReconciles() {
        let car = carShowingAThenDisconnected()
        let b = song("B", urlA)
        XCTAssertEqual(car.publish(b), [.writeText(b)])
        // A later publish (a transport change, the same song) follows the gate: no clear, no reload.
        let shown = car.image
        let again = song("B", urlA)
        XCTAssertEqual(car.publish(again), [.writeText(again)])
        XCTAssertTrue(car.image === shown)
    }

    // MARK: - No publication: the song disappeared

    func testPublicationStep() {
        let p = CarPlayNowPlayingPublication(fields: song("A", urlA), transport: .playing)
        let q = CarPlayNowPlayingPublication(fields: song("B", urlB), transport: .playing)
        XCTAssertEqual(CarPlayPublicationStep.next(from: nil, to: nil), .keep)
        XCTAssertEqual(CarPlayPublicationStep.next(from: nil, to: p), .apply(p.fields))
        XCTAssertEqual(CarPlayPublicationStep.next(from: p, to: p), .keep)
        XCTAssertEqual(CarPlayPublicationStep.next(from: p, to: q), .apply(q.fields))
        XCTAssertEqual(CarPlayPublicationStep.next(from: p, to: nil), .withdraw)
    }

    func testALateImageForASongThatDisappearedIsIgnored() {
        let car = Car(artworkKey: artworkKey, info: playerFields)
        let a = CarPlayNowPlayingPublication(fields: song("A", urlA), transport: .playing)
        guard case .apply(let fields) = CarPlayPublicationStep.next(from: nil, to: a),
              let tokenA = token(car.publish(fields)) else { return XCTFail("A was not applied") }
        XCTAssertEqual(CarPlayPublicationStep.next(from: a, to: nil), .withdraw)
        car.gate.reset()
        XCTAssertEqual(car.arrive(tokenA), .ignore)
        XCTAssertNil(car.image)
    }

    // MARK: - Observation

    func testObservationComparesTheImageObjectNotItsURL() {
        let mine = Image(urlA)
        XCTAssertEqual(CarPlayArtworkObservation.observe(current: nil, written: mine, writtenURL: urlA), .none)
        XCTAssertEqual(CarPlayArtworkObservation.observe(current: mine, written: mine, writtenURL: urlA), .written(urlA))
        XCTAssertEqual(CarPlayArtworkObservation.observe(current: Image(urlA), written: mine, writtenURL: urlA), .unknown)
        XCTAssertEqual(CarPlayArtworkObservation.observe(current: mine, written: nil, writtenURL: nil), .unknown)
    }

    // MARK: - App adapters (no iOS SDK on Linux: pinned by source)

    func testBridgeAndSceneUseTheReconcilePath() throws {
        let bridge = try code("AeroDJ/CarPlayNowPlayingBridge.swift")
        XCTAssertTrue(bridge.contains("gate.publish(fields, observed: observed)"))
        XCTAssertTrue(bridge.contains("CarPlayArtworkObservation.observe(current: current, written: written?.artwork"))
        XCTAssertTrue(bridge.contains("gate.reset()"))
        let lines = bridge.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertFalse(lines.contains("gate = CarPlayArtworkGate()"), "a new gate restarts token ids")
        XCTAssertTrue(bridge.contains("self.written = (artwork, token.url)"))
        XCTAssertTrue(bridge.contains("written = nil"))
        XCTAssertFalse(bridge.contains("async throws -> Data = {"), "no async closure as a default argument")
        let scene = try code("AeroDJ/CarPlaySceneDelegate.swift")
        XCTAssertTrue(scene.contains("CarPlayPublicationStep.next(from: lastPublication, to: model.publication)"))
        XCTAssertTrue(scene.contains("case .withdraw:\n            bridge.cancel()"))
    }

    private func code(_ relative: String) throws -> String {
        let ios = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: ios.appendingPathComponent(relative), encoding: .utf8)
        return source.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
