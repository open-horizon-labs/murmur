import Foundation

// MARK: - Runtime surface

protocol CodexAppServerRuntime: Sendable {
    var events: AsyncStream<CodexAppServerEvent> { get }

    func start() async throws
    func listModels() async throws -> [CodexModel]
    func listSkills(in workspace: URL, forceReload: Bool) async throws -> CodexSkillsInventory
    func startThread(_ configuration: CodexThreadConfiguration) async throws -> CodexThread
    func startTurn(_ configuration: CodexTurnConfiguration) async throws -> CodexTurn
    func interrupt(threadID: String, turnID: String) async throws
    func stop() async
}

struct CodexModel: Equatable, Sendable {
    let id: String
    let model: String
    let displayName: String
    let description: String
    let isDefault: Bool
    let hidden: Bool
    let defaultReasoningEffort: String
}

struct CodexSkill: Equatable, Sendable {
    let workspace: String
    let name: String
    let description: String
    let enabled: Bool
    let path: String
    let scope: String
}

struct CodexSkillLoadError: Equatable, Sendable {
    let workspace: String
    let path: String
    let message: String
}

struct CodexSkillsInventory: Equatable, Sendable {
    let skills: [CodexSkill]
    let errors: [CodexSkillLoadError]
}

struct CodexThreadConfiguration: Equatable, Sendable {
    let workspace: URL
    let model: String?
    let baseInstructions: String?
    let developerInstructions: String?
    let ephemeral: Bool

    init(
        workspace: URL,
        model: String? = nil,
        baseInstructions: String? = nil,
        developerInstructions: String? = nil,
        ephemeral: Bool = true
    ) {
        self.workspace = workspace
        self.model = model
        self.baseInstructions = baseInstructions
        self.developerInstructions = developerInstructions
        self.ephemeral = ephemeral
    }
}

struct CodexTurnConfiguration: Equatable, Sendable {
    let threadID: String
    let workspace: URL
    let prompt: String
    let model: String?
    let reasoningEffort: String?
    let outputSchema: JSONValue?

    init(
        threadID: String,
        workspace: URL,
        prompt: String,
        model: String? = nil,
        reasoningEffort: String? = nil,
        outputSchema: JSONValue? = nil
    ) {
        self.threadID = threadID
        self.workspace = workspace
        self.prompt = prompt
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.outputSchema = outputSchema
    }
}

struct CodexThread: Equatable, Sendable {
    let id: String
    let model: String
    let workspace: String
}

struct CodexTurn: Equatable, Sendable {
    let id: String
    let status: String
}

struct CodexCollabAgentCall: Equatable, Sendable {
    let id: String
    let tool: String
    let status: String
    let senderThreadID: String
    let receiverThreadIDs: [String]
    let prompt: String?
    let model: String?
    let reasoningEffort: String?
    let agentStates: [String: String]
}

enum CodexAppServerEvent: Equatable, Sendable {
    case turnStarted(threadID: String, turnID: String)
    case turnCompleted(threadID: String, turnID: String, status: String)
    case agentMessageDelta(threadID: String, turnID: String, delta: String)
    case collabAgentCall(CodexCollabAgentCall)
    case skillsChanged
    case notification(method: String, params: JSONValue?)
    case terminated(String)
}

enum CodexAppServerError: LocalizedError, Equatable, Sendable {
    case executableNotFound
    case alreadyRunning
    case notRunning
    case processLaunch(String)
    case transportClosed(String)
    case requestTimedOut(String)
    case malformedMessage(String)
    case rpc(code: Int, message: String)
    case unexpectedResponse(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "Could not find an executable Codex CLI."
        case .alreadyRunning:
            "The Codex App Server is already running."
        case .notRunning:
            "The Codex App Server is not running."
        case .processLaunch(let message):
            "Could not launch Codex App Server: \(message)"
        case .transportClosed(let message):
            "Codex App Server transport closed: \(message)"
        case .requestTimedOut(let method):
            "Codex App Server request timed out: \(method)"
        case .malformedMessage(let message):
            "Codex App Server returned malformed JSON: \(message)"
        case .rpc(let code, let message):
            "Codex App Server error \(code): \(message)"
        case .unexpectedResponse(let message):
            "Unexpected Codex App Server response: \(message)"
        }
    }
}

// MARK: - Persistent stdio client

