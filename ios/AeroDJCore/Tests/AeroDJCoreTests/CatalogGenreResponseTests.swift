import Foundation
import XCTest
@testable import AeroDJCore

// MusicCatalogSeedSource: GenreProviding (-Atlas): decoding and the contract, on Linux.

final class CatalogGenreResponseTests: XCTestCase {
    private let sample = Data("""
    {"data":[
      {"id":"34","type":"genres","href":"/v1/catalog/us/genres/34","attributes":{"name":"Music","url":"https://music.apple.com/us/genre/34"}},
      {"id":"20","type":"genres","attributes":{"name":"Alternative","parentId":"34","parentName":"Music"}},
      {"id":"14","type":"genres","attributes":{"name":"Pop","parentId":"34","parentName":"Music"}},
      {"id":"20","type":"genres","attributes":{"name":"Alternative (again)","parentId":"34"}},
      {"id":"18","type":"genres","attributes":{"name":" Hip-Hop/Rap ","parentId":"34"}},
      {"id":"x9","type":"genres","attributes":{"name":"Not a catalog id"}},
      {"id":"7","type":"genres","attributes":{"name":"  "}},
      {"id":"11","type":"genres"}
    ]}
    """.utf8)

    func testASampleBodyDecodesInAppleOrderWithoutMusicDuplicatesOrBadRows() throws {
        XCTAssertEqual(try CatalogGenreResponse.genres(from: sample), [
            CatalogGenre(id: "20", name: "Alternative"),
            CatalogGenre(id: "14", name: "Pop"),
            CatalogGenre(id: "18", name: "Hip-Hop/Rap"),
        ])
    }

    func testTheRootMusicGenreIsAlwaysDropped() {
        let out = CatalogGenreResponse.topLevel([.init(id: "34", name: "Music"), .init(id: " 34 ", name: "Music"),
                                                 .init(id: "5", name: "Classical")])
        XCTAssertEqual(out, [.init(id: "5", name: "Classical")])
    }

    func testDuplicatesKeepTheFirstAndTheOrder() {
        let out = CatalogGenreResponse.topLevel([.init(id: "21", name: "Rock"), .init(id: "14", name: "Pop"),
                                                 .init(id: "21", name: "Rock 2"), .init(id: "2", name: "Blues")])
        XCTAssertEqual(out.map(\.id), ["21", "14", "2"])
        XCTAssertEqual(out.first?.name, "Rock")
    }

    func testAnEmptyResponseIsAnEmptyListNotAFailure() throws {
        XCTAssertEqual(try CatalogGenreResponse.genres(from: Data(#"{"data":[]}"#.utf8)), [])
        XCTAssertEqual(try CatalogGenreResponse.genres(from: Data(#"{"data":[{"id":"34","attributes":{"name":"Music"}}]}"#.utf8)), [])
    }

    func testABodyThatIsNotTheGenresShapeThrows() {
        XCTAssertThrowsError(try CatalogGenreResponse.genres(from: Data(#"{"errors":[{"status":"500"}]}"#.utf8)))
        XCTAssertThrowsError(try CatalogGenreResponse.genres(from: Data("not json".utf8)))
    }

    func testFetchReturnsTheContractList() async throws {
        let body = sample
        let out = try await CatalogGenreResponse.fetch { body }
        XCTAssertEqual(out.map(\.id), ["20", "14", "18"])
    }

    func testFetchRethrowsOtherFailures() async {
        struct Offline: Error {}
        do {
            _ = try await CatalogGenreResponse.fetch { throw Offline() }
            XCTFail("expected a throw")
        } catch is Offline {
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testACancelledURLLoadBecomesCancellationError() async {
        do {
            _ = try await CatalogGenreResponse.fetch { throw URLError(.cancelled) }
            XCTFail("expected a throw")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    func testACancelledTaskThrowsCancellationErrorBeforeAndAfterTheRequest() async {
        // Cancelled before the request: the load never runs.
        let before = Task { () -> (Bool, Bool) in
            withUnsafeCurrentTask { $0?.cancel() }
            let ran = LockedFlag()
            do {
                _ = try await CatalogGenreResponse.fetch { ran.set(); return Data(#"{"data":[]}"#.utf8) }
                return (false, ran.value)
            } catch { return (error is CancellationError, ran.value) }
        }
        let (cancelledBefore, loadRan) = await before.value
        XCTAssertTrue(cancelledBefore)
        XCTAssertFalse(loadRan, "no request once cancelled")

        // Cancelled while the request runs: the decoded list is never returned.
        let body = sample
        let during = Task { () -> Bool in
            do {
                _ = try await CatalogGenreResponse.fetch {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return body
                }
                return false
            } catch { return error is CancellationError }
        }
        let cancelledDuring = await during.value
        XCTAssertTrue(cancelledDuring)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
