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
}

extension View {
    /// `scrollPosition` plus a drag that tells the machine the user is scrolling,
    /// so a later write of the art is kept. iOS 17: no `onScrollPhaseChange`.
    func playerScrollPosition(_ handle: PlayerScrollAnchorHandle, scrollerID: String) -> some View {
        self
            .scrollPosition(id: handle.binding(scrollerID: scrollerID))
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { _ in handle.noteUserScrolled() }
            )
    }
}