actor CodexAppServerClient: CodexAppServerRuntime {
    nonisolated let events: AsyncStream<CodexAppServerEvent>

    private let executableURL: URL
    private let childEnvironment: [String: String]
    private let requestTimeout: Duration
    private let eventContinuation: AsyncStream<CodexAppServerEvent>.Continuation
    private var process: Process?
    private var processGeneration: UUID?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var framer = JSONLineFramer()
    private var nextRequestID: Int64 = 1
    private var pending: [Int64: CheckedContinuation<JSONValue, Error>] = [:]
    private var requestTimeouts: [Int64: Task<Void, Never>] = [:]

    init(
        executableURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        requestTimeout: Duration = .seconds(30)
    ) throws {
        self.executableURL = try executableURL ?? CodexExecutableLocator.locate(environment: environment)
        self.childEnvironment = CodexChildEnvironment.sanitize(
            environment,
            executableURL: self.executableURL
        )
        self.requestTimeout = requestTimeout
        let pair = AsyncStream.makeStream(of: CodexAppServerEvent.self)
        self.events = pair.stream
        self.eventContinuation = pair.continuation
    }

    func start() async throws {
        guard process == nil else { throw CodexAppServerError.alreadyRunning }

        let process = Process()
        let launchGeneration = UUID()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]
        process.environment = childEnvironment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.receive(data, generation: launchGeneration) }
        }
        // Always drain stderr so a verbose child cannot deadlock. It is intentionally
        // not surfaced because diagnostics can contain workspace or account details.
        errors.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        process.terminationHandler = { [weak self] process in
            Task { await self?.processTerminated(status: process.terminationStatus, generation: launchGeneration) }
        }

        // Publish the process and handles before launch so an immediate child exit
        // cannot race past termination cleanup and leave requests hanging.
        self.process = process
        processGeneration = launchGeneration
        inputHandle = input.fileHandleForWriting
        outputHandle = output.fileHandleForReading
        errorHandle = errors.fileHandleForReading

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            self.process = nil
            processGeneration = nil
            inputHandle = nil
            outputHandle = nil
            errorHandle = nil
            throw CodexAppServerError.processLaunch(error.localizedDescription)
        }

        do {
            _ = try await request(
                method: "initialize",
                params: .object([
                    "clientInfo": .object([
                        "name": .string("murmur"),
                        "title": .string("Murmur"),
                        "version": .string("0.1.0")
                    ]),
                    "capabilities": .object(["experimentalApi": .bool(true)])
                ])
            )
            guard processGeneration == launchGeneration else {
                throw CodexAppServerError.transportClosed("process exited during initialization")
            }
            try sendNotification(method: "initialized")
        } catch {
            if processGeneration == launchGeneration { await stop() }
            throw error
        }
    }

    func listModels() async throws -> [CodexModel] {
        let result = try await request(
            method: "model/list",
            params: .object(["includeHidden": .bool(false)])
        )
        guard case .array(let rows)? = result["data"] else {
            throw CodexAppServerError.unexpectedResponse("model/list had no data array")
        }
        return try rows.map(CodexProtocolDecoder.model)
    }

    func listSkills(in workspace: URL, forceReload: Bool = false) async throws -> CodexSkillsInventory {
        let path = try canonicalWorkspacePath(workspace)
        let result = try await request(
            method: "skills/list",
            params: .object([
                "cwds": .array([.string(path)]),
                "forceReload": .bool(forceReload)
            ])
        )
        return try CodexProtocolDecoder.skillsInventory(result)
    }

    func startThread(_ configuration: CodexThreadConfiguration) async throws -> CodexThread {
        let workspace = try canonicalWorkspacePath(configuration.workspace)
        let params = CodexAppServerMessages.threadStart(configuration, workspace: workspace)
        let result = try await request(method: "thread/start", params: params)
        guard
            let id = result["thread"]?["id"]?.stringValue,
            let model = result["model"]?.stringValue
        else {
            throw CodexAppServerError.unexpectedResponse("thread/start omitted thread.id or model")
        }
        return CodexThread(id: id, model: model, workspace: result["cwd"]?.stringValue ?? workspace)
    }

    func startTurn(_ configuration: CodexTurnConfiguration) async throws -> CodexTurn {
        let workspace = try canonicalWorkspacePath(configuration.workspace)
        let params = CodexAppServerMessages.turnStart(configuration, workspace: workspace)
        let result = try await request(method: "turn/start", params: params)
        guard let id = result["turn"]?["id"]?.stringValue else {
            throw CodexAppServerError.unexpectedResponse("turn/start omitted turn.id")
        }
        return CodexTurn(id: id, status: result["turn"]?["status"]?.stringValue ?? "inProgress")
    }

    func interrupt(threadID: String, turnID: String) async throws {
        _ = try await request(
            method: "turn/interrupt",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID)
            ])
        )
    }

    func stop() async {
        processGeneration = nil
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        inputHandle?.closeFile()
        if let process, process.isRunning {
            process.terminate()
        }
        finishPending(with: CodexAppServerError.transportClosed("client stopped"))
        inputHandle = nil
        outputHandle = nil
        errorHandle = nil
        process = nil
        framer = JSONLineFramer()
    }

    private func request(method: String, params: JSONValue) async throws -> JSONValue {
        guard inputHandle != nil else { throw CodexAppServerError.notRunning }
        let requestID = nextRequestID
        nextRequestID += 1
        let message: JSONValue = .object([
            "id": .number(Double(requestID)),
            "method": .string(method),
            "params": params
        ])

        return try await withCheckedThrowingContinuation { continuation in
            pending[requestID] = continuation
            let timeout = requestTimeout
            requestTimeouts[requestID] = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                await self?.expireRequest(requestID, method: method)
            }
            do {
                try write(message)
            } catch {
                pending.removeValue(forKey: requestID)
                requestTimeouts.removeValue(forKey: requestID)?.cancel()
                continuation.resume(throwing: error)
            }
        }
    }

    private func sendNotification(method: String, params: JSONValue? = nil) throws {
        var object: [String: JSONValue] = ["method": .string(method)]
        if let params { object["params"] = params }
        try write(.object(object))
    }

    private func write(_ message: JSONValue) throws {
        guard let inputHandle else { throw CodexAppServerError.notRunning }
        var data = try JSONEncoder().encode(message)
        data.append(0x0A)
        do {
            try inputHandle.write(contentsOf: data)
        } catch {
            throw CodexAppServerError.transportClosed(error.localizedDescription)
        }
    }

    private func receive(_ data: Data, generation expectedGeneration: UUID) {
        guard processGeneration == expectedGeneration else { return }
        if data.isEmpty {
            for trailing in framer.finish() { consume(line: trailing) }
            processTerminated(status: process?.terminationStatus ?? -1, generation: expectedGeneration)
            return
        }
        for line in framer.append(data) { consume(line: line) }
    }

    private func consume(line: Data) {
        let message: JSONValue
        do {
            message = try JSONDecoder().decode(JSONValue.self, from: line)
        } catch {
            eventContinuation.yield(.notification(
                method: "transport/malformedMessage",
                params: .string(error.localizedDescription)
            ))
            return
        }

        if let id = message["id"]?.integerValue, message["result"] != nil || message["error"] != nil {
            guard let continuation = pending.removeValue(forKey: id) else { return }
            requestTimeouts.removeValue(forKey: id)?.cancel()
            if let error = message["error"] {
                continuation.resume(throwing: CodexAppServerError.rpc(
                    code: error["code"]?.integerValue.map(Int.init) ?? -1,
                    message: error["message"]?.stringValue ?? "Unknown error"
                ))
            } else {
                continuation.resume(returning: message["result"] ?? .null)
            }
            return
        }

        if let method = message["method"]?.stringValue {
            // Server-to-client requests are rejected rather than left hanging. Ambient
            // turns use approvalPolicy=never, so Murmur should never receive one.
            if let id = message["id"] {
                try? write(.object([
                    "id": id,
                    "error": .object([
                        "code": .number(-32601),
                        "message": .string("Murmur does not accept server requests")
                    ])
                ]))
                return
            }
            eventContinuation.yield(CodexProtocolDecoder.event(
                method: method,
                params: message["params"]
            ))
        }
    }

    private func processTerminated(status: Int32, generation expectedGeneration: UUID) {
        guard processGeneration == expectedGeneration, process != nil else { return }
        processGeneration = nil
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        finishPending(with: CodexAppServerError.transportClosed("process exited with status \(status)"))
        inputHandle = nil
        outputHandle = nil
        errorHandle = nil
        process = nil
        eventContinuation.yield(.terminated("Codex App Server exited with status \(status)"))
    }

    private func finishPending(with error: Error) {
        let continuations = Array(pending.values)
        pending.removeAll()
        for task in requestTimeouts.values { task.cancel() }
        requestTimeouts.removeAll()
        for continuation in continuations { continuation.resume(throwing: error) }
    }

    private func expireRequest(_ requestID: Int64, method: String) {
        guard let continuation = pending.removeValue(forKey: requestID) else { return }
        requestTimeouts.removeValue(forKey: requestID)?.cancel()
        continuation.resume(throwing: CodexAppServerError.requestTimedOut(method))
    }

    private func canonicalWorkspacePath(_ url: URL) throws -> String {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard
            canonical.isFileURL,
            FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw CodexAppServerError.unexpectedResponse("Workspace must be an existing local folder")
        }
        return canonical.path
    }
}

