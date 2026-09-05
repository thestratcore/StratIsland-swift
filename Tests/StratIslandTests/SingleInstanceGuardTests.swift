import Foundation
import XCTest
@testable import StratIsland

final class SingleInstanceGuardTests: XCTestCase {
    func testOnlyOneGuardCanOwnPathAndLockIsReleased() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let path = directory.appendingPathComponent("instance.lock").path
        defer { try? FileManager.default.removeItem(at: directory) }

        var first: SingleInstanceGuard? = try XCTUnwrap(SingleInstanceGuard.acquire(at: path))
        XCTAssertNotNil(first)
        XCTAssertNil(try SingleInstanceGuard.acquire(at: path))

        first = nil
        XCTAssertNotNil(try SingleInstanceGuard.acquire(at: path))
    }
}
