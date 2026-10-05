import Foundation

enum AudioSourceMode: String, CaseIterable, Identifiable, Sendable {
    case system = "Mac audio"
    case microphone = "Microphone"
    case both = "Both"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .system: "speaker.wave.2"
        case .microphone: "mic"
        case .both: "waveform.badge.mic"
        }
    }

    var capturesSystemAudio: Bool { self != .microphone }
    var capturesMicrophone: Bool { self != .system }
}

enum TranscriptionModel: String, CaseIterable, Identifiable, Sendable {
    case live = "gpt-live-transcribe"
    case accurate = "gpt-transcribe"

    var id: Self { self }

    var title: String {
        switch self {
        case .live: "Live"
        case .accurate: "Accurate"
        }
    }

    var detail: String {
        switch self {
        case .live: "Lowest latency · words appear as you speak"
        case .accurate: "Higher accuracy · appears after each speech turn"
        }
    }
}

enum ListeningPhase: Equatable, Sendable {
    case idle
    case connecting
    case listening
    case failed(String)

    var isActive: Bool {
        self == .connecting || self == .listening
    }
}

enum AgentTier: String, CaseIterable, Sendable {
    case fast = "Fast"
    case medium = "Context"
    case deep = "Skill"

    var targetLatency: String {
        switch self {
        case .fast: "< 500 ms"
        case .medium: "2–5 s"
        case .deep: "10–60 s"
        }
    }
}

enum TierActivity: Equatable, Sendable {
    case idle
    case working
    case suggested(String)
    case completed(String)
    case failed(String)
}

struct AgentEvidence: Equatable, Sendable, Codable {
    let path: String
    let lineStart: Int?
    let lineEnd: Int?
    let excerpt: String
    let transcriptSessionID: String?
    let transcriptEntryID: String?

    init(path: String, lineStart: Int?, lineEnd: Int?, excerpt: String, transcriptSessionID: String? = nil, transcriptEntryID: String? = nil) {
        self.path = path
        self.lineStart = lineStart
        self.lineEnd = lineEnd
        self.excerpt = excerpt
        self.transcriptSessionID = transcriptSessionID
        self.transcriptEntryID = transcriptEntryID
    }

    var sourceLabel: String {
        if transcriptSessionID != nil, transcriptEntryID != nil { return "Transcript passage" }
        guard let lineStart else { return path }
        if let lineEnd, lineEnd != lineStart { return "\(path):\(lineStart)-\(lineEnd)" }
        return "\(path):\(lineStart)"
    }
}

struct AgentFinding: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let summary: String
    let evidence: [AgentEvidence]
    let confidence: Double
    let skillsUsed: [String]
    let tier: AgentTier
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
