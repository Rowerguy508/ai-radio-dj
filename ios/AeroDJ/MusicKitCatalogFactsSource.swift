import Foundation
@preconcurrency import MusicKit
import AeroDJCore

/// #199 (-Fry): Apple Music catalog facts for DJ commentary, read with MusicKit only. No other
/// provider, service or model. Separate from `MusicKitService` (Claude's file) on purpose.
///
/// What it reads, per catalog song: `albumTitle`, `releaseDate`, `genreNames`,
/// `editorialNotes.short`, and the first artist's `editorialNotes.short` (the `.artists`
/// relationship). `CatalogTrackFacts` validates every value; the DJ speaks only what survives,
/// through `CatalogFactLine.templates`.
///
/// Privacy: only `.catalog` song ids reach this actor (`CatalogFactsFetch` filters), so a library
/// id or name is never put in a catalog request (Fry's rule (d)). Nothing is logged: no id, no
/// title, no fact.
///
/// Degrades to no facts: not authorized, offline, a failed or cancelled request, or a song the
/// catalog has no data for. A failed lookup is not cached, so a later queue may try again.
actor MusicKitCatalogFactsSource: CatalogTrackFactsSource {
    /// Looked-up songs: facts, or nil when the catalog had none.
    private var cache: [String: CatalogTrackFacts?] = [:]
    private static let maxCached = 2000
    /// Ids per catalog request.
    private static let batch = 50

    func facts(forCatalogSongIDs ids: [String]) async -> [String: CatalogTrackFacts] {
        guard MusicAuthorization.currentStatus == .authorized else { return [:] }
        let missing = Array(Set(ids.filter { cache[$0] == nil }))
        var start = 0
        while start < missing.count, !Task.isCancelled {
            let chunk = Array(missing[start..<min(start + Self.batch, missing.count)])
            start += Self.batch
            var request = MusicCatalogResourceRequest<Song>(matching: \.id, memberOf: chunk.map { MusicItemID($0) })
            request.properties = [.artists]
            guard let response = try? await request.response() else { break }
            let now = Date()
            for song in response.items {
                let facts = CatalogTrackFacts(catalogSongID: song.id.rawValue, songTitle: song.title,
                                              albumTitle: song.albumTitle, releaseDate: song.releaseDate,
                                              genreNames: song.genreNames,
                                              songEditorialNote: song.editorialNotes?.short,
                                              artistEditorialNote: song.artists?.first?.editorialNotes?.short,
                                              now: now)
                cache[song.id.rawValue] = .some(facts.isEmpty ? nil : facts)
            }
            // Answered, but no item: the catalog has nothing for that id.
            for id in chunk where cache[id] == nil { cache[id] = .some(nil) }
        }
        if cache.count > Self.maxCached { cache.removeAll(keepingCapacity: true) }
        var out: [String: CatalogTrackFacts] = [:]
        for id in ids { if case .some(.some(let facts)) = cache[id] { out[id] = facts } }
        return out
    }
}
