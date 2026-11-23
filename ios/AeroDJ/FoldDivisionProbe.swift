import AeroDJCore
import SwiftUI

/// Reads the Duo hinge and the active division regions for `FoldAwareness`.
///
/// On the SDK this tree builds with, both reads are absent and the bindings stay
/// empty, so the wide player keeps the centred gutter. The iOS 27.1 calls are
/// compiled only with a newer compiler, and only run on that OS. The probe does
/// not take taps and is not an accessibility element. It is attached to the wide
/// player, the open-Duo Stations screen (#507 rest) and the Stations root's open-Duo gate
/// (wide-and-tall windows only), so the compact phone body is unchanged.
struct FoldDivisionProbe: View {
    @Binding var hinge: FoldAwareness.HingeSample?
    @Binding var divisions: [FoldAwareness.Division]

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .modifier(HingeObserver(hinge: $hinge))
                .onChange(of: FoldDivisionReading.regions(in: proxy), initial: true) { _, next in
                    if next != divisions { divisions = next }
                }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// `reservedRegions(kind: .division)`, sorted so an unchanged fold does not write state again.
private enum FoldDivisionReading {
    static func regions(in proxy: GeometryProxy) -> [FoldAwareness.Division] {
        #if compiler(>=6.4.2)
        if #available(iOS 27.1, *) {
            return proxy.reservedRegions(kind: .division).map { region in
                FoldAwareness.Division(
                    minX: half(region.frame.minX),
                    minY: half(region.frame.minY),
                    width: half(region.frame.width),
                    height: half(region.frame.height),
                    isActive: region.isActive)
            }
            .sorted { lhs, rhs in
                if lhs.minY != rhs.minY { return lhs.minY < rhs.minY }
                if lhs.minX != rhs.minX { return lhs.minX < rhs.minX }
                return lhs.width < rhs.width
            }
        }
        #endif
        return []
    }

    /// #538: rounds to 0.5pt so sub-point jitter in the reported frames cannot
    /// rewrite `divisions` on every layout pass.
    private static func half(_ value: CGFloat) -> Double {
        (Double(value) * 2).rounded() / 2
    }
}

/// `onHingeChange(isEnabled:_:)`. A missing hinge clears the sample. The angle is
/// recorded and `FoldAwareness.resolve` does not read it.
private struct HingeObserver: ViewModifier {
    @Binding var hinge: FoldAwareness.HingeSample?

    func body(content: Content) -> some View {
        hingeBody(content)
    }

    @ViewBuilder
    private func hingeBody(_ content: Content) -> some View {
        #if compiler(>=6.4.2)
        if #available(iOS 27.1, *) {
            // #538: the SDK may call this off the main thread. A plain closure here is
            // inferred @MainActor and Swift 6 traps on that executor check, so the
            // closure is @Sendable (not isolated), maps the context to our value
            // sample, and hops to the main actor to write state.
            content.onHingeChange(isEnabled: true) { @Sendable [binding = $hinge] _, newContext in
                let next: FoldAwareness.HingeSample? = newContext.hinge.map { device in
                    let status: FoldAwareness.HingeStatus
                    switch device.status {
                    case .closed: status = .closed
                    case .partiallyOpen: status = .partiallyOpen
                    case .fullyOpen: status = .fullyOpen
                    default: status = .unknown // Xcode 27.2 SDK adds hinge states; plain default keeps Release archive exhaustive
                    }
                    return FoldAwareness.HingeSample(status: status, angleDegrees: device.angle.degrees)
                }
                Task { @MainActor in
                    if binding.wrappedValue != next { binding.wrappedValue = next }
                }
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}
