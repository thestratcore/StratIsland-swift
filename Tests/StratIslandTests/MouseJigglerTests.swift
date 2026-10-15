import CoreGraphics
import XCTest
@testable import StratIsland

final class MouseJigglerTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1000, height: 800)

    func testAlternatingMovement() throws {
        let point = CGPoint(x: 500, y: 400)
        let next = jiggleTarget(current: point, displays: [display], idleSeconds: 30, buttonDown: false, direction: 1)
        XCTAssertEqual(next, CGPoint(x: 501, y: 400))
        XCTAssertEqual(jiggleTarget(current: try XCTUnwrap(next), displays: [display], idleSeconds: 30, buttonDown: false, direction: -1), point)
    }

    func testSkipsActivityDraggingAndMenuStrip() {
        for (point, idle, button) in [(CGPoint(x: 500, y: 400), 9.9, false),
                                      (CGPoint(x: 500, y: 400), 30.0, true),
                                      (CGPoint(x: 500, y: 79), 30.0, false)] {
            XCTAssertNil(jiggleTarget(current: point, displays: [display], idleSeconds: idle, buttonDown: button, direction: 1))
        }
    }

    func testEdgesAndSecondaryDisplay() {
        XCTAssertEqual(jiggleTarget(current: CGPoint(x: 999, y: 100), displays: [display], idleSeconds: 10, buttonDown: false, direction: 1), CGPoint(x: 998, y: 100))
        let secondary = CGRect(x: -1000, y: -800, width: 1000, height: 800)
        XCTAssertEqual(jiggleTarget(current: CGPoint(x: -500, y: -400), displays: [display, secondary], idleSeconds: 30, buttonDown: false, direction: -1), CGPoint(x: -501, y: -400))
        XCTAssertNil(jiggleTarget(current: CGPoint(x: 2000, y: 100), displays: [display], idleSeconds: 30, buttonDown: false, direction: 1))
    }
}
