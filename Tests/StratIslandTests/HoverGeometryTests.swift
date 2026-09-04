import CoreGraphics
import XCTest
@testable import StratIsland

final class HoverGeometryTests: XCTestCase {
    func testExpandedTargetContainsPointBelowAnimatingFrame() {
        let animatingFrame = CGRect(x: 100, y: 900, width: 468, height: 38)
        let expandedTarget = CGRect(x: 100, y: 760, width: 468, height: 178)
        let pointerInPanel = CGPoint(x: 320, y: 820)

        XCTAssertFalse(hoverContains(pointerInPanel, in: animatingFrame))
        XCTAssertTrue(hoverContains(pointerInPanel, in: expandedTarget))
    }

    func testMarginProvidesBoundaryHysteresis() {
        let frame = CGRect(x: 100, y: 760, width: 468, height: 178)
        let pointerJustOutside = CGPoint(x: 99, y: 800)

        XCTAssertFalse(hoverContains(pointerJustOutside, in: frame, margin: 0))
        XCTAssertTrue(hoverContains(pointerJustOutside, in: frame, margin: 4))
    }
}
