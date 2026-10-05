import Foundation

struct ContextRunLimits: Codable, Equatable, Sendable {
    static let preferenceKey = "contextRunLimits"
    static let defaults = ContextRunLimits()
    static let roundRange = 1...100
    static let callRange = 1...1_000
    static let timeoutRange = 30...1_800

    var lookupRounds = 30
    var toolCalls = 120
    var timeoutSeconds = 300

    var isValid: Bool {
        Self.roundRange.contains(lookupRounds)
            && Self.callRange.contains(toolCalls)
            && Self.timeoutRange.contains(timeoutSeconds)
    }

    var validated: Self { isValid ? self : Self.defaults }

    static func load(from preferences: UserDefaults) -> Self {
        guard let data = preferences.data(forKey: preferenceKey),
              let limits = try? JSONDecoder().decode(Self.self, from: data) else { return .defaults }
        return limits.validated
    }
}
