import Foundation

protocol SessionStoring: Sendable {
    func save(_ record: SavedSession) async throws
    func load(id: UUID) async throws -> SessionLoadResult
    func list() async throws -> [SessionSummary]
    func delete(id: UUID) async throws
}

struct SavedTranscriptEntry: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let timestamp: Date
    let text: String
    let isFinal: Bool
    let wasInterrupted: Bool?

    init(id: String, timestamp: Date, text: String, isFinal: Bool, wasInterrupted: Bool? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
        self.isFinal = isFinal
        self.wasInterrupted = wasInterrupted
    }

    init(_ entry: TranscriptEntry) {
        self.init(id: entry.id, timestamp: entry.timestamp, text: entry.text, isFinal: entry.isFinal, wasInterrupted: entry.wasInterrupted)
    }

    var transcriptEntry: TranscriptEntry {
        TranscriptEntry(id: id, timestamp: timestamp, text: text, isFinal: isFinal, wasInterrupted: wasInterrupted)
    }
}

struct SavedFinding: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let summary: String
    let evidence: [AgentEvidence]
    let confidence: Double
    let skillsUsed: [String]
    let tier: String

    init(
        id: String,
        title: String,
        summary: String,
        evidence: [AgentEvidence],
        confidence: Double,
        skillsUsed: [String],
        tier: String
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.evidence = evidence
        self.confidence = confidence
        self.skillsUsed = skillsUsed
        self.tier = tier
    }

    init(_ finding: AgentFinding) {
        self.init(
            id: finding.id,
            title: finding.title,
            summary: finding.summary,
            evidence: finding.evidence,
            confidence: finding.confidence,
            skillsUsed: finding.skillsUsed,
            tier: finding.tier.rawValue
        )
    }

    var agentFinding: AgentFinding {
        AgentFinding(
            id: id,
            title: title,
            summary: summary,
            evidence: evidence,
            confidence: confidence,
            skillsUsed: skillsUsed,
            tier: AgentTier(rawValue: tier) ?? .medium
        )
    }
}

struct SavedInvestigation: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let selectionText: String
    let entryIDs: [String]
    let question: String
    let status: String
    let statusMessage: String?
    let finding: SavedFinding?
    let model: String?
    let createdAt: Date?

    init(
        id: UUID,
        selectionText: String,
        entryIDs: [String],
        question: String,
        status: String,
        statusMessage: String? = nil,
        finding: SavedFinding? = nil,
        model: String? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.selectionText = selectionText
        self.entryIDs = entryIDs
        self.question = question
        self.status = status
        self.statusMessage = statusMessage
        self.finding = finding
        self.model = model
        self.createdAt = createdAt
    }

    init(_ investigation: PassageInvestigation, model: String? = nil, createdAt: Date = Date()) {
        let state: (String, String?)
        switch investigation.activity {
        case .idle: state = ("idle", nil)
        case .working: state = ("working", nil)
        case .suggested(let message): state = ("suggested", message)
        case .completed(let message): state = ("completed", message)
        case .failed(let message): state = ("failed", message)
        }
        self.init(
            id: investigation.id,
            selectionText: investigation.selection.text,
            entryIDs: investigation.selection.entryIDs,
            question: investigation.question,
            status: state.0,
            statusMessage: state.1,
            finding: investigation.finding.map(SavedFinding.init),
            model: model,
            createdAt: createdAt
        )
    }

    var passageInvestigation: PassageInvestigation {
        let activity: TierActivity
        switch status {
        case "working": activity = .working
        case "suggested": activity = .suggested(statusMessage ?? "")
        case "completed": activity = .completed(statusMessage ?? finding?.title ?? "Completed")
        case "failed": activity = .failed(statusMessage ?? "Failed")
        default: activity = .idle
        }
        return PassageInvestigation(
            id: id,
            selection: TranscriptSelection(text: selectionText, entryIDs: entryIDs),
            question: question,
            activity: activity,
            finding: finding?.agentFinding
        )
    }
}

