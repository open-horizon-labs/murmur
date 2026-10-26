import Foundation

/// Platform-neutral secret storage for the transcription API key.
/// The macOS app supplies a Keychain implementation; other platforms supply their own.
public protocol TranscriptionCredentialStore {
    func load() throws -> String?
    func save(_ apiKey: String) throws
    func delete() throws
}

public struct EmptyTranscriptionCredentialStore: TranscriptionCredentialStore {
    public init() {}
    public func load() throws -> String? { nil }
    public func save(_ apiKey: String) throws {}
    public func delete() throws {}
}

public enum CredentialStoreError: LocalizedError {
    case emptyCredential

    public var errorDescription: String? {
        switch self {
        case .emptyCredential: "Enter an API key first."
        }
    }
}
