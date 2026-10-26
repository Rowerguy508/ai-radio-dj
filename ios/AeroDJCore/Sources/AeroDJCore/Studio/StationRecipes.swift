import Foundation
import Observation

// Station recipes: named, saved Station Tuner settings. Minimal by design: save, load,
// rename, delete, apply. A recipe holds tuning only, never connections, and applying
// one follows the same boundary rules as editing each control.

public struct StationRecipe: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    /// Tuning only: `requestedIntegrations` is always empty in a recipe.
    public var configuration: StationConfiguration
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, configuration: StationConfiguration,
                createdAt: Date = Date(), updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        var tuning = configuration.validated()
        tuning.requestedIntegrations = []
        self.configuration = tuning
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    public static let maxNameLength = 40
    public static let maxRecipes = 50

    /// Trimmed, whitespace-collapsed name, or the reason it is not allowed.
    public static func normalizedName(_ raw: String) -> Result<String, StationRecipeError> {
        let name = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if name.isEmpty { return .failure(.emptyName) }
        if name.count > maxNameLength { return .failure(.nameTooLong) }
        return .success(name)
    }

    private enum CodingKeys: String, CodingKey { case id, name, configuration, createdAt, updatedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let created = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        self.init(id: try c.decode(UUID.self, forKey: .id),
                  name: try c.decode(String.self, forKey: .name),
                  configuration: (try? c.decodeIfPresent(StationConfiguration.self, forKey: .configuration)) ?? .default,
                  createdAt: created,
                  updatedAt: try c.decodeIfPresent(Date.self, forKey: .updatedAt))
    }
}

public enum StationRecipeError: Error, Equatable, Sendable {
    case emptyName
    case nameTooLong
    case duplicateName
    case limitReached
    case notFound
    /// Not saved; the library was rolled back.
    case saveFailed
    /// Recipes on disk are from a newer AeroDJ; the library is read-only.
    case readOnlyNewerVersion
    case notLoaded

    public var userMessage: String {
        switch self {
        case .emptyName: "Give the recipe a name."
        case .nameTooLong: "Use \(StationRecipe.maxNameLength) characters or fewer."
        case .duplicateName: "You already have a recipe with that name."
        case .limitReached: "You can keep up to \(StationRecipe.maxRecipes) recipes. Delete one first."
        case .notFound: "That recipe no longer exists."
        case .saveFailed: "Couldn't save. Nothing changed."
        case .readOnlyNewerVersion: "Recipes were saved by a newer AeroDJ and can't be edited here."
        case .notLoaded: "Recipes are still loading."
        }
    }
}

/// Versioned on-disk form. Bump `currentVersion` only with a migration.
public struct StationRecipeLibrarySnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public let version: Int
    public let recipes: [StationRecipe]

    public init(recipes: [StationRecipe]) {
        self.version = Self.currentVersion
        self.recipes = recipes
    }

    private enum CodingKeys: String, CodingKey { case version, recipes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard version <= Self.currentVersion else { throw StationConfigurationStoreError.newerVersion(version) }
        // Tolerant: a single unreadable recipe is dropped, not the whole library.
        let raw = (try? c.decodeIfPresent([FailableRecipe].self, forKey: .recipes)) ?? []
        self.version = Self.currentVersion
        self.recipes = raw.compactMap(\.recipe)
    }

    private struct FailableRecipe: Decodable {
        let recipe: StationRecipe?
        init(from decoder: Decoder) throws { recipe = try? StationRecipe(from: decoder) }
    }

    public static func decode(_ data: Data) throws -> StationRecipeLibrarySnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(Self.self, from: data) }
        catch let error as StationConfigurationStoreError { throw error }
        catch { throw StationConfigurationStoreError.unreadable }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

public protocol StationRecipePersisting: Sendable {
    func load() async throws -> StationRecipeLibrarySnapshot?
    func save(_ snapshot: StationRecipeLibrarySnapshot) async throws
}

public actor InMemoryStationRecipeStore: StationRecipePersisting {
    public private(set) var data: Data?
    public private(set) var saveCount = 0
    public private(set) var failSaves = false

    public init(snapshot: StationRecipeLibrarySnapshot? = nil) { data = try? snapshot?.encoded() }
    public init(rawData: Data?) { data = rawData }
    public func setFailSaves(_ fail: Bool) { failSaves = fail }

    public func load() async throws -> StationRecipeLibrarySnapshot? {
        guard let data else { return nil }
        return try StationRecipeLibrarySnapshot.decode(data)
    }

    public func save(_ snapshot: StationRecipeLibrarySnapshot) async throws {
        if failSaves { throw StationConfigurationStoreError.writeFailed }
        data = try snapshot.encoded()
        saveCount += 1
    }
}