struct SavedSession: Codable, Sendable, Equatable, Identifiable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var id: UUID
    var revision: Int
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var workspacePath: String?
    var workspaceName: String
    var isDemo: Bool
    var sourceMode: String
    var transcriptionModel: String
    var contextModel: String
    var investigationModel: String
    var transcript: [SavedTranscriptEntry]
    var context: SavedFinding?
    var contextUpdatedAt: Date?
    var transcriptRevision: Int?
    var contextTranscriptRevision: Int?
    var contextFindingModel: String?
    var investigations: [SavedInvestigation]
    // Optional post-call fields keep older session files readable. The live
    // transcript remains in `transcript`; a batch-reviewed version is separate.
    var postCallTranscript: [SavedTranscriptEntry]?
    var postCallRevisionID: UUID?
    var postCallStatus: String?
    var postCallMessage: String?
    var postCallModel: String?
    var postCallKeepUntilReviewed: Bool?
    var postCallAudioExpiresAt: Date?
    var postCallRecordingIDs: [UUID]?
    var postCallLiveEntryIDs: [String]?
    var postCallHasCoverageGaps: Bool?

    init(
        schemaVersion: Int = currentSchemaVersion,
        id: UUID = UUID(),
        revision: Int = 1,
        title: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        workspacePath: String? = nil,
        workspaceName: String = "",
        isDemo: Bool = false,
        sourceMode: String = AudioSourceMode.microphone.rawValue,
        transcriptionModel: String = TranscriptionModel.live.rawValue,
        contextModel: String = "",
        investigationModel: String = "",
        transcript: [SavedTranscriptEntry] = [],
        context: SavedFinding? = nil,
        contextUpdatedAt: Date? = nil,
        transcriptRevision: Int? = nil,
        contextTranscriptRevision: Int? = nil,
        contextFindingModel: String? = nil,
        investigations: [SavedInvestigation] = [],
        postCallTranscript: [SavedTranscriptEntry]? = nil,
        postCallRevisionID: UUID? = nil,
        postCallStatus: String? = nil,
        postCallMessage: String? = nil,
        postCallModel: String? = nil,
        postCallKeepUntilReviewed: Bool? = nil,
        postCallAudioExpiresAt: Date? = nil,
        postCallRecordingIDs: [UUID]? = nil,
        postCallLiveEntryIDs: [String]? = nil,
        postCallHasCoverageGaps: Bool? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.revision = revision
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.workspacePath = workspacePath
        self.workspaceName = workspaceName
        self.isDemo = isDemo
        self.sourceMode = sourceMode
        self.transcriptionModel = transcriptionModel
        self.contextModel = contextModel
        self.investigationModel = investigationModel
        self.transcript = transcript
        self.context = context
        self.contextUpdatedAt = contextUpdatedAt
        self.transcriptRevision = transcriptRevision
        self.contextTranscriptRevision = contextTranscriptRevision
        self.contextFindingModel = contextFindingModel
        self.investigations = investigations
        self.postCallTranscript = postCallTranscript
        self.postCallRevisionID = postCallRevisionID
        self.postCallStatus = postCallStatus
        self.postCallMessage = postCallMessage
        self.postCallModel = postCallModel
        self.postCallKeepUntilReviewed = postCallKeepUntilReviewed
        self.postCallAudioExpiresAt = postCallAudioExpiresAt
        self.postCallRecordingIDs = postCallRecordingIDs
        self.postCallLiveEntryIDs = postCallLiveEntryIDs
        self.postCallHasCoverageGaps = postCallHasCoverageGaps
    }
}

struct SessionLoadResult: Sendable, Equatable {
    let session: SavedSession
    let recoveredFromBackup: Bool
}

public struct SessionSummary: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let title: String
    public let createdAt: Date
    public let updatedAt: Date
    public let preview: String
    public let isDemo: Bool
    public let available: Bool
    public let warning: String?

    public init(
        id: UUID,
        title: String,
        createdAt: Date,
        updatedAt: Date,
        preview: String,
        isDemo: Bool,
        available: Bool = true,
        warning: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.preview = preview
        self.isDemo = isDemo
        self.available = available
        self.warning = warning
    }
}

enum SessionStoreError: LocalizedError, Equatable, Sendable {
    case notFound(UUID)
    case deleted(UUID)
    case staleRevision(id: UUID, incoming: Int, latest: Int)
    case unsupportedSchemaVersion(id: UUID, version: Int)
    case corruptRecord(UUID)
    case recordIDMismatch(expected: UUID, actual: UUID)
    case invalidSchemaVersion(Int)

    var errorDescription: String? {
        switch self {
        case .notFound(let id): "No saved session exists for \(id)."
        case .deleted(let id): "Saved session \(id) was deleted."
        case .staleRevision(let id, let incoming, let latest):
            "Saved session \(id) revision \(incoming) is older than stored revision \(latest)."
        case .unsupportedSchemaVersion(let id, let version):
            "Saved session \(id) uses unsupported schema version \(version). Update Murmur before editing it."
        case .corruptRecord(let id): "Saved session \(id) and its backup could not be read."
        case .recordIDMismatch(let expected, let actual): "Saved session ID mismatch (expected \(expected), found \(actual))."
        case .invalidSchemaVersion(let version): "Cannot save unsupported session schema version \(version)."
        }
    }
}