// MARK: - Protocol payloads and decoding

enum CodexAppServerMessages {
    static func threadStart(_ configuration: CodexThreadConfiguration, workspace: String) -> JSONValue {
        var params: [String: JSONValue] = [
            "cwd": .string(workspace),
            "runtimeWorkspaceRoots": .array([.string(workspace)]),
            "approvalPolicy": .string("never"),
            "sandbox": .string("read-only"),
            "ephemeral": .bool(configuration.ephemeral)
        ]
        if let model = configuration.model { params["model"] = .string(model) }
        if let value = configuration.baseInstructions { params["baseInstructions"] = .string(value) }
        if let value = configuration.developerInstructions { params["developerInstructions"] = .string(value) }
        return .object(params)
    }

    static func turnStart(_ configuration: CodexTurnConfiguration, workspace: String) -> JSONValue {
        var params: [String: JSONValue] = [
            "threadId": .string(configuration.threadID),
            "cwd": .string(workspace),
            "runtimeWorkspaceRoots": .array([.string(workspace)]),
            "input": .array([.object([
                "type": .string("text"),
                "text": .string(configuration.prompt)
            ])]),
            "approvalPolicy": .string("never"),
            "sandboxPolicy": .object([
                "type": .string("readOnly"),
                "networkAccess": .bool(false)
            ])
        ]
        if let model = configuration.model { params["model"] = .string(model) }
        if let effort = configuration.reasoningEffort { params["effort"] = .string(effort) }
        if let schema = configuration.outputSchema { params["outputSchema"] = schema }
        return .object(params)
    }
}

