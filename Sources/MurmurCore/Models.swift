import Foundation

public enum AudioSourceMode: String, CaseIterable, Identifiable, Sendable {
    case system = "Mac audio"
    case microphone = "Microphone"
    case both = "Both"

    public var id: Self { self }

    public var systemImage: String {
        switch self {
        case .system: "speaker.wave.2"
        case .microphone: "mic"
        case .both: "waveform.badge.mic"
        }
    }

    public var capturesSystemAudio: Bool { self != .microphone }
    public var capturesMicrophone: Bool { self != .system }
}

public enum TranscriptionModel: String, CaseIterable, Identifiable, Sendable {
    case live = "gpt-live-transcribe"
    case accurate = "gpt-transcribe"

    public var id: Self { self }

    public var title: String {
        switch self {
        case .live: "Live"
        case .accurate: "Accurate"
        }
    }

    public var detail: String {
        switch self {
        case .live: "Lowest latency · words appear as you speak"
        case .accurate: "Higher accuracy · appears after each speech turn"
        }
    }
}

public enum ListeningPhase: Equatable, Sendable {
    case idle
    case connecting
    case listening
    case failed(String)

    public var isActive: Bool {
        self == .connecting || self == .listening
    }
}

public enum AgentTier: String, CaseIterable, Sendable {
    case fast = "Fast"
    case medium = "Context"
    case deep = "Skill"

    public var targetLatency: String {
        switch self {
        case .fast: "< 500 ms"
        case .medium: "2–5 s"
        case .deep: "10–60 s"
        }
    }
}

public enum TierActivity: Equatable, Sendable {
    case idle
    case working
    case suggested(String)
    case completed(String)
    case failed(String)
}

public struct AgentEvidence: Equatable, Sendable, Codable {
    public let path: String
    public let lineStart: Int?
    public let lineEnd: Int?
    public let excerpt: String
    public let transcriptSessionID: String?
    public let transcriptEntryID: String?

    public init(path: String, lineStart: Int?, lineEnd: Int?, excerpt: String, transcriptSessionID: String? = nil, transcriptEntryID: String? = nil) {
        self.path = path
        self.lineStart = lineStart
        self.lineEnd = lineEnd
        self.excerpt = excerpt
        self.transcriptSessionID = transcriptSessionID
        self.transcriptEntryID = transcriptEntryID
    }

    public var sourceLabel: String {
        if transcriptSessionID != nil, transcriptEntryID != nil { return "Transcript passage" }
        guard let lineStart else { return path }
        if let lineEnd, lineEnd != lineStart { return "\(path):\(lineStart)-\(lineEnd)" }
        return "\(path):\(lineStart)"
    }
}

public struct AgentFinding: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    public let evidence: [AgentEvidence]
    public let confidence: Double
    public let skillsUsed: [String]
    public let tier: AgentTier
}

struct WorkspaceDocument: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let source: String
    let body: String
    let url: URL
    let updatedAt: Date
}

struct Cue: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let source: String
    let url: URL
    let relevance: Double
    let tier: AgentTier
}

struct RoutingResult: Equatable, Sendable {
    let cues: [Cue]
    let medium: TierActivity
    let deep: TierActivity
}

enum TranscriptionEvent: Equatable, Sendable {
    case transportLost
    case recovering(attempt: Int, maximum: Int)
    case recovered
    case committed(itemID: String, previousItemID: String?)
    case partial(itemID: String, delta: String)
    case completed(itemID: String, text: String)
    case failed(String)
}
