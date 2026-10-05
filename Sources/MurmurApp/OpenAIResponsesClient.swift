import Foundation

protocol ResponsesHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionResponsesTransport: ResponsesHTTPTransport {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 120
        session = URLSession(configuration: configuration)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw ResponsesClientError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < OpenAIResponsesClient.maxResponseBytes else { throw ResponsesClientError.responseTooLarge }
            data.append(byte)
        }
        return (data, http)
    }
}

enum ResponsesClientError: Error, LocalizedError, Sendable {
    case invalidResponse
    case responseTooLarge
    case provider(status: Int, message: String)
    case malformedResponse
    case refused
    case incomplete(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "OpenAI returned an invalid response."
        case .responseTooLarge: "OpenAI's response exceeded Murmur's size limit."
        case .provider(_, let message): message
        case .malformedResponse: "OpenAI returned a response Murmur could not read."
        case .refused: "OpenAI declined this request."
        case .incomplete(let reason): "OpenAI could not finish the response: \(reason)"
        }
    }
}

struct OpenAIResponsesClient: Sendable {
    static let maxResponseBytes = 1_000_000
    private let transport: any ResponsesHTTPTransport
    private let baseURL: URL

    init(transport: any ResponsesHTTPTransport = URLSessionResponsesTransport(), baseURL: URL = URL(string: "https://api.openai.com/v1")!) {
        self.transport = transport
        self.baseURL = baseURL
    }

    func listModels(apiKey: String) async throws -> [CodexModel] {
        let data = try await send(path: "models", apiKey: apiKey, body: nil)
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .array(let items)? = root["data"] else { throw ResponsesClientError.malformedResponse }
        return items.compactMap { item in
            guard let id = item["id"]?.stringValue else { return nil }
            return CodexModel(id: id, model: id, displayName: id, description: "", isDefault: false, hidden: false, defaultReasoningEffort: "")
        }.sorted { $0.model.localizedStandardCompare($1.model) == .orderedAscending }
    }

    func createResponse(apiKey: String, payload: JSONValue) async throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let body = try? encoder.encode(payload) else { throw ResponsesClientError.malformedResponse }
        let data = try await send(path: "responses", apiKey: apiKey, body: body)
        guard let response = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw ResponsesClientError.malformedResponse }
        return response
    }

    private func send(path: String, apiKey: String, body: Data?) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.timeoutInterval = 120
        let (data, response) = try await transport.data(for: request)
        guard data.count <= Self.maxResponseBytes else { throw ResponsesClientError.responseTooLarge }
        guard (200..<300).contains(response.statusCode) else {
            let message: String
            switch response.statusCode {
            case 401, 403: message = "OpenAI did not accept the API key or its permissions."
            case 429: message = "OpenAI rate limited the request or the account has reached its current limit."
            default: message = "OpenAI rejected the selected model or request (HTTP \(response.statusCode))."
            }
            throw ResponsesClientError.provider(status: response.statusCode, message: message)
        }
        return data
    }
}