enum CodexProtocolDecoder {
    static func model(_ value: JSONValue) throws -> CodexModel {
        guard
            let id = value["id"]?.stringValue,
            let model = value["model"]?.stringValue,
            let displayName = value["displayName"]?.stringValue
        else { throw CodexAppServerError.unexpectedResponse("Malformed model/list entry") }
        return CodexModel(
            id: id,
            model: model,
            displayName: displayName,
            description: value["description"]?.stringValue ?? "",
            isDefault: value["isDefault"]?.boolValue ?? false,
            hidden: value["hidden"]?.boolValue ?? false,
            defaultReasoningEffort: value["defaultReasoningEffort"]?.stringValue ?? "medium"
        )
    }

    static func skillsInventory(_ value: JSONValue) throws -> CodexSkillsInventory {
        guard case .array(let groups)? = value["data"] else {
            throw CodexAppServerError.unexpectedResponse("skills/list had no data array")
        }
        var skills: [CodexSkill] = []
        var errors: [CodexSkillLoadError] = []
        for group in groups {
            let workspace = group["cwd"]?.stringValue ?? ""
            if case .array(let rows)? = group["skills"] {
                skills += rows.compactMap { row in
                    guard let name = row["name"]?.stringValue, let path = row["path"]?.stringValue else {
                        return nil
                    }
                    return CodexSkill(
                        workspace: workspace,
                        name: name,
                        description: row["description"]?.stringValue ?? "",
                        enabled: row["enabled"]?.boolValue ?? false,
                        path: path,
                        scope: row["scope"]?.stringValue ?? "user"
                    )
                }
            }
            if case .array(let rows)? = group["errors"] {
                errors += rows.compactMap { row in
                    guard let path = row["path"]?.stringValue, let message = row["message"]?.stringValue else {
                        return nil
                    }
                    return CodexSkillLoadError(workspace: workspace, path: path, message: message)
                }
            }
        }
        return CodexSkillsInventory(skills: skills, errors: errors)
    }

