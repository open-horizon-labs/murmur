import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct LLMError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Endpoint settings for an OpenAI-compatible chat API (Mercury by default). No secret lives here.
public struct LLMConfig: Sendable, Equatable {
    public var provider = "mercury"
    public var baseURL = "https://api.inceptionlabs.ai/v1"
    public var model = "mercury-2"
    public var reasoningEffort: String? = "low"
    public var keyEnv = "INCEPTION_API_KEY"
    public var keyCommand: [String] = []
    public var timeout: Double = 60

    public init() {}
    public init(provider: String, baseURL: String, model: String, reasoningEffort: String?, keyEnv: String, keyCommand: [String] = [], timeout: Double = 60) {
        self.provider = provider; self.baseURL = baseURL; self.model = model
        self.reasoningEffort = reasoningEffort; self.keyEnv = keyEnv; self.keyCommand = keyCommand; self.timeout = timeout
    }
}

/// What the Context agent needs from a chat model.
public protocol LiveChat: Sendable {
    var label: String { get }
    func complete(messages: [JSONValue], tools: JSONValue?, maxTokens: Int) async throws -> JSONValue
}

extension LiveChat {
    public func complete(messages: [JSONValue], tools: JSONValue? = nil) async throws -> JSONValue {
        try await complete(messages: messages, tools: tools, maxTokens: 4000)
    }
}

/// Chat client for OpenAI-compatible endpoints. The key comes from `LiveKeys.resolve`.
public struct ChatClient: LiveChat {
    public let config: LLMConfig
    private let transport: any ResponsesHTTPTransport
    private let env: [String: String]?
    private let sleep: @Sendable (Double) async -> Void

    public init(
        _ config: LLMConfig,
        transport: any ResponsesHTTPTransport = URLSessionResponsesTransport(),
        env: [String: String]? = nil,
        sleep: @escaping @Sendable (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) {
        self.config = config
        self.transport = transport
        self.env = env
        self.sleep = sleep
    }

    public var label: String { "\(config.provider):\(config.model)" }

    public func complete(messages: [JSONValue], tools: JSONValue? = nil, maxTokens: Int = 4000) async throws -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(config.model), "messages": .array(messages),
            "max_tokens": JSONValue(maxTokens), "temperature": 0.2
        ]
        if let effort = config.reasoningEffort, !effort.isEmpty {
            body["reasoning_effort"] = .string(effort)   // Mercury 2 counts reasoning against max_tokens
        }
        if let tools, !(tools.arrayValue?.isEmpty ?? true) { body["tools"] = tools }
        let key = try LiveKeys.resolve(keyEnv: config.keyEnv, keyCommand: config.keyCommand, env: env)
        guard let url = URL(string: config.baseURL.trimmingTrailingSlashes + "/chat/completions") else {
            throw LLMError("model request failed (invalid base URL)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = JSONValue.object(body).jsonText.data(using: .utf8)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = config.timeout
        for attempt in 0..<2 {
            do {
                let (data, response) = try await transport.data(for: request)
                if !(200..<300).contains(response.statusCode) {
                    if [429, 500, 502, 503, 504].contains(response.statusCode) && attempt == 0 {
                        await sleep(1.0)
                        continue
                    }
                    throw LLMError("model request failed (HTTP \(response.statusCode))")
                }
                guard let message = JSONValue.parse(data)?["choices"]?.arrayValue?.first?["message"] else {
                    throw LLMError("model request failed (malformed reply)")
                }
                return message
            } catch let error as LLMError {
                throw error
            } catch {
                if attempt == 0 { await sleep(1.0); continue }
                throw LLMError("model request failed (\(type(of: error)))")
            }
        }
        throw LLMError("model request failed")
    }
}

extension String {
    var trimmingTrailingSlashes: String {
        var text = self
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }
}
