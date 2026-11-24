import CoreGraphics
import XCTest

/// Simulators report frames with sub-point float noise: a 44 pt button measured
/// 43.99999999999994 pt on the iPhone Air (#421). 0.01 pt is far below one display pixel
/// (1/3 pt at 3x, 1/2 pt at 2x), so a target that is even one pixel short still fails.
let framePointNoise: CGFloat = 0.01

/// Checks that a measured frame size is at least `minimum` points, ignoring only float noise.
func assertAtLeastPoints(_ value: CGFloat, _ minimum: CGFloat, _ message: @autoclosure () -> String = "",
                         file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertGreaterThanOrEqual(value, minimum - framePointNoise, message(), file: file, line: line)
}
