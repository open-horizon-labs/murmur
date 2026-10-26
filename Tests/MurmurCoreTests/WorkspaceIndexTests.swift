import XCTest
@testable import MurmurCore

final class WorkspaceIndexTests: XCTestCase {
    func testRanksSSODecisionForAcmeExceptionQuery() {
        let results = DemoWorkspace.index.search("What was the Acme SSO exception decision?")

        XCTAssertEqual(results.first?.id, "decision-sso")
        XCTAssertEqual(results.first?.tier, .fast)
    }

    func testReturnsNoCueForUnrelatedSpeech() {
        let results = DemoWorkspace.index.search("Lovely weather for a walk after lunch")

        XCTAssertTrue(results.isEmpty)
    }

    func testRouterSuggestsDeepSkillOnlyForExplicitInvestigationLanguage() async {
        let router = AgentRouter(index: DemoWorkspace.index)
        let normal = await router.route(utterance: "Tell me about the Acme renewal")
        let investigation = await router.route(utterance: "Please investigate the Acme renewal pricing")

        XCTAssertEqual(normal.deep, .idle)
        XCTAssertEqual(investigation.deep, .suggested("workspace-investigation"))
    }

    func testWorkspaceLoaderIndexesDocumentsSourceAndManifests() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        try Data("Acme renewal decision and customer history".utf8)
            .write(to: folder.appendingPathComponent("renewal.md"))
        try Data("SAML issue remains open".utf8)
            .write(to: folder.appendingPathComponent("issue.txt"))
        try Data("struct SessionCoordinator {}".utf8)
            .write(to: folder.appendingPathComponent("SessionCoordinator.swift"))
        try Data("{\"scripts\":{\"test\":\"vitest\"}}".utf8)
            .write(to: folder.appendingPathComponent("package.json"))
        try Data("build:\n\tswift build".utf8)
            .write(to: folder.appendingPathComponent("Makefile"))

        let loaded = try await WorkspaceLoader().load(folder: folder)

        XCTAssertEqual(loaded.index.documentCount, 5)
        XCTAssertEqual(loaded.index.search("Acme renewal").first?.title, "renewal")
        XCTAssertEqual(
            loaded.index.search("Where is SessionCoordinator defined?").first?.title,
            "SessionCoordinator.swift"
        )
        XCTAssertEqual(loaded.index.search("vitest package scripts").first?.title, "package.json")
        XCTAssertEqual(loaded.index.search("swift build Makefile").first?.title, "Makefile")
    }

    func testWorkspaceLoaderExcludesSecretsGeneratedPathsAndGitignoredFiles() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        try write("ignored.swift\n*.trace\n", to: folder.appendingPathComponent(".gitignore"))
        try write("let visibleMarker = true", to: folder.appendingPathComponent("Visible.swift"))
        try write("let ignoredMarker = true", to: folder.appendingPathComponent("ignored.swift"))
        try write("trace marker", to: folder.appendingPathComponent("debug.trace"))
        try write("OPENAI_API_KEY=never-index", to: folder.appendingPathComponent(".env.local"))
        try write("token = never-index", to: folder.appendingPathComponent("credentials.json"))

        for directory in ["node_modules", "DerivedData", ".build"] {
            let generated = folder.appendingPathComponent(directory, isDirectory: true)
            try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)
            try write("let generatedMarker = true", to: generated.appendingPathComponent("Generated.swift"))
        }

        let loaded = try await WorkspaceLoader().load(folder: folder)

        XCTAssertEqual(loaded.index.documentCount, 1)
        XCTAssertEqual(loaded.index.search("visible marker").first?.title, "Visible.swift")
        XCTAssertTrue(loaded.index.search("ignored marker").isEmpty)
        XCTAssertTrue(loaded.index.search("never index").isEmpty)
        XCTAssertTrue(loaded.index.search("generated marker").isEmpty)
    }

    func testCodeChunksExposeLineRangesAndReturnMatchingChunk() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        var lines = (1...170).map { "// filler line \($0)" }
        lines[149] = "func invalidateCredentialCacheForAccount() { }"
        try write(lines.joined(separator: "\n"), to: folder.appendingPathComponent("CredentialCache.swift"))

        let loaded = try await WorkspaceLoader().load(folder: folder)
        let result = try XCTUnwrap(
            loaded.index.search("invalidate credential cache account", limit: 1).first
        )

        XCTAssertEqual(loaded.index.documentCount, 1)
        XCTAssertEqual(result.title, "CredentialCache.swift")
        XCTAssertTrue(result.source.hasPrefix("CredentialCache.swift:"))
        XCTAssertTrue(result.detail.contains("invalidateCredentialCacheForAccount"))
    }

    func testIdentifierAndPathMatchesOutrankBodyOnlyMatches() {
        let now = Date()
        let index = WorkspaceIndex(documents: [
            WorkspaceDocument(
                id: "generic",
                title: "Notes.md",
                source: "docs/Notes.md",
                body: "Auth token store migration notes and general background.",
                url: URL(fileURLWithPath: "/repo/docs/Notes.md"),
                updatedAt: now
            ),
            WorkspaceDocument(
                id: "implementation",
                title: "AuthTokenStore.swift",
                source: "Sources/Security/AuthTokenStore.swift:1-20",
                body: "actor AuthTokenStore { func load() {} }",
                url: URL(fileURLWithPath: "/repo/Sources/Security/AuthTokenStore.swift"),
                updatedAt: now
            )
        ])

        XCTAssertEqual(index.search("AuthTokenStore", limit: 1).first?.id, "implementation")
    }

    func testTranscriptionModelAPIIdentifiers() {
        XCTAssertEqual(TranscriptionModel.live.rawValue, "gpt-live-transcribe")
        XCTAssertEqual(TranscriptionModel.accurate.rawValue, "gpt-transcribe")
    }

    private func makeTemporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func write(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url)
    }
}
