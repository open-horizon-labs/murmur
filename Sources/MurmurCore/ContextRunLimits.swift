import Foundation

public struct ContextRunLimits: Codable, Equatable, Sendable {
    public static let preferenceKey = "contextRunLimits"
    public static let defaults = ContextRunLimits()
    public static let roundRange = 1...100
    public static let callRange = 1...1_000
    public static let timeoutRange = 30...1_800

    public var lookupRounds = 30
    public var toolCalls = 120
    public var timeoutSeconds = 300

    public init(lookupRounds: Int = 30, toolCalls: Int = 120, timeoutSeconds: Int = 300) {
        self.lookupRounds = lookupRounds
        self.toolCalls = toolCalls
        self.timeoutSeconds = timeoutSeconds
    }

    public var isValid: Bool {
        Self.roundRange.contains(lookupRounds)
            && Self.callRange.contains(toolCalls)
            && Self.timeoutRange.contains(timeoutSeconds)
    }

    public var validated: Self { isValid ? self : Self.defaults }

    public static func load(from preferences: UserDefaults) -> Self {
        guard let data = preferences.data(forKey: preferenceKey),
              let limits = try? JSONDecoder().decode(Self.self, from: data) else { return .defaults }
        return limits.validated
    }
}
