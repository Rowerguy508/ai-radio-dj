import SwiftUI

/// Opaque card chrome for Tune and Connections rows.
///
/// Not Liquid Glass: these sit inside the workspace surface, and stacking glass reads as
/// a pile of translucent cards. Pending rows get an orange edge in addition to the
/// text badge, so the state is never color alone. This modifier does not replace
/// the row's VoiceOver label. Reduce Transparency is already satisfied because the
/// fill is an opaque system background. Nothing here animates.
struct StudioCard: ViewModifier {
    var emphasized = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(emphasized ? Color.orange.opacity(0.9) : Color(.separator).opacity(0.55),
                                  lineWidth: emphasized ? 1.5 : 0.5)
            }
    }
}

extension View {
    func studioCard(emphasized: Bool = false) -> some View {
        modifier(StudioCard(emphasized: emphasized))
    }
}