actor LocalSessionStore: SessionStoring {
    private let directoryURL: URL
    private let fileRemover: @Sendable (URL) throws -> Void
    private var latestRevisions: [UUID: Int] = [:]
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        directoryURL: URL? = nil,
        fileRemover: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) {
        self.directoryURL = directoryURL ?? Self.defaultDirectoryURL()
        self.fileRemover = fileRemover
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = decoder
    }

    func save(_ record: SavedSession) async throws {
        guard record.schemaVersion == SavedSession.currentSchemaVersion else {
            throw SessionStoreError.invalidSchemaVersion(record.schemaVersion)
        }
        try prepareDirectory()
        let paths = paths(for: record.id)
        guard !FileManager.default.fileExists(atPath: paths.tombstone.path) else {
            throw SessionStoreError.deleted(record.id)
        }

        let current = try inspectFile(paths.primary, expectedID: record.id)
        let backup = try inspectFile(paths.backup, expectedID: record.id)
        let revisions = [latestRevisions[record.id], current.record?.revision, backup.record?.revision].compactMap { $0 }
        if let latest = revisions.max(), record.revision <= latest {
            throw SessionStoreError.staleRevision(id: record.id, incoming: record.revision, latest: latest)
        }

        // Rotate only a validated current file. If it is corrupt, preserve any good
        // backup as-is so recovery remains possible after this new primary is written.
        if let currentData = current.validData {
            try writeAtomically(currentData, to: paths.backup)
        }
        let data = try encoder.encode(record)
        try writeAtomically(data, to: paths.primary)
        latestRevisions[record.id] = record.revision
    }

    func load(id: UUID) async throws -> SessionLoadResult {
        try loadFromDisk(id: id)
    }

    func list() async throws -> [SessionSummary] {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return [] }
        let names = try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
        var ids = Set(names.compactMap { name -> UUID? in
            if name.hasSuffix(".backup.json") {
                return UUID(uuidString: String(name.dropLast(".backup.json".count)))
            }
            guard name.hasSuffix(".json") else { return nil }
            return UUID(uuidString: String(name.dropLast(".json".count)))
        })
        let tombstonedIDs = Set(names.compactMap { name -> UUID? in
            guard name.hasSuffix(".deleted") else { return nil }
            return UUID(uuidString: String(name.dropLast(".deleted".count)))
        })

        // Tombstoned records stay hidden once cleanup completed. If deletion was
        // interrupted, keep a warning row so the user can retry cleanup.
        let tombstonesWithRemainders = tombstonedIDs.filter { id in
            let filePaths = paths(for: id)
            return FileManager.default.fileExists(atPath: filePaths.primary.path)
                || FileManager.default.fileExists(atPath: filePaths.backup.path)
        }
        ids.formUnion(tombstonesWithRemainders)

        return ids.subtracting(tombstonedIDs.subtracting(tombstonesWithRemainders)).map { id in
            if tombstonedIDs.contains(id) {
                return Self.unavailableSummary(id: id, warning: "Deletion incomplete; retry Delete to remove the remaining files.")
            }
            do {
                let loaded = try loadFromDisk(id: id)
                return Self.summary(for: loaded.session, warning: loaded.recoveredFromBackup ? "Recovered from backup." : nil)
            } catch SessionStoreError.unsupportedSchemaVersion(_, let version) {
                return Self.unavailableSummary(id: id, warning: "Saved with newer schema version \(version). Update Murmur to open it.")
            } catch {
                return Self.unavailableSummary(id: id, warning: error.localizedDescription)
            }
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func delete(id: UUID) async throws {
        try prepareDirectory()
        let paths = paths(for: id)
        // Tombstone first. A delayed save, including one from a new store actor,
        // observes it and cannot resurrect this UUID after deletion.
        try writeAtomically(Data("deleted".utf8), to: paths.tombstone)
        try removeIfPresent(paths.primary)
        try removeIfPresent(paths.backup)
        latestRevisions.removeValue(forKey: id)
    }

    private struct FileState {
        let record: SavedSession?
        let validData: Data?
    }

    private func inspectFile(_ url: URL, expectedID: UUID) throws -> FileState {
        guard FileManager.default.fileExists(atPath: url.path) else { return FileState(record: nil, validData: nil) }
        let data = try Data(contentsOf: url)
        let header: FileHeader
        do {
            header = try decoder.decode(FileHeader.self, from: data)
        } catch is DecodingError {
            return FileState(record: nil, validData: nil)
        }
        guard header.schemaVersion == SavedSession.currentSchemaVersion else {
            throw SessionStoreError.unsupportedSchemaVersion(id: expectedID, version: header.schemaVersion)
        }
        do {
            let record = try decoder.decode(SavedSession.self, from: data)
            guard record.id == expectedID else {
                throw SessionStoreError.recordIDMismatch(expected: expectedID, actual: record.id)
            }
            return FileState(record: record, validData: data)
        } catch let error as SessionStoreError {
            throw error
        } catch is DecodingError {
            return FileState(record: nil, validData: nil)
        }
    }

    private func loadFromDisk(id: UUID) throws -> SessionLoadResult {
        let paths = paths(for: id)
        guard !FileManager.default.fileExists(atPath: paths.tombstone.path) else {
            throw SessionStoreError.deleted(id)
        }
        guard FileManager.default.fileExists(atPath: paths.primary.path)
                || FileManager.default.fileExists(atPath: paths.backup.path) else {
            throw SessionStoreError.notFound(id)
        }

        do {
            let primary = try inspectFile(paths.primary, expectedID: id)
            if let record = primary.record {
                latestRevisions[id] = max(latestRevisions[id] ?? 0, record.revision)
                return SessionLoadResult(session: record, recoveredFromBackup: false)
            }
        } catch let error as SessionStoreError {
            // A newer primary is authoritative: never silently roll back to backup.
            if case .unsupportedSchemaVersion = error { throw error }
            if case .recordIDMismatch = error { throw error }
        } catch {
            throw error
        }

        let backup = try inspectFile(paths.backup, expectedID: id)
        if let record = backup.record {
            // The primary was absent or unreadable, so this validated backup is
            // now the authoritative revision baseline for a recovered edit.
            latestRevisions[id] = record.revision
            return SessionLoadResult(session: record, recoveredFromBackup: true)
        }
        throw SessionStoreError.corruptRecord(id)
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
    }

    private func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func removeIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try fileRemover(url)
    }

    private struct FileHeader: Decodable { let schemaVersion: Int }

    private func paths(for id: UUID) -> (primary: URL, backup: URL, tombstone: URL) {
        (
            directoryURL.appendingPathComponent("\(id.uuidString).json"),
            directoryURL.appendingPathComponent("\(id.uuidString).backup.json"),
            directoryURL.appendingPathComponent("\(id.uuidString).deleted")
        )
    }

    private static func summary(for session: SavedSession, warning: String?) -> SessionSummary {
        let preview = session.transcript.last(where: \.isFinal)?.text
            ?? session.context?.summary
            ?? ""
        return SessionSummary(
            id: session.id,
            title: session.title.isEmpty ? "Untitled session" : session.title,
            createdAt: session.createdAt,
            updatedAt: session.updatedAt,
            preview: String(preview.prefix(240)),
            isDemo: session.isDemo,
            warning: warning
        )
    }

    private static func unavailableSummary(id: UUID, warning: String) -> SessionSummary {
        SessionSummary(
            id: id,
            title: "Saved session unavailable",
            createdAt: .distantPast,
            updatedAt: .distantPast,
            preview: warning,
            isDemo: false,
            available: false,
            warning: warning
        )
    }

    private static func defaultDirectoryURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("me.openhorizons.murmur", isDirectory: true)
            .appendingPathComponent("Sessions", isDirectory: true)
    }
}