/// JSON in Application Support, atomic writes. Preferences only: no personal context.
public actor FileStationRecipeStore: StationRecipePersisting {
    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }

    public func load() async throws -> StationRecipeLibrarySnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        guard let data = try? Data(contentsOf: fileURL) else { throw StationConfigurationStoreError.unreadable }
        return try StationRecipeLibrarySnapshot.decode(data)
    }

    public func save(_ snapshot: StationRecipeLibrarySnapshot) async throws {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try snapshot.encoded().write(to: fileURL, options: [.atomic])
        } catch { throw StationConfigurationStoreError.writeFailed }
    }
}

/// Recipe list for the Studio. Create once at app/scene level.
@MainActor @Observable
public final class StationRecipeLibrary {
    /// Sorted by name for display.
    public private(set) var recipes: [StationRecipe] = []
    public private(set) var loadState: StationConfigurationLoadState = .notLoaded

    @ObservationIgnored private let store: any StationRecipePersisting
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var lastSave: Task<Bool, Never>?

    public init(store: any StationRecipePersisting, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    public func load() async {
        loadState = .loading
        do {
            recipes = Self.sorted(try await store.load()?.recipes ?? [])
            loadState = .ready
        } catch let error as StationConfigurationStoreError {
            recipes = []
            loadState = .failed(error)
        } catch {
            recipes = []
            loadState = .failed(.unreadable)
        }
    }

    public func recipe(_ id: UUID) -> StationRecipe? { recipes.first { $0.id == id } }

    /// Saves the station's current tuning (`displayed`, so pending edits are included) under `name`.
    @discardableResult
    public func save(name: String, configuration: StationConfiguration) async -> Result<StationRecipe, StationRecipeError> {
        if let error = writeBlocker { return .failure(error) }
        let clean: String
        switch StationRecipe.normalizedName(name) {
        case .failure(let e): return .failure(e)
        case .success(let n): clean = n
        }
        guard !isTaken(clean, except: nil) else { return .failure(.duplicateName) }
        guard recipes.count < StationRecipe.maxRecipes else { return .failure(.limitReached) }
        let recipe = StationRecipe(name: clean, configuration: configuration, createdAt: now())
        let saved = await commit(recipes + [recipe])
        return saved ? .success(recipe) : .failure(.saveFailed)
    }

    @discardableResult
    public func rename(_ id: UUID, to newName: String) async -> Result<StationRecipe, StationRecipeError> {
        if let error = writeBlocker { return .failure(error) }
        guard let index = recipes.firstIndex(where: { $0.id == id }) else { return .failure(.notFound) }
        let name: String
        switch StationRecipe.normalizedName(newName) {
        case .failure(let e): return .failure(e)
        case .success(let n): name = n
        }
        guard !isTaken(name, except: id) else { return .failure(.duplicateName) }
        var next = recipes
        next[index].name = name
        next[index].updatedAt = now()
        let renamed = next[index]
        return await commit(next) ? .success(renamed) : .failure(.saveFailed)
    }

    @discardableResult
    public func delete(_ id: UUID) async -> Result<Void, StationRecipeError> {
        if let error = writeBlocker { return .failure(error) }
        guard recipes.contains(where: { $0.id == id }) else { return .failure(.notFound) }
        return await commit(recipes.filter { $0.id != id }) ? .success(()) : .failure(.saveFailed)
    }

    /// Applies a recipe to the station with the normal boundary rules. Returns the
    /// pending timing per control so the UI can say "Applies after this song", etc.
    @discardableResult
    public func apply(_ id: UUID, to station: StationConfigurationModel) async -> Result<[StationSetting: StationChangeTiming], StationRecipeError> {
        guard let recipe = recipe(id) else { return .failure(.notFound) }
        await station.applyRecipe(recipe)
        return .success(station.state.pendingSettings)
    }

    // MARK: Internals

    private var writeBlocker: StationRecipeError? {
        switch loadState {
        case .notLoaded, .loading: .notLoaded
        case .failed(.newerVersion): .readOnlyNewerVersion
        default: nil
        }
    }

    private func isTaken(_ name: String, except id: UUID?) -> Bool {
        recipes.contains { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Optimistic update, serialized saves, rollback on failure.
    private func commit(_ next: [StationRecipe]) async -> Bool {
        let before = recipes
        recipes = Self.sorted(next)
        let previous = lastSave
        let store = store
        let snapshot = StationRecipeLibrarySnapshot(recipes: recipes)
        let task = Task { () -> Bool in
            _ = await previous?.value
            do { try await store.save(snapshot); return true } catch { return false }
        }
        lastSave = task
        let ok = await task.value
        if !ok { recipes = before }
        return ok
    }

    private static func sorted(_ list: [StationRecipe]) -> [StationRecipe] {
        list.sorted { ($0.name.localizedLowercase, $0.id.uuidString) < ($1.name.localizedLowercase, $1.id.uuidString) }
    }
}
