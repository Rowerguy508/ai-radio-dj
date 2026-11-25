import Foundation

// Sentinel's #410 n4 (-Fry): `NarrationPurger.purgeAllPersonalNarration()` had no app caller, so
// nothing ever published `NarrationPurgeFeed` `.all`, and the listeners built for a data reset
// (cached personal clips, planned breaks, ratings, location and local facts) never ran. The
// Settings row is that caller: one tap, confirmed, then the one purge-all. Owner's call (-Fry):
// its wording names only what the purge-all clears, not "all DJ data".

/// Removes the DJ's spoken clips and planned breaks that mention a personal item, then publishes
/// `.all`. Production: `NarrationPurger`.
public protocol PersonalNarrationResetting: Sendable {
    func purgeAllPersonalNarration() async
}

extension NarrationPurger: PersonalNarrationResetting {}

/// The Settings row that runs the purge-all: its copy, and the one action it runs.
public enum PersonalDataReset {
    public static let title = "Delete DJ clips, ratings and location"
    public static let confirm = "Delete"
    /// What `.all` clears today, and nothing more: spoken clips and planned breaks that mention a
    /// personal item (`NarrationPurger.purgeAllPersonalNarration`), cloud-voice clips of library
    /// songs and typed station names (`VoiceRenderer.allLinesClipTag`, owner's call on #433), song ratings
    /// (`StationRatingsModel.listen`), the saved location or typed place (`LocalAreaStore.listen`)
    /// saved GDELT news headlines and the queued fact lines (`LocalFactsWiring.listen`). The same
    /// purge also drops the on-device DJ template-id memory (`SpokenLineMemory`, #318); it holds no
    /// listener content, so the row does not name it. Whether a
    /// weather provider's own cache is cleared is unconfirmed, so the copy does not say so. It does NOT delete shared-inbox
    /// items, review decisions (`SharedReviewStore`, including any `.unreadable` copy),
    /// `PersonalUpdateLedger`, played song IDs, search text, stations, recipes or settings.
    public static let message = "Deletes the DJ's spoken clips and planned breaks that mention your calendar, notes or shared items, the cloud-voice clips of your library songs and station names, your song ratings, your saved location and saved news headlines. It doesn't delete the shared items themselves, your review choices, play history or search text. Your stations and settings stay."
    public static let footer = "Everything it deletes is stored only on this device. This can't be undone."
    public static let accessibilityIdentifier = "settings.deleteMyDJData"

    /// The row's action, after the listener confirms.
    public static func run(_ purger: any PersonalNarrationResetting) async {
        await purger.purgeAllPersonalNarration()
    }
}
