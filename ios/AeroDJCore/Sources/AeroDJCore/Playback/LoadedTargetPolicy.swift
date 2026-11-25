import Foundation

/// The song a successful load actually put in the player, with the queue generation of that load.
/// A skip that fails or is cut leaves this nil: the player may still hold the previous song.
public struct LoadedPlayerTarget: Equatable, Sendable {
    public let index: Int
    public let generation: Int

    public init(index: Int, generation: Int) {
        self.index = index
        self.generation = generation
    }
}

/// What a resume may do with the player. `playLoaded` is the only decision that may call `play()`
/// on the entry already loaded. Anything else must not start the previous song.
public enum ResumeTargetDecision: Equatable, Sendable {
    /// The player holds the selected song for this queue generation.
    case playLoaded
    /// The selected song can be loaded, and the player does not hold it.
    case reloadSelected
    /// The selected index has nothing playable. Do not start whatever is still loaded.
    case failClosed
}

public enum LoadedTargetPolicy {
    /// Resume plays the loaded song only when it is the selected one. A failed or cut skip leaves
    /// the previous song loaded and the index on the song that did not start; that must not play.
    public static func decide(
        loaded: LoadedPlayerTarget?,
        selectedIndex: Int,
        generation: Int,
        selectedIsPlayable: Bool
    ) -> ResumeTargetDecision {
        guard selectedIsPlayable else { return .failClosed }
        if let loaded, loaded.index == selectedIndex, loaded.generation == generation {
            return .playLoaded
        }
        return .reloadSelected
    }
}
