import AeroDJCore
import SwiftUI

/// Reads the Duo hinge and the active division regions for `FoldAwareness`.
///
/// On the SDK this tree builds with, both reads are absent and the bindings stay
/// empty, so the wide player keeps the centred gutter. The iOS 27.1 calls are
/// compiled only with a newer compiler, and only run on that OS. The probe does
/// not take taps and is not an accessibility element. It is attached to the wide
/// player only, so the compact phone body is unchanged.
struct FoldDivisionProbe: View {
    @Binding var hinge: FoldAwareness.HingeSample?
    @Binding var divisions: [FoldAwareness.Division]

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .modifier(HingeObserver(hinge: $hinge))
                .onChange(of: FoldDivisionReading.regions(in: proxy), initial: true) { _, next in
                    divisions = next
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
                    minX: Double(region.frame.minX),
                    minY: Double(region.frame.minY),
                    width: Double(region.frame.width),
                    height: Double(region.frame.height),
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
            content.onHingeChange(isEnabled: true) { _, newContext in
                guard let device = newContext.hinge else {
                    hinge = nil
                    return
                }
                let status: FoldAwareness.HingeStatus
                switch device.status {
                case .closed: status = .closed
                case .partiallyOpen: status = .partiallyOpen
                case .fullyOpen: status = .fullyOpen
                @unknown default: status = .unknown
                }
                hinge = FoldAwareness.HingeSample(status: status, angleDegrees: device.angle.degrees)
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}
