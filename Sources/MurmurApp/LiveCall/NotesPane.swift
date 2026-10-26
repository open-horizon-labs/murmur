import MurmurCore
import SwiftUI

/// Catch-up on top, then the running notes: So far, Commitments, Open questions, Decisions, Evidence.
struct NotesPane: View {
    var model: LiveCallModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let message = model.savedMessage {
                    Text(message)
                        .font(LiveTheme.ui(14))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(LiveTheme.accentSoft, in: RoundedRectangle(cornerRadius: 10))
                        .padding(.bottom, 10)
                }
                CatchUpCard(model: model)
                if let notes = model.notes {
                    NotesBody(model: model, notes: notes)
                }
            }
            .padding(.init(top: 20, leading: 24, bottom: 40, trailing: 24))
        }
        .background(LiveTheme.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Notes")
    }
}

private struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(LiveTheme.ui(13, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 20)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct NotesBody: View {
    var model: LiveCallModel
    let notes: LiveNotes

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(text: "So far")
            Text(notes.summary)
                .font(LiveTheme.reading(17))
                .fixedSize(horizontal: false, vertical: true)
            NoteSection(model: model, title: "Commitments", items: notes.commitments)
            NoteSection(model: model, title: "Open questions", items: notes.openQuestions)
            NoteSection(model: model, title: "Decisions", items: notes.decisions)
            if !notes.findings.isEmpty {
                SectionTitle(text: "Evidence")
                ForEach(notes.findings) { finding in
                    FindingView(model: model, finding: finding)
                }
            }
            Text("Notes by \(notes.model) (\(String(format: "%.1f", notes.seconds))s). Spoken claims are not verified.")
                .font(LiveTheme.ui(12))
                .foregroundStyle(.secondary)
                .padding(.top, 24)
        }
    }
}

private struct NoteSection: View {
    var model: LiveCallModel
    let title: String
    let items: [LiveNoteItem]

    var body: some View {
        if !items.isEmpty {
            SectionTitle(text: title)
            ForEach(items) { item in
                NoteRow(model: model, item: item)
            }
        }
    }
}

/// A note with its tags and quote chips. A note with no verified quote says so.
private struct NoteRow: View {
    var model: LiveCallModel
    let item: LiveNoteItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.text)
                    .font(LiveTheme.reading(16))
                    .fixedSize(horizontal: false, vertical: true)
                if item.proposed { NoteTag(text: "Proposed") }
                if !item.hasQuote { NoteTag(text: "No quote") }
            }
            ForEach(item.evidence) { quote in
                QuoteChip(label: "“\(quote.quote)”", entry: quote.entry) { model.reveal(entry: $0) }
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .contain)
    }
}

private struct FindingView: View {
    var model: LiveCallModel
    let finding: LiveFinding

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(finding.title).font(LiveTheme.reading(16, weight: .semibold))
            Text(finding.detail)
                .font(LiveTheme.reading(15))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if finding.evidence.isEmpty {
                NoteTag(text: "No quote")
            }
            ForEach(finding.evidence) { quote in
                QuoteChip(label: "“\(quote.quote)”", entry: quote.entry) { model.reveal(entry: $0) }
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }
}
