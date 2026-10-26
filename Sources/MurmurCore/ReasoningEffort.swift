import Foundation

/// API effort values, not a model compatibility catalog.
public enum ReasoningEffort: String, CaseIterable, Sendable {
    case modelDefault, none, minimal, low, medium, high, xhigh, max

    public static let contextPreferenceKey = "contextReasoningEffort"
    public static let investigationPreferenceKey = "investigationReasoningEffort"

    public var label: String {
        switch self {
        case .modelDefault: "Model default"
        case .none: "None"
        case .minimal: "Minimal"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra high"
        case .max: "Maximum"
        }
    }

    public static func load(from preferences: UserDefaults, key: String) -> Self {
        preferences.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .modelDefault
    }
}
