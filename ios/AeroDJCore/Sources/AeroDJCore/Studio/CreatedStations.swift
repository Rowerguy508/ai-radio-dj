import Foundation

// Created stations (-Atlas, P0 build 25): the Stations list shows every station the listener
// built with the add-station walkthrough. A created station is a saved recipe with seeds
// (`StationCreationModel.save` → `studio.saveRecipe(named:from:applying:)`), so the recipe
// library is its one store: saving adds the row, deleting or renaming the recipe in Tune
// updates it. Tuning-only recipes (no seeds) stay in Tune and are not stations.
// The row id is the recipe id. Nothing here plays, applies or logs.

/// One row in the Stations list for a station the listener created.
public struct CreatedStationEntry: Identifiable, Equatable, Hashable, Sendable {
    /// The recipe's id, stable across launches and renames.
    public let id: UUID
    public let name: String
    /// Fixed copy from the seed kind only ("Artist station"), never a seed's own name.
    public let summary: String

    public init(id: UUID, name: String, summary: String) {
        self.id = id
        self.name = name
        self.summary = summary
    }
}

public enum CreatedStations {
    /// Recipes that are stations (at least one seed), in the library's order.
    public static func entries(from recipes: [StationRecipe]) -> [CreatedStationEntry] {
        recipes.compactMap { recipe in
            guard let first = recipe.configuration.seeds.first else { return nil }
            return CreatedStationEntry(id: recipe.id, name: recipe.name,
                                       summary: summary(kind: first.kind, count: recipe.configuration.seeds.count))
        }
    }

    /// The created station with `id`, or nil (a built-in station, or a deleted recipe).
    public static func recipeID(for id: UUID, in recipes: [StationRecipe]) -> UUID? {
        entries(from: recipes).first { $0.id == id }?.id
    }

    static func summary(kind: StationSeedKind, count: Int) -> String {
        switch kind {
        case .artist: count > 1 ? "Your station from \(count) artists" : "Your artist station"
        case .genre: "Your genre station"
        case .playlist: "Your playlist station"
        case .song: "Your song station"
        }
    }
}
