import Foundation
import XCTest
@testable import StratIsland

@MainActor
final class SessionTitleTests: XCTestCase {
    func testCodexTitleSkipsInjectedContext() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let injected = try event(text: "The following <skills_instructions> are runtime policy")
        let prompt = try event(text: "Inspect the running StratIsland")
        try "\(injected)\n\(prompt)\n".write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(SessionTitle.codex(rolloutPath: url.path), "Inspect the running StratIsland")
    }

    private func event(text: String) throws -> String {
        let object: [String: Any] = [
            "payload": [
                "role": "user",
                "content": [["text": text]],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }
}
