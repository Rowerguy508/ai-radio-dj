import Foundation
import MusicKit
import AeroDJCore

/// MusicKit adapter for station seeds (-Atlas). Implements the AeroDJCore engine's
/// `StationSeedCatalog` (songs per seed and reach tier) and `StarterStationSource`
/// (suggested stations), and seed search for the station wizard. It never plays, queues,
/// saves or logs anything. It is separate from `MusicKitService` (Claude's file) on purpose.
///
/// Per kind and tier (`.catalog` seeds):
///   artist:   core = top songs;  related = similar artists' top songs;  broad = charts of the artist's genres.
///   song:     core = the song;   related = its artist's and similar artists' top songs;  broad = charts of its genres.
///   playlist: core = its tracks; related = similar artists of its main artists;  broad = charts of its songs' genres.
///   genre:    core = the genre's most-played songs chart;  related = its top chart playlists;  broad = more chart playlists.
///
/// Privacy (Fry's rule (d)): `.library` seeds are read with `MusicLibraryRequest` only, on the
/// device; their IDs and names are never sent in a catalog request. The engine never calls
/// `relatedSongs` or `broadSongs` for them. Nothing here logs a seed, a name or an ID.
///
/// Playing a pool: `tracks(for:)` returns the `Track`s for a built list, for the queue hook
/// (see the PR: queueing them live is a `MusicKitService` dependency for Claude).
actor MusicCatalogSeedSource: StationSeedCatalog, StarterStationSource, StationSeedSearching {
    /// Songs returned by the last lookups, so a built list can become playable `Track`s.
    private var songsByID: [String: Song] = [:]
    /// Where each cached song came from (Sentinel): `MusicLibraryRequest` lookups are `.library`,
    /// catalog lookups `.catalog`; library wins if an id was seen both ways. Read by `tracks(for:)`
    /// so the DJ never names a library song in an off-device voice.
    private var originsByID: [String: TrackOrigin] = [:]
    private static let maxCachedSongs = 2000

    // MARK: Seed search (station wizard)

    /// Artists, genres, playlists and songs matching `term`, as catalog seeds with display-only
    /// subtitles (a song's artist, a playlist's curator) and artwork. A blank term returns `[]`
    /// without a request; a cancelled search throws `CancellationError` and returns nothing
    /// partial (`StationSeedSearch.run`). Subtitles and artwork are never logged.
    func searchSeeds(_ term: String, limit: Int = 10, artworkSize: Int = 120) async throws -> [StationSeedSearchResult] {
        try await StationSeedSearch.run(term: term, limit: limit) { query, limit in
            var request = MusicCatalogSearchRequest(term: query, types: [Artist.self, Playlist.self, Song.self])
            request.limit = limit
            let response = try await request.response()
            try Task.checkCancellation()
            let artists = response.artists.map {
                StationSeedSearchResult(seed: StationSeed(kind: .artist, catalogID: $0.id.rawValue, name: $0.name),
                                        artworkURL: $0.artwork?.url(width: artworkSize, height: artworkSize))
            }
            let playlists = response.playlists.map {
                StationSeedSearchResult(seed: StationSeed(kind: .playlist, catalogID: $0.id.rawValue, name: $0.name),
                                        subtitle: $0.curatorName,
                                        artworkURL: $0.artwork?.url(width: artworkSize, height: artworkSize))
            }
            let songs = response.songs.map {
                StationSeedSearchResult(seed: StationSeed(kind: .song, catalogID: $0.id.rawValue, name: $0.title),
                                        subtitle: $0.artistName,
                                        artworkURL: $0.artwork?.url(width: artworkSize, height: artworkSize))
            }
            // Genres are not a catalog search type; match the storefront's genre list instead.
            // A failed genre lookup only drops genres; a cancellation cancels the whole search.
            let genres: [StationSeedSearchResult]
            do {
                genres = try await self.genreSeeds(matching: query)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                genres = []
            }
            return artists + Array(genres.prefix(limit)) + playlists + songs
        }
    }

    /// Add-station search (`StationSeedSearching`): catalog rows of `kinds` only (`.artist`,
    /// `.playlist`, `.song`; genres come from `genreSeeds(matching:)`). Same blank-term and
    /// cancellation rules as `searchSeeds(_:limit:artworkSize:)`. Nothing is logged.
    func searchSeeds(_ term: String, kinds: Set<StationSeedKind>, limit: Int) async throws -> [StationSeedSearchResult] {
        var types: [any MusicCatalogSearchable.Type] = []
        if kinds.contains(.artist) { types.append(Artist.self) }
        if kinds.contains(.playlist) { types.append(Playlist.self) }
        if kinds.contains(.song) { types.append(Song.self) }
        guard !types.isEmpty else { return [] }
        let artworkSize = 120
        return try await StationSeedSearch.run(term: term, limit: limit) { query, limit in
            var request = MusicCatalogSearchRequest(term: query, types: types)
            request.limit = limit
            let response = try await request.response()
            try Task.checkCancellation()
            let artists = response.artists.map {
                StationSeedSearchResult(seed: StationSeed(kind: .artist, catalogID: $0.id.rawValue, name: $0.name),
                                        artworkURL: $0.artwork?.url(width: artworkSize, height: artworkSize))
            }
            let playlists = response.playlists.map {
                StationSeedSearchResult(seed: StationSeed(kind: .playlist, catalogID: $0.id.rawValue, name: $0.name),
                                        subtitle: $0.curatorName,
                                        artworkURL: $0.artwork?.url(width: artworkSize, height: artworkSize))
            }
            let songs = response.songs.map {
                StationSeedSearchResult(seed: StationSeed(kind: .song, catalogID: $0.id.rawValue, name: $0.title),
                                        subtitle: $0.artistName,
                                        artworkURL: $0.artwork?.url(width: artworkSize, height: artworkSize))
            }
            return artists + playlists + songs
        }
    }

    /// The listener's library playlists as `.library` seeds, read on the device with
    /// `MusicLibraryRequest` only. Private: their names and IDs are never sent in a catalog
    /// request, logged, or put in diagnostics (Fry's rule (d)).
    func libraryPlaylistSeeds(limit: Int) async throws -> [StationSeedSearchResult] {
        try Task.checkCancellation()
        var request = MusicLibraryRequest<Playlist>()
        request.limit = StationCreationModel.clampedLibraryLimit(limit)
        let items = try await request.response().items
        try Task.checkCancellation()
        return items.map {
            StationSeedSearchResult(seed: StationSeed(kind: .playlist, catalogID: $0.id.rawValue, name: $0.name, source: .library),
                                    artworkURL: $0.artwork?.url(width: 120, height: 120))
        }
    }

    /// The storefront's top-level genres, optionally filtered by name. Genres have no artwork.
    func genreSeeds(matching query: String = "") async throws -> [StationSeedSearchResult] {
        try Task.checkCancellation()
        let genres = try await catalogGenres(path: "genres")
        try Task.checkCancellation()
        let q = StationSeedSearch.normalizedTerm(query)
        return genres
            .filter { q == nil || $0.name.localizedCaseInsensitiveContains(q ?? "") }
            .map { StationSeedSearchResult(seed: StationSeed(kind: .genre, catalogID: $0.id.rawValue, name: $0.name)) }
    }

    /// Playable tracks for a built station list, in order. Songs not looked up here are skipped.
    func tracks(for candidates: [StationCandidate]) -> [Track] {
        candidates.compactMap { c in songsByID[c.id].map { Track(song: $0, origin: originsByID[c.id] ?? .unknown) } }
    }

    // MARK: StationSeedCatalog

    func coreSongs(for seed: StationSeed, limit: Int) async throws -> [StationCandidate] {
        switch (seed.source, seed.kind) {
        case (.catalog, .artist):
            return remember(try await artist(seed.catalogID)?.topSongs, limit: limit, origin: .catalog)
        case (.catalog, .song):
            return remember(try await catalogSong(seed.catalogID).map { [$0] }, limit: limit, origin: .catalog)
        case (.catalog, .playlist):
            return remember(Self.songs(in: try await catalogPlaylist(seed.catalogID)?.tracks), limit: limit, origin: .catalog)
        case (.catalog, .genre):
            return remember(try await chartSongs(genreID: seed.catalogID, limit: limit), limit: limit, origin: .catalog)
        case (.library, .playlist):
            return remember(try await libraryPlaylistSongs(seed.catalogID), limit: limit, origin: .library)
        case (.library, .song):
            return remember(try await librarySong(seed.catalogID).map { [$0] }, limit: limit, origin: .library)
        case (.library, .artist):
            return remember(try await librarySongs(byArtistNamed: seed.name), limit: limit, origin: .library)
        case (.library, .genre):
            return []
        }
    }

    func relatedSongs(for seed: StationSeed, limit: Int) async throws -> [StationCandidate] {
        guard seed.source == .catalog else { return [] }
        switch seed.kind {
        case .artist:
            let similar = Array(try await artist(seed.catalogID)?.similarArtists ?? [])
            return remember(try await topSongs(of: similar, limit: limit), limit: limit, origin: .catalog)
        case .song:
            guard let song = try await catalogSong(seed.catalogID),
                  let first = song.artists?.first, let main = try await artist(first.id.rawValue) else { return [] }
            let own = Array(main.topSongs ?? []).filter { $0.id != song.id }
            let similar = try await topSongs(of: Array(main.similarArtists ?? []), limit: limit)
            return remember(Self.alternate(own, similar), limit: limit, origin: .catalog)
        case .playlist:
            let mains = try await mainArtists(ofPlaylist: seed.catalogID)
            var similar: [Artist] = []
            for a in mains {
                if let detail = try await artist(a.id.rawValue) { similar += Array(detail.similarArtists ?? []).prefix(2) }
            }
            return remember(try await topSongs(of: similar, limit: limit), limit: limit, origin: .catalog)
        case .genre:
            return remember(try await chartPlaylistSongs(genreID: seed.catalogID, playlists: 0..<2, limit: limit), limit: limit, origin: .catalog)
        }
    }

    func broadSongs(for seed: StationSeed, limit: Int) async throws -> [StationCandidate] {
        guard seed.source == .catalog else { return [] }
        let genreIDs: [String]
        switch seed.kind {
        case .artist:
            genreIDs = Array(try await artist(seed.catalogID)?.genres ?? []).map(\.id.rawValue)
        case .song:
            genreIDs = Array(try await catalogSong(seed.catalogID)?.genres ?? []).map(\.id.rawValue)
        case .playlist:
            genreIDs = try await genres(ofPlaylist: seed.catalogID)
        case .genre:
            return remember(try await chartPlaylistSongs(genreID: seed.catalogID, playlists: 2..<5, limit: limit), limit: limit, origin: .catalog)
        }
        var songs: [Song] = []
        for id in Self.unique(genreIDs).prefix(2) {
            songs += try await chartSongs(genreID: id, limit: limit)
        }
        return remember(songs, limit: limit, origin: .catalog)
    }

    // MARK: StarterStationSource

    /// Most-played library artists, from on-device library play counts. Library seeds.
    func libraryTopArtists(limit: Int) async throws -> [StationSeed] {
        var songs = MusicLibraryRequest<Song>()
        songs.limit = 500
        var plays: [String: Int] = [:]
        for song in try await songs.response().items {
            plays[song.artistName, default: 0] += song.playCount ?? 0
        }
        let ranked = plays.filter { $0.value > 0 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map(\.key)
        var artists = MusicLibraryRequest<Artist>()
        artists.limit = 500
        var idByName: [String: String] = [:]
        for a in try await artists.response().items where idByName[a.name] == nil { idByName[a.name] = a.id.rawValue }
        return ranked.compactMap { name in
            idByName[name].map { StationSeed(kind: .artist, catalogID: $0, name: name, source: .library) }
        }.prefix(limit).map { $0 }
    }

    /// Recently played songs (Apple Music history, catalog IDs), most recent first.
    func recentlyPlayed(limit: Int) async throws -> [StationSeed] {
        var request = MusicRecentlyPlayedRequest<Song>()
        request.limit = limit
        return try await request.response().items.map {
            StationSeed(kind: .song, catalogID: $0.id.rawValue, name: $0.title)
        }
    }

    /// Playlists from Apple Music's personal recommendations.
    func recommendations(limit: Int) async throws -> [StationSeed] {
        let response = try await MusicPersonalRecommendationsRequest().response()
        let playlists = response.recommendations.flatMap { Array($0.playlists) }
        return playlists.prefix(limit).map { StationSeed(kind: .playlist, catalogID: $0.id.rawValue, name: $0.name) }
    }

    // MARK: Catalog lookups

    private func artist(_ id: String) async throws -> Artist? {
        var request = MusicCatalogResourceRequest<Artist>(matching: \.id, equalTo: MusicItemID(id))
        request.properties = [.topSongs, .similarArtists, .genres]
        return try await request.response().items.first
    }

    private func catalogSong(_ id: String) async throws -> Song? {
        var request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(id))
        request.properties = [.artists, .genres]
        return try await request.response().items.first
    }

    private func catalogPlaylist(_ id: String) async throws -> Playlist? {
        var request = MusicCatalogResourceRequest<Playlist>(matching: \.id, equalTo: MusicItemID(id))
        request.properties = [.tracks]
        return try await request.response().items.first
    }

    /// Up to `limit` top songs across `artists`, a few from each, alternating.
    private func topSongs(of artists: [Artist], limit: Int) async throws -> [Song] {
        var lists: [[Song]] = []
        for a in artists.prefix(5) {
            let detailed = try await a.with([.topSongs])
            lists.append(Array((detailed.topSongs ?? []).prefix(max(1, limit / 5))))
        }
        return Self.roundRobin(lists)
    }

    /// The playlist's three most frequent artists (by catalog ID).
    private func mainArtists(ofPlaylist id: String) async throws -> [Artist] {
        let songs = try await detailedSongs(ofPlaylist: id)
        var counts: [MusicItemID: (Int, Artist)] = [:]
        for song in songs { for a in song.artists ?? [] { counts[a.id] = ((counts[a.id]?.0 ?? 0) + 1, a) } }
        return counts.values.sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1.id.rawValue < $1.1.id.rawValue }
            .prefix(3).map(\.1)
    }

    private func genres(ofPlaylist id: String) async throws -> [String] {
        let songs = try await detailedSongs(ofPlaylist: id)
        return songs.flatMap { Array($0.genres ?? []).map(\.id.rawValue) }
    }

    /// The playlist's first 25 songs with artists and genres loaded (one request).
    private func detailedSongs(ofPlaylist id: String) async throws -> [Song] {
        let ids = Self.songs(in: try await catalogPlaylist(id)?.tracks).prefix(25).map(\.id)
        guard !ids.isEmpty else { return [] }
        var request = MusicCatalogResourceRequest<Song>(matching: \.id, memberOf: Array(ids))
        request.properties = [.artists, .genres]
        return Array(try await request.response().items)
    }

    private func chartSongs(genreID: String, limit: Int) async throws -> [Song] {
        guard StationSeed.isValidCatalogGenreID(genreID),
              let genre = try await catalogGenres(path: "genres/\(genreID)").first else { return [] }
        var request = MusicCatalogChartsRequest(genre: genre, kinds: [.mostPlayed], types: [Song.self])
        request.limit = min(max(limit, 1), 50)
        return try await request.response().songCharts.flatMap { Array($0.items) }
    }

    private func chartPlaylistSongs(genreID: String, playlists range: Range<Int>, limit: Int) async throws -> [Song] {
        guard StationSeed.isValidCatalogGenreID(genreID),
              let genre = try await catalogGenres(path: "genres/\(genreID)").first else { return [] }
        var request = MusicCatalogChartsRequest(genre: genre, kinds: [.mostPlayed], types: [Playlist.self])
        request.limit = range.upperBound
        let charts = try await request.response().playlistCharts.flatMap { Array($0.items) }
        var lists: [[Song]] = []
        for playlist in charts.dropFirst(range.lowerBound).prefix(range.count) {
            lists.append(Self.songs(in: try await playlist.with([.tracks]).tracks))
        }
        return Array(Self.roundRobin(lists).prefix(limit))
    }

    /// `Genre` has no catalog search, so read it from the storefront's genres endpoint.
    private func catalogGenres(path: String) async throws -> [Genre] {
        let country = try await MusicDataRequest.currentCountryCode
        guard let url = URL(string: "https://api.music.apple.com/v1/catalog/\(country)/\(path)") else { return [] }
        let response = try await MusicDataRequest(urlRequest: URLRequest(url: url)).response()
        return Array(try JSONDecoder().decode(MusicItemCollection<Genre>.self, from: response.data))
    }

    // MARK: Library lookups (on-device only)

    private func libraryPlaylistSongs(_ id: String) async throws -> [Song] {
        var request = MusicLibraryRequest<Playlist>()
        request.filter(matching: \.id, equalTo: MusicItemID(id))
        guard let playlist = try await request.response().items.first else { return [] }
        return Self.songs(in: try await playlist.with([.tracks]).tracks)
    }

    private func librarySong(_ id: String) async throws -> Song? {
        var request = MusicLibraryRequest<Song>()
        request.filter(matching: \.id, equalTo: MusicItemID(id))
        return try await request.response().items.first
    }

    /// Library songs by one artist, matched on the device (the name is never sent anywhere).
    private func librarySongs(byArtistNamed name: String) async throws -> [Song] {
        var request = MusicLibraryRequest<Song>()
        request.limit = 500
        return try await request.response().items.filter { $0.artistName == name }
            .sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }
    }

    // MARK: Helpers

    /// Caches the songs for `tracks(for:)` and maps them to engine candidates (catalog order).
    /// `origin` has no default: every lookup states whether it read the library or the catalog.
    private func remember<S: Sequence>(_ songs: S?, limit: Int, origin: TrackOrigin) -> [StationCandidate] where S.Element == Song {
        guard let songs else { return [] }
        let list = Array(songs.prefix(limit))
        if songsByID.count + list.count > Self.maxCachedSongs { songsByID.removeAll(); originsByID.removeAll() }
        for song in list {
            songsByID[song.id.rawValue] = song
            originsByID[song.id.rawValue] = (originsByID[song.id.rawValue] ?? origin).restricted(by: origin)
        }
        return list.map { song in
            StationCandidate(track: TrackInfo(id: song.id.rawValue, title: song.title, artistName: song.artistName,
                                              artworkURL: song.artwork?.url(width: 300, height: 300)))
        }
    }

    private static func songs(in tracks: MusicItemCollection<MusicKit.Track>?) -> [Song] {
        (tracks ?? []).compactMap { track -> Song? in
            guard case .song(let song) = track else { return nil }
            return song
        }
    }

    private static func roundRobin(_ lists: [[Song]]) -> [Song] {
        var result: [Song] = []
        for i in 0..<(lists.map(\.count).max() ?? 0) {
            for list in lists where i < list.count { result.append(list[i]) }
        }
        return result
    }

    private static func alternate(_ a: [Song], _ b: [Song]) -> [Song] { roundRobin([a, b]) }

    private static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}
