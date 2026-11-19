import AeroDJCore
import SwiftUI

/// Shared by `PlayingScreen` and `FoldedPlayer`. The machine lives above the
/// placement switch; each scroller names itself so a rebuild arms on its first
/// `scrollPosition` write, even if that write lands before `onChange`.
struct PlayerScrollAnchorHandle {
    var stored: Binding<String?>
    var machine: Binding<DisplayContinuity.ScrollAnchorMachine>

    func binding(scrollerID: String) -> Binding<String?> {
        Binding(
            get: { stored.wrappedValue },
            set: { incoming in
                var next = machine.wrappedValue
                let held = stored.wrappedValue ?? ""
                let result = next.write(incoming, stored: held, layout: scrollerID)
                machine.wrappedValue = next
                if result == .accept, (incoming ?? "") != (stored.wrappedValue ?? "") {
                    stored.wrappedValue = incoming
                }
            }
        )
    }

    func noteUserScrolled() {
        var next = machine.wrappedValue
        next.noteUserScrolled()
        machine.wrappedValue = next
    }

    /// The anchor ids the scroller laid out, top first. A held id that is not
    /// there releases the guard instead of leaving it armed.
    func noteScrollerIDs(_ ids: [String], scrollerID: String) {
        var next = machine.wrappedValue
        next.noteScrollerIDs(ids, stored: stored.wrappedValue ?? "", layout: scrollerID)
        if next != machine.wrappedValue { machine.wrappedValue = next }
    }
}

/// Anchor ids inside one player scroller, in layout order. Read by
/// `playerScrollPosition` on that scroller and cleared there, so an outer view
/// never sees another scroller's ids.
struct PlayerScrollAnchorIDsKey: PreferenceKey {
    static let defaultValue: [String] = []
    static func reduce(value: inout [String], nextValue: () -> [String]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// `.id` for a player scroll anchor, and the id reported to the scroller so
    /// the guard knows whether a held id exists there. `.id` stays outermost.
    func playerScrollAnchor(_ id: String) -> some View {
        self
            .preference(key: PlayerScrollAnchorIDsKey.self, value: [id])
            .id(id)
    }

    /// `scrollPosition` plus the user-scroll signal: `onScrollPhaseChange` on
    /// iOS 18+, a drag on iOS 17. A move to another id after adoption releases
    /// on every OS (VoiceOver, trackpad, mouse, `scrollTo`), and the scroller's
    /// ids release a held id it does not have.
    func playerScrollPosition(_ handle: PlayerScrollAnchorHandle, scrollerID: String) -> some View {
        self
            .scrollPosition(id: handle.binding(scrollerID: scrollerID))
            .modifier(PlayerUserScrollSignal(handle: handle))
            .backgroundPreferenceValue(PlayerScrollAnchorIDsKey.self) { ids in
                Color.clear
                    .accessibilityHidden(true)
                    .onChange(of: ids, initial: true) { _, laidOut in
                        handle.noteScrollerIDs(laidOut, scrollerID: scrollerID)
                    }
            }
            .transformPreference(PlayerScrollAnchorIDsKey.self) { $0 = [] }
    }
}

/// iOS 18+: a user scroll phase (tracking, interacting, decelerating). The
/// scroller's own adoption scroll is `.animating` and is not a user scroll.
/// iOS 17 has no `onScrollPhaseChange`, so it keeps the drag.
private struct PlayerUserScrollSignal: ViewModifier {
    let handle: PlayerScrollAnchorHandle

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { _, phase in
                switch phase {
                case .tracking, .interacting, .decelerating:
                    handle.noteUserScrolled()
                default:
                    break
                }
            }
        } else {
            content.simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { _ in handle.noteUserScrolled() }
            )
        }
    }
}
