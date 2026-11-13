import Foundation

/// #438 (-Atlas): which station a queue the station player starts belongs to.
///
/// The tag is `PlaybackSnapshot.station`. The car reads it for the Now Playing station name and
/// for the row that shows the playing mark (`CarPlayScreen`), so it has to be the station whose
/// songs are playing, wherever that station was opened (car or phone). Before this, a station
/// start copied the tag the previous queue had, so after a station switch the car could name the
/// old station and mark its row while the new one played.
///
/// The owner is the station whose configuration is committed now: the built-in or saved station
/// last applied (`StudioPresentationModel.lastAppliedRecipeID`), when its seeds still match the
/// committed ones (the same rule as `StationRatingScope.recipeID`). Only ids and names that are
/// already on the station rows; never a summary, seed, song, or anything the DJ says.
public enum StationQueueOwner {
    /// Nil when the committed station is neither a matching built-in nor a matching saved
    /// station with a name (no seeds, edited seeds, a deleted recipe, nothing applied).
    public static func station(lastApplied: UUID?, recipes: [StationRecipe],
                               committed: StationConfiguration) -> StationRef? {
        guard let lastApplied, let key = StationQueueKey(committed) else { return nil }
        if let builtIn = BuiltInStations.station(id: lastApplied) {
            guard StationQueueKey(builtIn.configuration)?.seedsFingerprint == key.seedsFingerprint else { return nil }
            return StationRef(id: builtIn.id.uuidString, name: builtIn.name)
        }
        guard let id = StationRatingScope.recipeID(lastApplied: lastApplied, recipes: recipes, committed: committed),
              let recipe = recipes.first(where: { $0.id == id }),
              !recipe.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return StationRef(id: id.uuidString, name: recipe.name)
    }

    /// The tag for a new station queue: its owner, or (owner unknown) the playing queue's tag,
    /// which is what every station start used before #438.
    public static func tag(owner: StationRef?, playing: StationRef?) -> StationRef? {
        owner ?? playing
    }
}
