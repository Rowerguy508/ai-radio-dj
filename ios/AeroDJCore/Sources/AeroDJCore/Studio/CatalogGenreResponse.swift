import Foundation

// Apple Music catalog genres (-Atlas): the pure half of `MusicCatalogSeedSource: GenreProviding`.
// The app fetches `/v1/catalog/{storefront}/genres` with `MusicDataRequest` (storefront from
// `MusicDataRequest.currentCountryCode`) and hands the body here. Decoding, filtering and
// cancellation live in core so they are tested on Linux. Nothing here logs a name or an ID.

public enum CatalogGenreResponse {
    /// The JSON:API shape of the genres endpoint: `{"data":[{"id":"14","type":"genres",
    /// "attributes":{"name":"Pop","parentId":"34",…}},…]}`. Unknown fields are ignored; a row
    /// without a name decodes and is dropped by `topLevel`.
    struct Body: Decodable {
        struct Row: Decodable {
            struct Attributes: Decodable { let name: String? }
            let id: String
            let attributes: Attributes?
        }
        let data: [Row]
    }

    /// The storefront's top-level genres from a response body, in Apple's order. Throws a
    /// `DecodingError` for a body that is not the genres shape (never a partial list).
    public static func genres(from data: Data) throws -> [CatalogGenre] {
        let body = try JSONDecoder().decode(Body.self, from: data)
        return topLevel(body.data.map { CatalogGenre(id: $0.id, name: $0.attributes?.name ?? "") })
    }

    /// The `GenreProviding` contract: valid catalog IDs (ASCII digits) only, the root "Music"
    /// genre (34) dropped, blank names dropped, de-duplicated by ID (first wins), order kept.
    public static func topLevel(_ genres: [CatalogGenre]) -> [CatalogGenre] {
        var seen = Set<String>()
        return genres.compactMap { genre in
            let id = genre.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = genre.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard StationSeed.isValidCatalogGenreID(id), id != GenrePicker.rootGenreID, !name.isEmpty,
                  seen.insert(id).inserted else { return nil }
            return CatalogGenre(id: id, name: name)
        }
    }

    /// Fry's rule (#214): Apple Music access is never requested by a genre fetch, and nothing
    /// MusicKit runs without it. `isAuthorized` reads the current status only (the app passes
    /// `MusicAuthorization.currentStatus == .authorized`, never `request()`); when it is false
    /// this throws `notAuthorized()` (the app's `MusicKitError.notAuthorized`, so the picker shows
    /// the existing not-authorized copy and Try again) and `load` (storefront lookup, cache and
    /// request) never runs. A relaunch that reopens Tune therefore never touches Apple Music.
    public static func whenAuthorized(_ isAuthorized: @Sendable () -> Bool,
                                      notAuthorized: @Sendable () -> any Error,
                                      load: @Sendable () async throws -> [CatalogGenre]) async throws -> [CatalogGenre] {
        try Task.checkCancellation()
        guard isAuthorized() else { throw notAuthorized() }
        return try await load()
    }

    /// Runs one fetch under the contract's cancellation rule: checks before and after the
    /// request, and maps a cancelled URL load (`URLError.cancelled`) to `CancellationError`.
    /// Any other failure is rethrown as is (the picker maps it to fixed copy).
    public static func fetch(_ load: @Sendable () async throws -> Data) async throws -> [CatalogGenre] {
        try Task.checkCancellation()
        let data: Data
        do {
            data = try await load()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
        try Task.checkCancellation()
        return try genres(from: data)
    }
}
