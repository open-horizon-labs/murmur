import MurmurCore
import SwiftUI
import UniformTypeIdentifiers

struct CompanionView: View {
    @Bindable var model: AppModel
    @State private var selectedPassage: TranscriptSelection?
    @State private var isSettingsPresented = false
    @State private var isHistoryPresented = false
    @State private var isConfirmingNewConversation = false

    var body: some View {
        VStack(spacing: 0) {
            SessionToolbar(
                model: model,
                openSettings: { isSettingsPresented = true },
                openHistory: { isHistoryPresented = true },
                newConversation: { isConfirmingNewConversation = true },
                toggleListening: toggleListening
            )

            Divider()

            if case .failed(let message) = model.phase {
                SessionErrorBanner(
                    message: message,
                    canRetry: model.canStartListening && !model.isStopping && !model.isResetting,
                    retry: toggleListening,
                    openSettings: { isSettingsPresented = true },
                    dismiss: { model.dismissError() }
                )
                Divider()
            }

            HSplitView {
                TranscriptView(
                    entries: model.displayedTranscriptEntries.filter { !$0.text.isEmpty },
                    phase: model.phase,
                    isDemo: model.isDemo,
                    isPostCallVersion: model.postCallRevisionID != nil && model.showsPostCallTranscript,
                    hasPostCallVersion: !model.postCallTranscriptEntries.isEmpty,
                    selectPostCallVersion: { model.showsPostCallTranscript = $0 },
                    canInvestigate: model.canInvestigate && !model.isStopping && !model.isResetting && !model.investigations.contains(where: { $0.activity == .working }),
                    investigateDisabledReason: investigationDisabledReason,
                    selection: $selectedPassage,
                    onInvestigate: { selection, question in
                        model.investigate(selection: selection, question: question)
                    }
                )
                .frame(minWidth: 410, maxWidth: .infinity, maxHeight: .infinity)

                ContextPanel(
                    model: model,
                    openSettings: { isSettingsPresented = true }
                )
                .frame(minWidth: 310, idealWidth: 370, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(.background)
        .environment(\.openTranscriptEvidence, { evidence in
            guard evidence.transcriptSessionID == model.activeSessionID?.uuidString,
                  let id = evidence.transcriptEntryID,
                  let entry = (model.transcriptEntries.first(where: { $0.id == id })
                    ?? model.postCallTranscriptEntries.first(where: { $0.id == id })),
                  entry.isFinal, !entry.isSystemNotice, entry.wasInterrupted != true,
                  !evidence.excerpt.isEmpty, entry.text.contains(evidence.excerpt) else { return }
            model.showsPostCallTranscript = model.transcriptEntries.contains(where: { $0.id == id })
            selectedPassage = TranscriptSelection(text: evidence.excerpt, entryIDs: [id])
        })
        .task { await model.restoreLastWorkspaceIfNeeded() }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsView(model: model)
                .frame(minWidth: 540, idealWidth: 600, minHeight: 580, idealHeight: 620)
        }
        .sheet(isPresented: $isHistoryPresented) {
            SessionHistoryView(model: model) { id in
                selectedPassage = nil
                Task {
                    if await model.openSession(id: id) {
                        isHistoryPresented = false
                    }
                }
            }
            .frame(minWidth: 620, idealWidth: 700, minHeight: 420, idealHeight: 520)
        }
        .onChange(of: model.activeSessionID) { _, _ in
            selectedPassage = nil
        }
        .confirmationDialog(
            "Start a new conversation?",
            isPresented: $isConfirmingNewConversation,
            titleVisibility: .visible
        ) {
            Button("Start New Conversation") {
                selectedPassage = nil
                Task { await model.newConversation() }
            }
            .disabled(model.isStopping || model.isResetting)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your current conversation is kept in History so you can return to it later.")
        }
    }

    private func toggleListening() {
        if model.phase.isActive {
            Task { await model.stop() }
        } else {
            Task { await model.startLive() }
        }
    }

    private var investigationDisabledReason: String {
        if !model.canUseWorkspaceAgents { return "Enable Context agents in Settings" }
        if model.deepModel.isEmpty { return "Choose a passage agent model in Settings" }
        if model.isStopping || model.isResetting { return "Wait for the current session change to finish" }
        if model.investigations.contains(where: { $0.activity == .working }) { return "Wait for the current passage investigation to finish" }
        return "Investigate this passage"
    }
}

private struct SessionErrorBanner: View {
    let message: String
    let canRetry: Bool
    let retry: () -> Void
    let openSettings: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text("Listening stopped")
                    .font(.callout.weight(.semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if canRetry {
                Button("Try again", action: retry).buttonStyle(.bordered)
            } else {
                Button("Review Settings", action: openSettings).buttonStyle(.bordered)
            }
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .accessibilityLabel("Dismiss error")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.08))
    }
}

private struct SessionToolbar: View {
    let model: AppModel
    let openSettings: () -> Void
    let openHistory: () -> Void
    let newConversation: () -> Void
    let toggleListening: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.indigo)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text("Murmur")
                        .font(.headline)
                    if model.isDemo {
                        Text("SIMULATED")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.12), in: Capsule())
                    }
                }
                Text(model.hasConversation ? "\(model.sessionTitle) · \(statusDetail)" : statusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            PersistenceStatusView(model: model)
                .help(model.persistenceError ?? model.persistenceStatus)

            Button("History", systemImage: "clock.arrow.circlepath", action: openHistory)
                .labelStyle(.titleAndIcon)
                .buttonStyle(.bordered)
                .help("Browse saved conversations")

            if model.hasConversation && !(model.isDemo && !model.phase.isActive) {
                Button("New conversation", systemImage: "plus") { newConversation() }
                    .labelStyle(.titleAndIcon)
                    .help("Start a new conversation. This one stays in History.")
                    .disabled(model.isStopping || model.isResetting)
            }

            Button("Settings", systemImage: "slider.horizontal.3", action: openSettings)
                .labelStyle(.iconOnly)
                .help("Workspace, audio, and agent settings")

            Button {
                if model.isDemo && !model.phase.isActive {
                    newConversation()
                } else {
                    toggleListening()
                }
            } label: {
                if model.phase == .connecting {
                    Label("Cancel", systemImage: "xmark")
                } else if model.phase == .listening {
                    Label("Stop", systemImage: "stop.fill")
                } else if model.isDemo {
                    Label("New conversation", systemImage: "plus")
                } else if model.hasConversation {
                    Label("Resume", systemImage: "play.fill")
                } else {
                    Label("Start listening", systemImage: "waveform")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isStopping || model.isResetting || (!model.phase.isActive && !model.isDemo && !model.canStartListening))
            .help(startHelp)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.bar)
    }

    private var statusDetail: String {
        if let status = model.transcriptionConnectionStatus { return status }
        if model.phase == .connecting { return "Connecting to transcription" }
        if model.phase == .listening { return model.isDemo ? "Sample conversation" : model.sourceMode.rawValue }
        if model.hasConversation { return "Conversation paused · \(model.workspaceName)" }
        if model.isCallOnly { return "Call only · no folder access" }
        if model.workspaceURL == nil { return "Saved workspace unavailable" }
        if !model.hasTranscriptionCredential { return "Add a transcription key in Settings" }
        return model.workspaceName
    }

    private var startHelp: String {
        if model.phase.isActive { return "Stop listening; this conversation is saved in History" }
        if model.isDemo { return "Start a new conversation to leave this simulated session" }
        if !model.isCallOnly && model.workspaceURL == nil { return "Relink this conversation’s workspace before resuming" }
        if !model.hasTranscriptionCredential { return "Add an OpenAI API key in Settings before starting" }
        return model.hasConversation ? "Resume this conversation" : "Start an explicitly selected audio session"
    }
}

