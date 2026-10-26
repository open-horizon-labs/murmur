import XCTest
@testable import MurmurCore

final class WorkspaceToolsTests: XCTestCase {
    func testListSearchReadAndValidatedEvidence() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("first line\nAcme renewal approval\nlast line", to: root.appendingPathComponent("notes.md"))
        let tools = WorkspaceTools(workspace: root)

        let files = try await tools.execute(name: "list_workspace_files", arguments: #"{"directory":null}"#)
        XCTAssertEqual(files, "notes.md")
        let hits = try await tools.execute(name: "search_workspace", arguments: #"{"query":"renewal Acme","directory":null}"#)
        XCTAssertTrue(hits.contains("notes.md:2: Acme renewal approval"))
        let read = try await tools.execute(name: "read_workspace_file", arguments: #"{"path":"notes.md","line_start":2,"line_end":3}"#)
        XCTAssertTrue(read.contains("2: Acme renewal approval"))
        let valid = AgentEvidence(path: "notes.md", lineStart: 2, lineEnd: 2, excerpt: "Acme renewal approval")
        let fake = AgentEvidence(path: "../outside.txt", lineStart: 1, lineEnd: 1, excerpt: "secret")
        let approved = await tools.validatedEvidence([valid, fake])
        XCTAssertEqual(approved, [valid])
    }

    func testRejectsTraversalAbsoluteAndSymlinkPaths() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outside) }
        try write("outside secret", to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.txt"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linkdir"), withDestinationURL: outside.deletingLastPathComponent())
        let tools = WorkspaceTools(workspace: root)
        for path in ["../outside.txt", outside.path, "escape.txt"] {
            do {
                _ = try await tools.execute(name: "read_workspace_file", arguments: try args(["path": path, "line_start": 1, "line_end": 1]))
                XCTFail("Expected path to be rejected: \(path)")
            } catch { }
        }
        do {
            _ = try await tools.execute(name: "list_workspace_files", arguments: #"{"directory":"linkdir"}"#)
            XCTFail("Expected symlink directory to be rejected")
        } catch { }
    }

    func testExcludesSecretsGitignoredNestedAndGeneratedFiles() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("*.local\nprivate/\n**/private.md\n", to: root.appendingPathComponent(".gitignore"))
        try write("OPENAI_API_KEY=hidden", to: root.appendingPathComponent(".env.local"))
        try write("credential", to: root.appendingPathComponent("credentials.json"))
        try write("ignore me", to: root.appendingPathComponent("config.local"))
        try write("private secret", to: root.appendingPathComponent("private/nested.txt"))
        try write("private note", to: root.appendingPathComponent("private.md"))
        try write("nested private note", to: root.appendingPathComponent("docs/private.md"))
        try write("secret source", to: root.appendingPathComponent("secrets/nested/visible.md"))
        try write("*.hidden\n", to: root.appendingPathComponent("docs/.gitignore"))
        try write("do not expose", to: root.appendingPathComponent("docs/draft.hidden"))
        try write("visible doc", to: root.appendingPathComponent("docs/readme.md"))
        try write("generated", to: root.appendingPathComponent("build/out.txt"))
        try write("visible content", to: root.appendingPathComponent("visible.md"))
        let tools = WorkspaceTools(workspace: root)
        let files = try await tools.execute(name: "list_workspace_files", arguments: #"{"directory":null}"#)
        XCTAssertEqual(files, "docs/readme.md\nvisible.md")
        let hits = try await tools.execute(name: "search_workspace", arguments: #"{"query":"hidden credential secret","directory":null}"#)
        XCTAssertTrue(hits.isEmpty)
        do {
            _ = try await tools.execute(name: "read_workspace_file", arguments: #"{"path":"docs/draft.hidden","line_start":1,"line_end":1}"#)
            XCTFail("Direct reads must honor nested ignore rules")
        } catch { }
        for path in ["private.md", "PRIVATE.MD", "docs/private.md", "secrets/nested/visible.md"] {
            do {
                _ = try await tools.execute(name: "read_workspace_file", arguments: try args(["path": path, "line_start": 1, "line_end": 1]))
                XCTFail("Direct reads must honor the exclusion policy for \(path)")
            } catch { }
        }
    }

    func testEnforcesFileCountAndReadSizeBounds() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for number in 0..<510 { try write("marker \(number)", to: root.appendingPathComponent("file\(number).txt")) }
        try Data(repeating: 65, count: 1_000_001).write(to: root.appendingPathComponent("large.txt"))
        let tools = WorkspaceTools(workspace: root)
        let files = try await tools.execute(name: "list_workspace_files", arguments: #"{"directory":null}"#)
        XCTAssertEqual(files.components(separatedBy: .newlines).count, 500)
        do {
            _ = try await tools.execute(name: "read_workspace_file", arguments: #"{"path":"large.txt","line_start":1,"line_end":1}"#)
            XCTFail("Expected large file to be rejected")
        } catch { }
    }

    func testSchemasAreStrictAndToolSetIsBounded() {
        XCTAssertEqual(WorkspaceTools.definitions.count, 3)
        for item in WorkspaceTools.definitions {
            XCTAssertEqual(item["strict"]?.boolValue, true)
            XCTAssertEqual(item["parameters"]?["additionalProperties"]?.boolValue, false)
        }
    }

    func testIgnoreCharacterClassesEscapesAndPolicyChangesApplyToDirectReads() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["private1.json", "literal[1].md", "fresh.md"] {
            try write("excluded text", to: root.appendingPathComponent(path))
        }
        try write("private[0-9].json\nliteral\\[1\\].md\n", to: root.appendingPathComponent(".gitignore"))
        let tools = WorkspaceTools(workspace: root)
        for path in ["private1.json", "PRIVATE1.JSON", "literal[1].md", "private1.json\0.md"] {
            do {
                _ = try await tools.execute(name: "read_workspace_file", arguments: try args(["path": path, "line_start": 1, "line_end": 1]))
                XCTFail("Ignored or malformed path must be denied")
            } catch { }
        }
        try write("fresh.md\n", to: root.appendingPathComponent(".gitignore"))
        do {
            _ = try await tools.execute(name: "read_workspace_file", arguments: #"{"path":"fresh.md","line_start":1,"line_end":1}"#)
            XCTFail("Each read must apply the current exclusion policy")
        } catch { }
    }

    func testUnreadableSymlinkPolicyFailsClosed() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("private text", to: root.appendingPathComponent("private.md"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".gitignore"), withDestinationURL: root.appendingPathComponent("missing-policy"))
        let tools = WorkspaceTools(workspace: root)
        do {
            _ = try await tools.execute(name: "read_workspace_file", arguments: #"{"path":"private.md","line_start":1,"line_end":1}"#)
            XCTFail("Unknown policy must not expose files")
        } catch { }
    }

    func testEvidenceFromMultipleReadsSurvivesAndNullEndMeansSingleLine() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("first source", to: root.appendingPathComponent("one.md"))
        try write("second source", to: root.appendingPathComponent("two.md"))
        let tools = WorkspaceTools(workspace: root)
        for path in ["one.md", "two.md"] {
            _ = try await tools.execute(name: "read_workspace_file", arguments: try args(["path": path, "line_start": 1, "line_end": 1]))
        }
        let findings = await tools.validatedEvidence([
            AgentEvidence(path: "one.md", lineStart: 1, lineEnd: nil, excerpt: "first source"),
            AgentEvidence(path: "two.md", lineStart: 1, lineEnd: 1, excerpt: "second source"),
            AgentEvidence(path: "one.md", lineStart: 1, lineEnd: 1, excerpt: "made up")
        ])
        XCTAssertEqual(findings.map(\.path), ["one.md", "two.md"])
        XCTAssertEqual(findings.first?.lineEnd, 1)
    }

    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    private func args(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}
