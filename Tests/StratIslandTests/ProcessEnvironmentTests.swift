import XCTest
@testable import StratIsland

/// `KERN_PROCARGS2` is an undocumented binary layout, and getting the argv skip wrong
/// silently yields an empty environment — which reads exactly like "this session isn't in
/// cmux". So the parsing is exercised against a hand-built buffer rather than trusted.
final class ProcessEnvironmentTests: XCTestCase {

    /// argc, exec path, padding NULs, argv strings, then env strings.
    private func procArgs2Buffer(
        execPath: String, argv: [String], env: [String], padding: Int = 3
    ) -> Data {
        var data = Data()
        var argc = Int32(argv.count)
        withUnsafeBytes(of: &argc) { data.append(contentsOf: $0) }
        data.append(contentsOf: Array(execPath.utf8))
        data.append(contentsOf: [UInt8](repeating: 0, count: padding + 1))
        for arg in argv + env {
            data.append(contentsOf: Array(arg.utf8))
            data.append(0)
        }
        return data
    }

    func testParsesEnvironmentAfterArgv() {
        let data = procArgs2Buffer(
            execPath: "/usr/local/bin/claude",
            // Claude is launched with a JSON settings blob as an argument; an argv entry
            // containing '=' must not be mistaken for an environment variable.
            argv: ["claude", "--settings", #"{"hooks":{"Stop":[]}}"#, "--flag=value"],
            env: [
                "HOME=/Users/admin",
                "CMUX_SURFACE_ID=D80B10B2-D3E2-4701-B605-4EA265895852",
                "CMUX_WORKSPACE_ID=AF77882C-4030-44C3-AF01-07F8B454DBF0",
                "CMUX_AGENT_LAUNCH_KIND=claude",
            ]
        )
        let env = parseProcArgs2(data)
        XCTAssertEqual(env?["HOME"], "/Users/admin")
        XCTAssertEqual(env?["CMUX_SURFACE_ID"], "D80B10B2-D3E2-4701-B605-4EA265895852")
        XCTAssertEqual(env?["CMUX_AGENT_LAUNCH_KIND"], "claude")
        XCTAssertNil(env?["--flag"], "argv must not leak into the environment")
    }

    func testKeepsValuesContainingEquals() {
        let data = procArgs2Buffer(
            execPath: "/bin/zsh", argv: ["zsh"],
            env: ["NODE_OPTIONS=--require=/tmp/shim.cjs --max-old-space-size=4096"]
        )
        XCTAssertEqual(
            parseProcArgs2(data)?["NODE_OPTIONS"],
            "--require=/tmp/shim.cjs --max-old-space-size=4096"
        )
    }

    func testBindingRequiresASurface() {
        XCTAssertNil(cmuxBinding(in: ["HOME": "/Users/admin"]))
        XCTAssertNil(cmuxBinding(in: ["CMUX_SURFACE_ID": ""]))
        let binding = cmuxBinding(in: [
            "CMUX_SURFACE_ID": "surface-uuid",
            "CMUX_WORKSPACE_ID": "workspace-uuid",
            "CMUX_AGENT_LAUNCH_KIND": "codex",
        ])
        XCTAssertEqual(binding?.surfaceID, "surface-uuid")
        XCTAssertEqual(binding?.workspaceID, "workspace-uuid")
        XCTAssertEqual(binding?.agentKind, "codex")
    }

    /// The app reads its own environment through the same path it uses for session
    /// processes, so this covers the sysctl call as well as the parsing.
    func testReadsOwnEnvironment() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let env = try XCTUnwrap(processEnvironment(pid))
        XCTAssertEqual(env["HOME"], ProcessInfo.processInfo.environment["HOME"])
    }

    /// End-to-end when the suite itself is run from a cmux pane: the resolver has to find
    /// the surface by walking up from a process cmux never launched directly (the test
    /// binary), which is the same shape as a background Claude job under its daemon.
    @MainActor
    func testResolvesSurfaceForOwnProcessWhenRunUnderCmux() throws {
        let expected = try XCTUnwrap(
            ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"],
            "not running under cmux"
        )
        CmuxBindingResolver.resetForTesting()
        let binding = CmuxBindingResolver.binding(forPID: ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(binding?.surfaceID, expected)
    }

    func testWindowIDIsReadFromFocusResponse() {
        let response = """
        {
          "surface_id" : "D80B10B2-D3E2-4701-B605-4EA265895852",
          "window_id" : "3B0155A5-B4EC-4879-B03D-E0D44C4B7DD5",
          "workspace_ref" : "workspace:1"
        }
        """
        XCTAssertEqual(jsonString(in: response, key: "window_id"), "3B0155A5-B4EC-4879-B03D-E0D44C4B7DD5")
        XCTAssertNil(jsonString(in: "Error: not_found: Workspace not found", key: "window_id"))
    }
}
