import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SessionHistoryView: View {
    @Bindable var model: AppModel
    let openSession: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var renamingSession: SessionSummary?
    @State private var renameTitle = ""
    @State private var deletingSession: SessionSummary?
    @State private var exportError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("History")
                        .font(.title2.weight(.semibold))
                    Text("Saved on this Mac. Audio is never included.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done", action: dismiss.callAsFunction)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(18)

            Divider()

            if let error = model.persistenceError {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.persistenceStatus == "Save failed" ? "Conversation could not be saved" : "History action failed")
                            .font(.callout.weight(.semibold))
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                    if model.persistenceStatus == "Save failed" {
                        Button("Retry save") { Task { await model.retrySave() } }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(.orange.opacity(0.08))
                Divider()
            }

            Group {
                if model.isLoadingHistory {
                    ProgressView("Loading conversations…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.sessionHistory.isEmpty {
                    ContentUnavailableView(
                        "No saved conversations",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("New conversations will appear here automatically.")
                    )
                } else {
                    List {
                        ForEach(model.sessionHistory) { session in
                            historyRow(session)
                        }
                    }
                    .listStyle(.inset)
                }
            }
        }
        .task { await model.loadSessionHistory() }
        .sheet(item: $renamingSession) { _ in
            renameSheet
                .frame(width: 360)
        }
        .confirmationDialog(
            "Delete \(deletingSession?.title ?? "conversation")?",
            isPresented: Binding(
                get: { deletingSession != nil },
                set: { if !$0 { deletingSession = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Conversation", role: .destructive) {
                guard let session = deletingSession else { return }
                deletingSession = nil
                Task { _ = await model.deleteSession(id: session.id) }
            }
            Button("Cancel", role: .cancel) { deletingSession = nil }
        } message: {
            Text("This removes the saved conversation and its local recovery copies. Exported files are left as they are.")
        }
        .alert("Couldn’t export conversation", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "Try exporting again.")
        }
    }

    private func historyRow(_ session: SessionSummary) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(session.title)
                        .font(.headline)
                        .lineLimit(1)
                    if session.isDemo {
                        Text("SIMULATED")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
                Text(session.preview.isEmpty ? "No transcript yet" : session.preview)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    if let warning = session.warning {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            Button("Open") { openSession(session.id) }
                .buttonStyle(.bordered)
                .disabled(!session.available || model.isLoadingHistory || model.isStopping || model.isResetting)
                .help(session.warning ?? "Open this conversation paused")
            Menu {
                Button("Rename…", systemImage: "pencil") {
                    renameTitle = session.title
                    renamingSession = session
                }
                .disabled(!session.available)
                Menu("Export") {
                    Button("Markdown…", systemImage: "doc.text") {
                        export(session, as: .markdown)
                    }
                    Button("JSON…", systemImage: "curlybraces") {
                        export(session, as: .json)
                    }
                }
                .disabled(!session.available)
                Divider()
                Button("Delete…", systemImage: "trash") {
                    deletingSession = session
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .disabled(model.isLoadingHistory || model.isResetting || model.isStopping)
            .help("Rename, export, or delete this conversation")
        }
        .padding(.vertical, 7)
    }

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename conversation")
                .font(.headline)
            TextField("Conversation name", text: $renameTitle)
                .textFieldStyle(.roundedBorder)
                .onSubmit(saveRename)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { renamingSession = nil }
                Button("Save", action: saveRename)
                    .keyboardShortcut(.defaultAction)
                    .disabled(renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }

    private func saveRename() {
        guard let session = renamingSession else { return }
        let title = renameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        renamingSession = nil
        Task { await model.renameSession(id: session.id, title: title) }
    }

    private func export(_ session: SessionSummary, as format: SessionExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(safeFilename(session.title)).\(format == .markdown ? "md" : "json")"
        panel.allowedContentTypes = [format == .markdown ? UTType(filenameExtension: "md") ?? .plainText : .json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            do {
                let data = try await model.exportSession(id: session.id, format: format)
                try await Task.detached(priority: .userInitiated) {
                    try data.write(to: url, options: .atomic)
                }.value
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private func safeFilename(_ title: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Murmur conversation" : cleaned
    }
}

struct PersistenceStatusView: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 5) {
            if model.persistenceStatus == "Saving…" {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: model.persistenceStatus == "Saved" ? "checkmark.circle.fill" : icon)
                    .foregroundStyle(model.persistenceStatus == "Save failed" ? .orange : .secondary)
            }
            Text(model.persistenceStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if model.persistenceStatus == "Save failed" {
                Button("Retry") { Task { await model.retrySave() } }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch model.persistenceStatus {
        case "Not saved": "circle.dashed"
        case "Saving…": "arrow.triangle.2.circlepath"
        case "Save failed": "exclamationmark.circle.fill"
        default: "externaldrive"
        }
    }
}