private struct ContextPanel: View {
    let model: AppModel
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "brain.head.profile")
                    .foregroundStyle(.indigo)
                Text("Context")
                    .font(.headline)
                if model.isDemo {
                    Text("SIMULATED")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.orange.opacity(0.12), in: Capsule())
                }
                Spacer()
                if model.mediumActivity == .working {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Refreshing context")
                }
                Button {
                    model.refreshContext()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(!model.canRunAgents || model.mediumActivity == .working || model.isStopping || model.isResetting)
                .help("Refresh understanding of this call")
                .accessibilityLabel("Refresh context")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.bar)

            Divider()

            PostCallReviewStatus(model: model)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let finding = model.contextFinding {
                        ContextFindingView(
                            finding: finding,
                            updatedAt: model.contextUpdatedAt,
                            workspaceURL: model.workspaceURL
                        )
                    } else {
                        ContextEmptyState(
                            hasConversation: model.hasConversation,
                            isDemo: model.isDemo,
                            isAgentReady: model.canRunAgents,
                            activity: model.mediumActivity,
                            openSettings: openSettings
                        )
                    }

                    if let message = model.contextMessage {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if case .failed(let message) = model.mediumActivity, model.contextMessage != message {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    ForEach(model.investigations) { investigation in
                        InvestigationCard(
                            investigation: investigation,
                            workspaceURL: model.workspaceURL,
                            dismiss: { model.dismissInvestigation(id: investigation.id) },
                            cancel: { model.cancelInvestigation(id: investigation.id) },
                            retry: {
                                guard model.canInvestigate,
                                      !model.isStopping, !model.isResetting, !model.isInvestigating else { return }
                                model.dismissInvestigation(id: investigation.id)
                                model.investigate(selection: investigation.selection, question: investigation.question)
                            },
                            canRetry: model.canInvestigate && !model.isStopping && !model.isResetting && !model.isInvestigating
                        )
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct PostCallReviewStatus: View {
    @Bindable var model: AppModel

    var body: some View {
        if let status = model.postCallStatus, status != "complete" && status != "deleted" {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if status == "transcribing" || status == "context_pending" { ProgressView().controlSize(.small) }
                    Label(title(for: status), systemImage: status == "failed" ? "exclamationmark.triangle" : "waveform")
                        .font(.callout.weight(.medium))
                }
                if let message = model.postCallMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !model.postCallRecordingIDs.isEmpty {
                    HStack {
                        if status == "failed" || status == "pending" || status == "needs_setup" {
                            Button(model.postCallMessage?.localizedCaseInsensitiveContains("may have completed") == true
                                ? "Retry · may duplicate charge" : (model.postCallMessage?.localizedCaseInsensitiveContains("incomplete") == true
                                    || model.postCallMessage?.localizedCaseInsensitiveContains("not been finalized") == true
                                    ? "Analyze available audio" : "Retry review")) {
                                model.retryPostCallReview(userInitiated: true)
                            }
                            .buttonStyle(.bordered)
                        }
                        Spacer()
                        if status != "recording" {
                            Button("Delete now", role: .destructive) { model.deleteTemporaryRecordingNow() }
                                .buttonStyle(.borderless)
                        }
                    }
                    Toggle("Keep temporary audio until I review it", isOn: Binding(
                        get: { model.postCallKeepUntilReviewed },
                        set: { model.setKeepRecordingUntilReviewed($0) }
                    ))
                    .font(.caption)
                    if let expiresAt = model.postCallAudioExpiresAt {
                        Text("Expires \(expiresAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(12)
            .background(.indigo.opacity(0.06))
        } else if let status = model.recordingStatus {
            Label(status, systemImage: "waveform")
                .font(.caption).foregroundStyle(.secondary)
                .padding(12)
        }
    }

    private func title(for status: String) -> String {
        switch status {
        case "recording": "Temporary recording active · stop before deleting"
        case "transcribing": "Preparing post-call transcript"
        case "context_pending": "Regenerating Context"
        case "retained": "Review ready · audio retained"
        case "failed": "Post-call review needs attention"
        case "needs_setup": "Post-call review needs setup"
        default: "Post-call review pending"
        }
    }
}

private struct ContextEmptyState: View {
    let hasConversation: Bool
    let isDemo: Bool
    let isAgentReady: Bool
    let activity: TierActivity
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if activity == .working {
                    ProgressView().controlSize(.small)
                    Text("Building call context…")
                        .font(.headline)
                } else {
                    Text(hasConversation ? "No context yet" : "Your call context")
                        .font(.headline)
                }
            }
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !isAgentReady && !isDemo {
                Button("Set up Context agents", action: openSettings)
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private var description: String {
        if activity == .working { return "The transcript stays available while Murmur updates its understanding of this call." }
        if isDemo { return "This simulated call uses sample context only. Start a new conversation to use Context agents with live speech." }
        if !isAgentReady { return "In Settings, choose a Context model and enable agents to build an evolving understanding of this call." }
        if hasConversation { return "Refresh Context to review this conversation’s decisions and open questions." }
        return "Start a conversation and Murmur will keep an evolving understanding beside the transcript."
    }
}

private struct ContextFindingView: View {
    let finding: AgentFinding
    let updatedAt: Date?
    let workspaceURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(finding.title)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                if let updatedAt {
                    Text(updatedAt.formatted(.relative(presentation: .named)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .help("Context updated \(updatedAt.formatted(date: .abbreviated, time: .shortened))")
                }
            }
            AgentMarkdownView(markdown: finding.summary)

            if !finding.evidence.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 9) {
                    Text("Sources")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(Array(finding.evidence.prefix(5).enumerated()), id: \.offset) { _, evidence in
                        EvidenceRow(evidence: evidence, workspaceURL: workspaceURL)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InvestigationCard: View {
    let investigation: PassageInvestigation
    let workspaceURL: URL?
    let dismiss: () -> Void
    let cancel: () -> Void
    let retry: () -> Void
    let canRetry: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                Label("Passage investigation", systemImage: "quote.bubble")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.indigo)
                Spacer()
                if investigation.activity == .working {
                    Button("Cancel", action: cancel)
                        .buttonStyle(.link)
                        .font(.caption)
                } else {
                    Button(action: dismiss) {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Dismiss this finding from the session")
                    .accessibilityLabel("Dismiss passage investigation")
                }
            }

            Text("“\(investigation.selection.text)”")
                .font(.callout.weight(.medium))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !investigation.question.isEmpty {
                Text(investigation.question)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch investigation.activity {
            case .working:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Investigating this passage…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: 7) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try again", systemImage: "arrow.clockwise", action: retry)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!canRetry)
                        .help(canRetry ? "Repeat this investigation with the same passage and question" : "Wait until another investigation finishes, or restore agent access")
                }
            case .completed:
                if let finding = investigation.finding {
                    Divider()
                    Text(finding.title)
                        .font(.headline)
                    AgentMarkdownView(markdown: finding.summary)
                        .foregroundStyle(.secondary)
                    ForEach(Array(finding.evidence.prefix(4).enumerated()), id: \.offset) { _, evidence in
                        EvidenceRow(evidence: evidence, workspaceURL: workspaceURL)
                    }
                }
            case .suggested(let message):
                Label(message, systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .idle:
                if let finding = investigation.finding {
                    AgentMarkdownView(markdown: finding.summary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: .rect(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(.separator.opacity(0.45), lineWidth: 0.5)
        }
    }
}

private struct EvidenceRow: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.openTranscriptEvidence) private var openTranscriptEvidence
    let evidence: AgentEvidence
    let workspaceURL: URL?

    var body: some View {
        if evidence.transcriptSessionID != nil {
            Button { openTranscriptEvidence(evidence) } label: { evidenceContent }
                .buttonStyle(.plain)
                .help("Show the cited passage in this call’s transcript")
        } else if let sourceURL = WorkspaceEvidenceLink.fileURL(path: evidence.path, workspace: workspaceURL) {
            Button {
                openURL(sourceURL)
            } label: {
                evidenceContent
            }
            .buttonStyle(.plain)
            .help("Open this file from the selected workspace")
        } else {
            evidenceContent
                .foregroundStyle(.secondary)
        }
    }

    private var evidenceContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(evidence.sourceLabel, systemImage: "doc.text.magnifyingglass")
                .font(.caption.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if !evidence.excerpt.isEmpty {
                Text(evidence.excerpt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

enum WorkspaceEvidenceLink {
    static func fileURL(path: String, workspace: URL?) -> URL? {
        guard let workspace, !path.isEmpty else { return nil }
        let root = workspace.standardizedFileURL.resolvingSymlinksInPath()
        let pathWithoutLine = path.components(separatedBy: "#L").first ?? path
        let candidate: URL
        if pathWithoutLine.hasPrefix("/") {
            candidate = URL(fileURLWithPath: pathWithoutLine)
        } else {
            candidate = root.appendingPathComponent(pathWithoutLine)
        }
        let canonical = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard canonical.isFileURL,
              canonical.path.hasPrefix(root.path + "/"),
              FileManager.default.fileExists(atPath: canonical.path) else { return nil }
        return canonical
    }
}

private struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var isChoosingWorkspace = false
    @State private var apiKey = ""
    @State private var section: SettingsSection = .context

    private enum SettingsSection: String, CaseIterable, Identifiable {
        case listening = "Listening"
        case context = "Context"
        case privacy = "API & privacy"
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Settings")
                        .font(.title2.weight(.semibold))
                    Text("Choose what Murmur can hear and where it can look.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done", action: { dismiss() })
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            Picker("Settings", selection: $section) {
                ForEach(SettingsSection.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if section == .listening {
                    settingGroup("Audio source") {
                        Picker("Listen to", selection: $model.sourceMode) {
                            ForEach(AudioSourceMode.allCases) { source in
                                Label(source.rawValue, systemImage: source.systemImage).tag(source)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(model.phase.isActive || model.isStopping || model.isResetting)
                        Toggle("Keep a temporary recording for review", isOn: Binding(
                            get: { model.temporaryRecordingEnabled },
                            set: { model.setTemporaryRecordingEnabled($0) }
                        ))
                        .disabled(model.phase.isActive || model.isStopping || model.isResetting)
                        Text("Applies to the next recording. Murmur records each selected source separately while listening. Temporary audio is deleted after the post-call transcript and matching Context are saved, or expires after 24 hours.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    settingGroup("Transcription") {
                        Picker("Transcription model", selection: $model.transcriptionModel) {
                            ForEach(TranscriptionModel.allCases) { choice in
                                Text(choice.title).tag(choice)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(model.phase.isActive || model.isStopping || model.isResetting)
                        Text(model.transcriptionModel.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if model.hasConversation {
                            Text("Changes apply to the next conversation.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    settingGroup("Try it") {
                        Text("Explore the transcript and Context with a simulated call. Murmur does not capture audio in the demo.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Try simulated conversation", systemImage: "play.circle") {
                            model.startDemo()
                            dismiss()
                        }
                        .disabled(model.phase.isActive || model.hasConversation || model.isStopping || model.isResetting)
                        .buttonStyle(.link)
                    }
                    } else if section == .context {
                    settingGroup("Workspace") {
                        WorkspaceSettingsRow(model: model, chooseFolder: { isChoosingWorkspace = true })
                        if model.workspaceURL != nil && !model.hasConversation {
                            Button("Use call only — no folder access") { model.useCallOnly() }
                                .buttonStyle(.link)
                                .disabled(model.phase.isActive || model.isStopping || model.isResetting)
                        }
                    }
                    settingGroup(model.isCallOnly ? "Call agents" : "File access") {
                        WorkspaceAgentSettings(model: model)
                    }
                    settingGroup("Context instructions") {
                        ContextGuidanceEditor(model: model)
                    }
                    settingGroup("Advanced") {
                        DisclosureGroup("Context limits") {
                            ContextLimitsEditor(model: model)
                                .padding(.top, 10)
                        }
                    }
                    settingGroup("Models") {
                        AgentModelSettings(model: model)
                        OpenAIModelIDSelector(
                            title: "Post-call transcription model",
                            purpose: "Reviews the temporary recording after you stop. Choose a batch transcription model ID; the live transcription model is not compatible.",
                            selection: Binding(get: { model.batchTranscriptionModel }, set: { model.setBatchTranscriptionModel($0) }),
                            models: model.codexModels,
                            recentIDs: model.recentModelIDs,
                            status: model.batchTranscriptionModel.isEmpty
                                ? "Choose a batch model before post-call review starts."
                                : model.modelAvailability(model.batchTranscriptionModel, for: "post-call transcription")
                        )
                        .disabled(model.postCallStatus == "transcribing")
                    }
                    } else {
                    settingGroup("OpenAI API") {
                        TranscriptionCredentialSettings(model: model, apiKey: $apiKey)
                    }
                    settingGroup("On this Mac") {
                        Text("Conversations are saved locally. Temporary recordings are kept for up to 24 hours while review is pending and are removed after the reviewed transcript and matching Context are saved.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    }
                }
                .padding(20)
            }
        }
        .fileImporter(isPresented: $isChoosingWorkspace, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let folder = urls.first else { return }
            Task { await model.loadWorkspace(from: folder) }
        }
    }

    private func settingGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

private struct ContextLimitsEditor: View {
    let model: AppModel
    @State private var rounds = ""
    @State private var calls = ""
    @State private var seconds = ""
    @State private var message: String?

    private var draft: ContextRunLimits? {
        guard let rounds = Int(rounds.trimmingCharacters(in: .whitespacesAndNewlines)),
              let calls = Int(calls.trimmingCharacters(in: .whitespacesAndNewlines)),
              let seconds = Int(seconds.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let value = ContextRunLimits(lookupRounds: rounds, toolCalls: calls, timeoutSeconds: seconds)
        return value.isValid ? value : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Limits for each live or post-call Context update. Larger limits may increase wait time and API usage. Passage investigations keep their existing limits.")
                .font(.caption).foregroundStyle(.secondary)
            limitRow("Lookup rounds", detail: "1–100 model turns for looking up information", value: $rounds)
            limitRow("Tool calls", detail: "1–1,000 transcript or file lookups in total", value: $calls)
            limitRow("Time limit (seconds)", detail: "30–1,800 seconds for the entire update", value: $seconds)
            Text("One summary-only turn is reserved after the lookup limit, within the overall time limit.")
                .font(.caption).foregroundStyle(.secondary)
            if draft == nil {
                Text("Use whole numbers within the shown ranges.")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("Restore defaults") {
                    model.resetContextLimits()
                    loadSavedValues()
                    message = "Defaults restored. Applies to the next update."
                }
                .disabled(draft == .defaults && model.contextLimits == .defaults)
                Spacer()
                Button("Save limits") {
                    if let draft, model.saveContextLimits(draft) {
                        loadSavedValues()
                        message = "Saved. Applies to the next update."
                    }
                }
                .disabled(draft == nil || draft == model.contextLimits)
            }
            Text(draft != model.contextLimits ? "Unsaved changes." : (message ?? "Saved on this Mac. Running updates and existing notes stay unchanged."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { loadSavedValues() }
    }

    private func limitRow(_ title: String, detail: String, value: Binding<String>) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            TextField(title, text: value)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 88)
                .accessibilityLabel(title)
        }
    }

    private func loadSavedValues() {
        rounds = String(model.contextLimits.lookupRounds)
        calls = String(model.contextLimits.toolCalls)
        seconds = String(model.contextLimits.timeoutSeconds)
    }
}

private struct ContextGuidanceEditor: View {
    let model: AppModel
    @State private var draft = ""
    @State private var savedMessage: String?

    private var hasChanges: Bool { draft != model.contextGuidance }
    private var isValid: Bool { ContextGuidance.validated(draft) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose the tone, structure, and focus of your live and post-call notes. Citation and transcript-reading requirements stay in place.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $draft)
                .font(.body)
                .frame(minHeight: 220)
                .padding(6)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.25)))
                .accessibilityLabel("Context instructions")
            if !isValid {
                Text(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? "Enter instructions, or restore the default."
                     : "Use 8,000 characters or fewer.")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("Restore default") {
                    model.resetContextGuidance()
                    draft = model.contextGuidance
                    savedMessage = "Default restored. Applies to the next Context update."
                }
                .disabled(draft == ContextGuidance.defaultText && model.contextGuidance == ContextGuidance.defaultText)
                Spacer()
                Button("Save instructions") {
                    if model.saveContextGuidance(draft) {
                        draft = model.contextGuidance
                        savedMessage = "Saved. Applies to the next Context update."
                    }
                }
                .disabled(!hasChanges || !isValid)
            }
            Text(hasChanges ? "Unsaved changes. Save to apply to future Context updates." : (savedMessage ?? "Saved on this Mac for all calls. Changes apply to the next Context update; existing notes stay as they are."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { draft = model.contextGuidance }
    }
}

private struct TranscriptionCredentialSettings: View {
    @Bindable var model: AppModel
    @Binding var apiKey: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.usesEnvironmentCredential {
                Label("Using OpenAI key from this launch", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if model.hasSavedTranscriptionCredential {
                Label("OpenAI key stored in macOS Keychain", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Button("Remove saved key", role: .destructive) { model.removeTranscriptionAPIKey() }
                    .buttonStyle(.link)
                    .font(.caption)
            } else {
                HStack(spacing: 8) {
                    SecureField("OpenAI API key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { save() }
                    Button("Save", action: save)
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Text("OpenAI account usage includes live transcription, Context updates, and Passage investigations. Transcripts, selected passages, and relevant source snippets may be sent with agent requests.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message = model.credentialMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func save() {
        if model.saveTranscriptionAPIKey(apiKey) { apiKey = "" }
    }
}

private struct WorkspaceSettingsRow: View {
    @Bindable var model: AppModel
    let chooseFolder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.workspaceName).font(.callout.weight(.medium))
                    Text(model.workspaceMessage ?? (model.isCallOnly ? "Agents use this call’s transcript. A folder is optional." : "\(model.workspaceDocumentCount) indexed files"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if model.isLoadingWorkspace {
                    ProgressView().controlSize(.small)
                } else {
                    Menu(model.isCallOnly ? "Add folder…" : "Change") {
                        ForEach(model.recentWorkspaces) { workspace in
                            Button(workspace.name) {
                                Task { await model.switchToRecentWorkspace(workspace) }
                            }
                        }
                        if !model.recentWorkspaces.isEmpty { Divider() }
                        Button("Choose folder…", systemImage: "folder.badge.plus", action: chooseFolder)
                    }
                    .disabled(!canChangeWorkspace)
                    .help(model.canRelinkWorkspace ? "Choose the saved workspace again before resuming this conversation" : "Change workspace")
                }
            }
            if model.canRelinkWorkspace {
                Text("This conversation’s saved workspace is missing. Choose it again before resuming.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.hasConversation {
                Text("Start a new conversation before changing the workspace.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.phase.isActive || model.isStopping {
                Text("Stop listening before changing the workspace.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var canChangeWorkspace: Bool {
        (!model.hasConversation || model.canRelinkWorkspace) && !model.phase.isActive && !model.isStopping && !model.isResetting
    }
}

private struct WorkspaceAgentSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        if model.isCallOnly {
            Text("Agents send relevant transcript passages to OpenAI to update Context and answer your passage questions. They cannot read local folders in call-only mode.")
                .font(.caption).foregroundStyle(.secondary)
            if model.callAgentsEnabled {
                Label("Call agents enabled", systemImage: "checkmark.circle")
                Button("Disable call agents") { model.disableCallAgents() }.buttonStyle(.link)
            } else {
                Button("Enable call agents") { model.enableCallAgents() }
            }
        } else if model.workspaceURL == nil {
            Text("Relink this call’s workspace before using its agents.")
                .font(.caption).foregroundStyle(.secondary)
        } else if model.hasAgentConsent {
            Label("Read-only access is allowed for this workspace.", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Murmur can inspect the selected folder read-only. Context and Passage requests can include relevant transcript excerpts and small source snippets. This permission is remembered for this workspace.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Allow workspace agents") { model.grantAgentConsent() }
                .buttonStyle(.bordered)
        }
        HStack {
            if model.hasAgentConsent {
                Button("Revoke access", role: .destructive) { model.revokeAgentConsent() }
                    .buttonStyle(.link)
            }
        }
    }
}

private struct AgentModelSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(model.isLoadingCodex ? "Loading model list…" : model.codexMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Refresh") { Task { await model.refreshCodex() } }
                .disabled(model.isLoadingCodex)
                .controlSize(.small)
        }
        OpenAIModelIDSelector(
            title: "Context model",
            purpose: "Updates automatically as the conversation develops.",
            selection: $model.contextModel,
            models: model.codexModels,
            recentIDs: model.recentModelIDs,
            status: model.modelAvailability(model.contextModel, for: "Context")
        )
        ReasoningEffortSelector(title: "Context effort", selection: $model.contextEffort)
        OpenAIModelIDSelector(
            title: "Passage investigation model",
            purpose: "Runs on demand when you select a transcript passage.",
            selection: $model.deepModel,
            models: model.codexModels,
            recentIDs: model.recentModelIDs,
            status: model.modelAvailability(model.deepModel, for: "Passage agent")
        )
        ReasoningEffortSelector(title: "Passage investigation effort", selection: $model.investigationEffort)
        Text("Model and effort choices are saved on this Mac and apply to the next run. Higher effort may take longer and use more tokens. Supported levels vary by model; unsupported choices show an error. Model default lets the API decide.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ReasoningEffortSelector: View {
    let title: String
    @Binding var selection: ReasoningEffort

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(ReasoningEffort.allCases, id: \.self) { effort in
                Text(effort.label).tag(effort)
            }
        }
        .pickerStyle(.menu)
    }
}

private struct OpenAIModelIDSelector: View {
    let title: String
    let purpose: String
    @Binding var selection: String
    let models: [CodexModel]
    let recentIDs: [String]
    let status: String
    @State private var searchText = ""
    @State private var manualID = ""
    @State private var isShowingChooser = false

    private var matchingIDs: [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return models.map(\.model) }
        return models.map(\.model).filter { $0.lowercased().contains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.callout.weight(.medium))
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(purpose).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(selection.isEmpty ? "No model selected" : selection)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button(selection.isEmpty ? "Choose…" : "Change…") {
                    searchText = ""
                    manualID = ""
                    isShowingChooser = true
                }
                .accessibilityLabel("\(selection.isEmpty ? "Choose" : "Change") \(title.lowercased())")
                .popover(isPresented: $isShowingChooser, arrowEdge: .trailing) {
                    chooser
                        .frame(width: 390, height: 440)
                        .padding(16)
                }
            }
            if !selection.isEmpty && !models.contains(where: { $0.model == selection }) {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Choose \(title.lowercased())")
                    .font(.headline)
                Text("Select a listed model, or enter an exact ID below.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Search available model IDs", text: $searchText)
                .textFieldStyle(.roundedBorder)
            if !recentIDs.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Recent choices").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(recentIDs, id: \.self) { id in
                                Button(id) { choose(id) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                    }
                }
            }
            if matchingIDs.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(matchingIDs, id: \.self) { id in
                    Button { choose(id) } label: {
                        HStack {
                            Text(id).font(.system(.caption, design: .monospaced))
                            Spacer()
                            if selection == id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
            DisclosureGroup("Enter an exact model ID") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Model ID", text: $manualID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Text("IDs are sent exactly as entered. A model may be listed or accepted by the API without supporting every request type.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Use exact ID") { choose(manualID.trimmingCharacters(in: .whitespacesAndNewlines)) }
                            .disabled(manualID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(.top, 8)
            }
            .font(.callout)
        }
    }

    private func choose(_ id: String) {
        guard !id.isEmpty else { return }
        selection = id
        isShowingChooser = false
    }
}

struct MenuBarControls: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Murmur", systemImage: "waveform.circle.fill")
                    .font(.headline)
                Spacer()
                Text(model.phase == .connecting ? "Connecting" : (model.phase.isActive ? "Listening" : (model.hasConversation ? "Paused" : "Idle")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.phase.isActive {
                Button("Stop listening", systemImage: "stop.circle") {
                    Task { await model.stop() }
                }
            } else if model.hasConversation {
                Button("Resume", systemImage: "play.circle") {
                    Task { await model.startLive() }
                }
            } else {
                Button("Start listening", systemImage: "waveform") {
                    Task { await model.startLive() }
                }
            }
            Divider()
            Button("Open Live Call", systemImage: "text.bubble") {
                openWindow(id: LiveCallWindow.id)
            }
        }
        .padding(14)
        .frame(width: 250)
    }
}

private struct TranscriptEvidenceActionKey: EnvironmentKey {
    static var defaultValue: @MainActor @Sendable (AgentEvidence) -> Void { { _ in } }
}

private extension EnvironmentValues {
    var openTranscriptEvidence: @MainActor @Sendable (AgentEvidence) -> Void {
        get { self[TranscriptEvidenceActionKey.self] }
        set { self[TranscriptEvidenceActionKey.self] = newValue }
    }
}
