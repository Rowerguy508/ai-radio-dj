import Foundation

// Sentinel's #410 n4 (-Fry): `NarrationPurger.purgeAllPersonalNarration()` had no app caller, so
// nothing ever published `NarrationPurgeFeed` `.all`, and the listeners built for a data reset
// (cached personal clips, planned breaks, ratings, location and local facts) never ran. Settings
// "Delete my DJ data" is that caller: one tap, confirmed, then the one purge-all.

/// Removes all personal narration and publishes `.all`. Production: `NarrationPurger`.
public protocol PersonalNarrationResetting: Sendable {
    func purgeAllPersonalNarration() async
}

extension NarrationPurger: PersonalNarrationResetting {}

/// Settings "Delete my DJ data": the copy, and the one action the row runs.
public enum PersonalDataReset {
    public static let title = "Delete my DJ data"
    public static let confirm = "Delete"
    /// What `.all` clears today: personal clips and planned breaks (`NarrationPurger`), ratings
    /// (`StationRatingsModel.listen`), location and queued weather and news (`LocalAreaStore` and
    /// `LocalFactsWiring.listen`). Stations, recipes and settings stay.
    public static let message = "Deletes what the DJ prepared from your calendar, notes and shared items, your song ratings, and your location for weather and news. Your stations and settings stay."
    public static let footer = "Everything it deletes is stored only on this device. This can't be undone."
    public static let accessibilityIdentifier = "settings.deleteMyDJData"

    /// The row's action, after the listener confirms.
    public static func run(_ purger: any PersonalNarrationResetting) async {
        await purger.purgeAllPersonalNarration()
    }
}