    static func event(method: String, params: JSONValue?) -> CodexAppServerEvent {
        switch method {
        case "turn/started":
            if let threadID = params?["threadId"]?.stringValue,
               let turnID = params?["turn"]?["id"]?.stringValue {
                return .turnStarted(threadID: threadID, turnID: turnID)
            }
        case "turn/completed":
            if let threadID = params?["threadId"]?.stringValue,
               let turnID = params?["turn"]?["id"]?.stringValue {
                return .turnCompleted(
                    threadID: threadID,
                    turnID: turnID,
                    status: params?["turn"]?["status"]?.stringValue ?? "completed"
                )
            }
        case "item/agentMessage/delta":
            if let threadID = params?["threadId"]?.stringValue,
               let turnID = params?["turnId"]?.stringValue,
               let delta = params?["delta"]?.stringValue {
                return .agentMessageDelta(threadID: threadID, turnID: turnID, delta: delta)
            }
        case "item/started", "item/completed":
            if let item = params?["item"], item["type"]?.stringValue == "collabAgentToolCall",
               let call = collabAgentCall(item) {
                return .collabAgentCall(call)
            }
        case "skills/changed":
            return .skillsChanged
        default:
            break
        }
        return .notification(method: method, params: params)
    }

    private static func collabAgentCall(_ item: JSONValue) -> CodexCollabAgentCall? {
        guard
            let id = item["id"]?.stringValue,
            let tool = item["tool"]?.stringValue,
            let status = item["status"]?.stringValue,
            let sender = item["senderThreadId"]?.stringValue,
            case .array(let receiverValues)? = item["receiverThreadIds"]
        else { return nil }

        let receivers = receiverValues.compactMap(\.stringValue)
        var states: [String: String] = [:]
        if case .object(let values)? = item["agentsStates"] {
            for (threadID, state) in values {
                if let status = state["status"]?.stringValue { states[threadID] = status }
            }
        }
        return CodexCollabAgentCall(
            id: id,
            tool: tool,
            status: status,
            senderThreadID: sender,
            receiverThreadIDs: receivers,
            prompt: item["prompt"]?.stringValue,
            model: item["model"]?.stringValue,
            reasoningEffort: item["reasoningEffort"]?.stringValue,
            agentStates: states
        )
    }
}

// MARK: - Process isolation

enum CodexExecutableLocator {
    static func locate(
        environment: [String: String],
        fixedCandidates: [String]? = nil
    ) throws -> URL {
        let fileManager = FileManager.default
        var candidates: [String] = []
        if let override = environment["MURMUR_CODEX_PATH"], !override.isEmpty {
            candidates.append(override)
        }
        let home = environment["HOME"] ?? NSHomeDirectory()
        candidates += fixedCandidates ?? [
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "\(home)/.asdf/shims/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.bun/bin/codex"
        ]
        candidates += (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { String($0) + "/codex" }

        for candidate in candidates {
            let url = URL(fileURLWithPath: candidate).standardizedFileURL
            if fileManager.isExecutableFile(atPath: url.path) { return url }
        }
        throw CodexAppServerError.executableNotFound
    }
}

enum CodexChildEnvironment {
    private static let allowedNames: Set<String> = [
        "HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG", "LC_ALL",
        "SHELL", "XDG_CONFIG_HOME", "CODEX_HOME"
    ]

    static func sanitize(
        _ environment: [String: String],
        executableURL: URL? = nil
    ) -> [String: String] {
        var clean = environment.filter { key, _ in
            allowedNames.contains(key) || key.hasPrefix("LC_")
        }
        let home = environment["HOME"] ?? NSHomeDirectory()
        var paths: [String] = []
        if let executableURL {
            paths.append(executableURL.deletingLastPathComponent().path)
        }
        paths += [
            "\(home)/.asdf/shims",
            "\(home)/.local/bin",
            "\(home)/.bun/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        paths += (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        var seen = Set<String>()
        clean["PATH"] = paths.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
        clean["NO_COLOR"] = "1"
        clean["TERM"] = "dumb"
        return clean
    }
}

// MARK: - JSONL framing and dynamic JSON

struct JSONLineFramer: Sendable {
    private var buffer = Data()

    mutating func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line.last == 0x0D { line.removeLast() }
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }

    mutating func finish() -> [Data] {
        guard !buffer.isEmpty else { return [] }
        var line = buffer
        buffer.removeAll(keepingCapacity: false)
        if line.last == 0x0D { line.removeLast() }
        return line.isEmpty ? [] : [line]
    }
}

indirect enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var integerValue: Int64? {
        guard case .number(let value) = self, value.rounded() == value else { return nil }
        return Int64(exactly: value)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value):
            if value.rounded() == value, let integer = Int64(exactly: value) {
                try container.encode(integer)
            } else {
                try container.encode(value)
            }
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}