actor InMemorySessionStore: SessionStoring {
    private var sessions: [UUID: SavedSession] = [:]
    private var deletedIDs: Set<UUID> = []

    func save(_ record: SavedSession) async throws {
        guard record.schemaVersion == SavedSession.currentSchemaVersion else {
            throw SessionStoreError.invalidSchemaVersion(record.schemaVersion)
        }
        guard !deletedIDs.contains(record.id) else { throw SessionStoreError.deleted(record.id) }
        if let current = sessions[record.id], record.revision <= current.revision {
            throw SessionStoreError.staleRevision(id: record.id, incoming: record.revision, latest: current.revision)
        }
        sessions[record.id] = record
    }

    func load(id: UUID) async throws -> SessionLoadResult {
        guard !deletedIDs.contains(id) else { throw SessionStoreError.deleted(id) }
        guard let session = sessions[id] else { throw SessionStoreError.notFound(id) }
        return SessionLoadResult(session: session, recoveredFromBackup: false)
    }

    func list() async throws -> [SessionSummary] {
        sessions.values.map { session in
            let preview = session.transcript.last(where: \.isFinal)?.text ?? session.context?.summary ?? ""
            return SessionSummary(
                id: session.id,
                title: session.title.isEmpty ? "Untitled session" : session.title,
                createdAt: session.createdAt,
                updatedAt: session.updatedAt,
                preview: String(preview.prefix(240)),
                isDemo: session.isDemo
            )
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func delete(id: UUID) async throws {
        deletedIDs.insert(id)
        sessions.removeValue(forKey: id)
    }
}
