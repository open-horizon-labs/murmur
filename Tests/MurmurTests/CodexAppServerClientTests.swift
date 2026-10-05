import Foundation
import XCTest
@testable import MurmurApp

final class CodexAppServerClientTests: XCTestCase {
    func testExecutableLocatorPrefersExplicitOverrideThenFinderSafeCandidates() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let override = root.appendingPathComponent("override-codex")
        let installed = root.appendingPathComponent("installed-codex")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for executable in [override, installed] {
            try Data("#!/bin/sh\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }

        XCTAssertEqual(
            try CodexExecutableLocator.locate(
                environment: ["MURMUR_CODEX_PATH": override.path, "PATH": ""],
                fixedCandidates: [installed.path]
            ),
            override.standardizedFileURL
        )
        XCTAssertEqual(
            try CodexExecutableLocator.locate(
                environment: ["PATH": ""],
                fixedCandidates: [installed.path]
            ),
            installed.standardizedFileURL
        )
    }

    func testFinderStyleEnvironmentLaunchesSelectedRuntimeBackedAppServer() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let wrapper = root.appendingPathComponent("wrapper-codex")
        let runtimeFolder = root.appendingPathComponent(".asdf/shims", isDirectory: true)
        let node = runtimeFolder.appendingPathComponent("node")
        try FileManager.default.createDirectory(at: runtimeFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        #!/bin/sh
        exec node "$@"
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        IFS= read -r request
        printf '%s\\n' '{"id":1,"result":{}}'
        IFS= read -r initialized
        while IFS= read -r ignored; do :; done
        """.write(to: node, atomically: true, encoding: .utf8)
        for executable in [wrapper, node] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }

        let finderEnvironment = [
            "HOME": root.path,
            "USER": "fixture-user",
            "PATH": "/usr/bin:/bin"
        ]
        let executable = try CodexExecutableLocator.locate(
            environment: finderEnvironment,
            fixedCandidates: [wrapper.path]
        )
        let client = try CodexAppServerClient(
            executableURL: executable,
            environment: finderEnvironment
        )

        try await client.start()
        await client.stop()
    }

    func testRPCWithoutResponseTimesOutAndReleasesCaller() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let executable = root.appendingPathComponent("codex-timeout-fixture")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        #!/bin/sh
        IFS= read -r initialize
        printf '%s\\n' '{"id":1,"result":{}}'
        IFS= read -r initialized
        IFS= read -r request
        sleep 2
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let client = try CodexAppServerClient(
            executableURL: executable,
            environment: ["HOME": root.path, "PATH": "/usr/bin:/bin"],
            requestTimeout: .milliseconds(40)
        )
        try await client.start()
        do {
            _ = try await client.listModels()
            XCTFail("Expected the unanswered model/list request to time out")
        } catch let error as CodexAppServerError {
            XCTAssertEqual(error, .requestTimedOut("model/list"))
        }
        await client.stop()
    }

    func testInstalledCodexLaunchesWithFinderPathWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["MURMUR_SIGNED_HOST_SMOKE"] == "1" else {
            throw XCTSkip("Set MURMUR_SIGNED_HOST_SMOKE=1 to probe the installed Codex App Server with a Finder PATH.")
        }
        let environment = [
            "HOME": NSHomeDirectory(),
            "USER": NSUserName(),
            "PATH": "/usr/bin:/bin"
        ]
        let client = try CodexAppServerClient(environment: environment)
        try await client.start()
        let models = try await client.listModels()
        XCTAssertFalse(models.isEmpty)
        await client.stop()
    }

    func testJSONLineFramerHandlesPartialAndMultipleReads() throws {
        var framer = JSONLineFramer()

        XCTAssertTrue(framer.append(Data("{\"id\":1".utf8)).isEmpty)
        let firstBatch = framer.append(Data("}\n{\"method\":\"turn/started\"}\r\n{\"tail\"".utf8))

        XCTAssertEqual(firstBatch.count, 2)
        XCTAssertEqual(String(decoding: firstBatch[0], as: UTF8.self), "{\"id\":1}")
        XCTAssertEqual(String(decoding: firstBatch[1], as: UTF8.self), "{\"method\":\"turn/started\"}")

        let secondBatch = framer.append(Data(":true}\n".utf8))
        XCTAssertEqual(secondBatch.map { String(decoding: $0, as: UTF8.self) }, ["{\"tail\":true}"])
        XCTAssertTrue(framer.finish().isEmpty)
    }

    func testDecodesCollabAgentEventFromItemNotification() throws {
        let payload = try decodeJSON("""
        {
          "threadId": "parent",
          "turnId": "turn-1",
          "item": {
            "type": "collabAgentToolCall",
            "id": "call-1",
            "tool": "spawnAgent",
            "status": "inProgress",
            "senderThreadId": "parent",
            "receiverThreadIds": ["child-a", "child-b"],
            "prompt": "Trace the queue",
            "model": "gpt-5.6-sol",
            "reasoningEffort": "high",
            "agentsStates": {
              "child-a": {"status": "running"},
              "child-b": {"status": "pendingInit"}
            }
          }
        }
        """)

        XCTAssertEqual(
            CodexProtocolDecoder.event(method: "item/started", params: payload),
            .collabAgentCall(CodexCollabAgentCall(
                id: "call-1",
                tool: "spawnAgent",
                status: "inProgress",
                senderThreadID: "parent",
                receiverThreadIDs: ["child-a", "child-b"],
                prompt: "Trace the queue",
                model: "gpt-5.6-sol",
                reasoningEffort: "high",
                agentStates: ["child-a": "running", "child-b": "pendingInit"]
            ))
        )
    }

    func testSanitizedChildEnvironmentDoesNotInheritSecrets() {
        let clean = CodexChildEnvironment.sanitize([
            "HOME": "/Users/example",
            "PATH": "/usr/bin:/bin",
            "LANG": "en_US.UTF-8",
            "LC_CTYPE": "UTF-8",
            "CODEX_HOME": "/Users/example/.codex",
            "OPENAI_API_KEY": "secret-openai",
            "AWS_SECRET_ACCESS_KEY": "secret-aws",
            "GITHUB_TOKEN": "secret-github",
            "DATABASE_URL": "postgres://secret",
            "MURMUR_CODEX_PATH": "/tmp/codex"
        ])

        XCTAssertEqual(clean["HOME"], "/Users/example")
        XCTAssertEqual(clean["CODEX_HOME"], "/Users/example/.codex")
        XCTAssertEqual(clean["LC_CTYPE"], "UTF-8")
        XCTAssertEqual(clean["NO_COLOR"], "1")
        XCTAssertEqual(clean["TERM"], "dumb")
        XCTAssertNil(clean["OPENAI_API_KEY"])
        XCTAssertNil(clean["AWS_SECRET_ACCESS_KEY"])
        XCTAssertNil(clean["GITHUB_TOKEN"])
        XCTAssertNil(clean["DATABASE_URL"])
        XCTAssertNil(clean["MURMUR_CODEX_PATH"])
    }

    func testTurnPayloadUsesCurrentReadOnlyNoNetworkContract() {
        let configuration = CodexTurnConfiguration(
            threadID: "thread-1",
            workspace: URL(fileURLWithPath: "/repo"),
            prompt: "Find the retry policy",
            model: "gpt-5.6-terra",
            reasoningEffort: "low",
            outputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("cues")])
            ])
        )

        let payload = CodexAppServerMessages.turnStart(configuration, workspace: "/repo")

        XCTAssertEqual(payload["approvalPolicy"], .string("never"))
        XCTAssertEqual(payload["cwd"], .string("/repo"))
        XCTAssertEqual(payload["runtimeWorkspaceRoots"], .array([.string("/repo")]))
        XCTAssertEqual(payload["sandboxPolicy"]?["type"], .string("readOnly"))
        XCTAssertEqual(payload["sandboxPolicy"]?["networkAccess"], .bool(false))
        XCTAssertEqual(payload["input"]?[0]?["text"], .string("Find the retry policy"))
        XCTAssertNotNil(payload["outputSchema"])
    }

    func testRuntimeCanBeReplacedByDeterministicFake() async throws {
        let fake: any CodexAppServerRuntime = FakeCodexAppServerRuntime()
        try await fake.start()

        let models = try await fake.listModels()
        let inventory = try await fake.listSkills(
            in: URL(fileURLWithPath: "/tmp/workspace"),
            forceReload: false
        )
        let thread = try await fake.startThread(CodexThreadConfiguration(
            workspace: URL(fileURLWithPath: "/tmp/workspace")
        ))
        let turn = try await fake.startTurn(CodexTurnConfiguration(
            threadID: thread.id,
            workspace: URL(fileURLWithPath: "/tmp/workspace"),
            prompt: "Where is auth handled?"
        ))
        try await fake.interrupt(threadID: thread.id, turnID: turn.id)
        await fake.stop()

        XCTAssertEqual(models.first?.model, "fake-model")
        XCTAssertEqual(inventory.skills.first?.name, "fake-skill")
        XCTAssertEqual(thread.id, "fake-thread")
        XCTAssertEqual(turn.id, "fake-turn")
    }

    private func decodeJSON(_ source: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8))
    }
}

private actor FakeCodexAppServerRuntime: CodexAppServerRuntime {
    nonisolated let events: AsyncStream<CodexAppServerEvent>

    init() {
        events = AsyncStream { continuation in continuation.finish() }
    }

    func start() async throws {}

    func listModels() async throws -> [CodexModel] {
        [CodexModel(
            id: "fake-id",
            model: "fake-model",
            displayName: "Fake",
            description: "Deterministic test model",
            isDefault: true,
            hidden: false,
            defaultReasoningEffort: "low"
        )]
    }

    func listSkills(in workspace: URL, forceReload: Bool) async throws -> CodexSkillsInventory {
        CodexSkillsInventory(skills: [CodexSkill(
            workspace: workspace.path,
            name: "fake-skill",
            description: "A deterministic fake",
            enabled: true,
            path: workspace.appendingPathComponent("SKILL.md").path,
            scope: "repo"
        )], errors: [])
    }

    func startThread(_ configuration: CodexThreadConfiguration) async throws -> CodexThread {
        CodexThread(id: "fake-thread", model: "fake-model", workspace: configuration.workspace.path)
    }

    func startTurn(_ configuration: CodexTurnConfiguration) async throws -> CodexTurn {
        CodexTurn(id: "fake-turn", status: "inProgress")
    }

    func interrupt(threadID: String, turnID: String) async throws {}
    func stop() async {}
}

private extension JSONValue {
    subscript(index: Int) -> JSONValue? {
        guard case .array(let array) = self, array.indices.contains(index) else { return nil }
        return array[index]
    }
}
