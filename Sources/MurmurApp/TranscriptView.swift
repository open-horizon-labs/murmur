import AppKit
import SwiftUI

struct TranscriptView: View {
    let entries: [TranscriptEntry]
    let phase: ListeningPhase
    let isDemo: Bool
    var isPostCallVersion = false
    var hasPostCallVersion = false
    var selectPostCallVersion: (Bool) -> Void = { _ in }
    let canInvestigate: Bool
    let investigateDisabledReason: String
    @Binding var selection: TranscriptSelection?
    let onInvestigate: (TranscriptSelection, String) -> Void
    @State private var question = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "text.alignleft")
                    .foregroundStyle(.secondary)
                Text("Transcript")
                    .font(.headline)
                if hasPostCallVersion {
                    Picker("Transcript version", selection: Binding(
                        get: { isPostCallVersion }, set: { selectPostCallVersion($0) }
                    )) {
                        Text("Post-call").tag(true)
                        Text("Live").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                    .help("Switch between the batch-reviewed transcript and the original live transcript")
                }
                if isDemo {
                    Text("SIMULATED")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.orange.opacity(0.12), in: Capsule())
                }
                Spacer()
                Text(statusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)

            Divider()

            if entries.isEmpty {
                TranscriptEmptyState(phase: phase)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TranscriptTextView(entries: entries, selection: $selection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let selection, !selection.text.isEmpty {
                Divider()
                selectionAction(selection)
            }
        }
        .background(.background)
    }

    private var statusLabel: String {
        switch phase {
        case .connecting: "Connecting"
        case .listening: isDemo ? "Demo in progress" : "Listening"
        case .failed: "Connection stopped"
        case .idle: isPostCallVersion ? "Post-call transcript · inspect wording" : (entries.isEmpty ? "Ready when you are" : "Live transcript · saved in History")
        }
    }

    private func selectionAction(_ selected: TranscriptSelection) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "quote.opening")
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                Text(selected.text)
                    .font(.callout)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    selection = nil
                    question = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear selected passage")
            }

            HStack(spacing: 8) {
                TextField("Optional question for this passage", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { investigate(selected) }
                    .disabled(!canInvestigate)
                Button {
                    investigate(selected)
                } label: {
                    Label("Investigate", systemImage: "sparkle.magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canInvestigate)
                .help(canInvestigate ? "Ask an agent to investigate this passage" : investigateDisabledReason)
            }
        }
        .padding(12)
        .background(.background)
    }

    private func investigate(_ selected: TranscriptSelection) {
        guard canInvestigate else { return }
        onInvestigate(selected, question.trimmingCharacters(in: .whitespacesAndNewlines))
        question = ""
    }
}

private struct TranscriptEmptyState: View {
    let phase: ListeningPhase

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
            Text("Speech will appear here with timestamps. Select any words or a passage to investigate it without losing your place in the call.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .padding(32)
    }

    private var title: String {
        switch phase {
        case .connecting: "Connecting to the call…"
        case .listening: "Listening for speech…"
        case .failed: "The transcript is paused"
        case .idle: "Your conversation will appear here"
        }
    }
}

struct TranscriptTextDocument: Equatable {
    struct Block: Equatable {
        let entryID: String
        let bodyRange: NSRange
        let isFinal: Bool
    }

    let text: String
    let blocks: [Block]

    init(entries: [TranscriptEntry]) {
        var rendered = ""
        var blocks: [Block] = []
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"

        for entry in entries {
            if !rendered.isEmpty { rendered += "\n\n" }
            rendered += formatter.string(from: entry.timestamp) + "   "
            let start = (rendered as NSString).length
            rendered += entry.text
            let length = (entry.text as NSString).length
            if !entry.isSystemNotice { blocks.append(Block(entryID: entry.id, bodyRange: NSRange(location: start, length: length), isFinal: entry.isFinal)) }
            if !entry.isFinal { rendered += entry.wasInterrupted == true ? "  · interrupted" : "  · partial" }
        }
        text = rendered
        self.blocks = blocks
    }

    func selection(for range: NSRange) -> TranscriptSelection? {
        let source = text as NSString
        guard range.location != NSNotFound,
              range.location >= 0,
              range.length > 0,
              NSMaxRange(range) <= source.length else { return nil }

        var selectedText: [String] = []
        var entryIDs: [String] = []
        for block in blocks {
            let overlap = NSIntersectionRange(range, block.bodyRange)
            guard overlap.length > 0 else { continue }
            let part = source.substring(with: overlap).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty else { continue }
            selectedText.append(part)
            if !entryIDs.contains(block.entryID) { entryIDs.append(block.entryID) }
        }
        let passage = selectedText.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !passage.isEmpty else { return nil }
        return TranscriptSelection(text: passage, entryIDs: entryIDs)
    }

    func selectionAnchor(for range: NSRange) -> TranscriptSelectionAnchor? {
        guard selection(for: range) != nil else { return nil }
        let intersected = blocks.filter { NSIntersectionRange(range, $0.bodyRange).length > 0 }
        guard let first = intersected.first, let last = intersected.last else { return nil }
        let end = min(NSMaxRange(range), NSMaxRange(last.bodyRange))
        return TranscriptSelectionAnchor(
            startEntryID: first.entryID,
            startOffset: max(0, range.location - first.bodyRange.location),
            endEntryID: last.entryID,
            endOffset: max(0, end - last.bodyRange.location)
        )
    }

    func range(for anchor: TranscriptSelectionAnchor) -> NSRange? {
        guard let start = blocks.first(where: { $0.entryID == anchor.startEntryID }),
              let end = blocks.first(where: { $0.entryID == anchor.endEntryID }) else { return nil }
        let startOffset = min(max(anchor.startOffset, 0), start.bodyRange.length)
        let endOffset = min(max(anchor.endOffset, 0), end.bodyRange.length)
        let startLocation = start.bodyRange.location + startOffset
        let endLocation = end.bodyRange.location + endOffset
        guard endLocation > startLocation else { return nil }
        return NSRange(location: startLocation, length: endLocation - startLocation)
    }
}

struct TranscriptSelectionAnchor: Equatable {
    let startEntryID: String
    let startOffset: Int
    let endEntryID: String
    let endOffset: Int
}

struct TranscriptTextView: NSViewRepresentable {
    let entries: [TranscriptEntry]
    @Binding var selection: TranscriptSelection?

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.usesFindBar = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.textContainerInset = NSSize(width: 20, height: 18)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.delegate = context.coordinator
        scrollView.documentView = textView

        context.coordinator.update(textView, document: TranscriptTextDocument(entries: entries), externalSelection: selection)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.selection = $selection
        context.coordinator.update(textView, document: TranscriptTextDocument(entries: entries), externalSelection: selection)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var selection: Binding<TranscriptSelection?>
        private var isApplyingUpdate = false
        private var currentDocument = TranscriptTextDocument(entries: [])
        private var selectionAnchor: TranscriptSelectionAnchor?
        private var currentSelection: TranscriptSelection?

        init(selection: Binding<TranscriptSelection?>) {
            self.selection = selection
        }

        func update(_ textView: NSTextView, document: TranscriptTextDocument, externalSelection: TranscriptSelection?) {
            if let externalSelection, externalSelection != currentSelection,
               let block = document.blocks.first(where: { externalSelection.entryIDs.contains($0.entryID) }) {
                let body = (document.text as NSString).substring(with: block.bodyRange) as NSString
                let match = body.range(of: externalSelection.text)
                if match.location != NSNotFound {
                    let range = NSRange(location: block.bodyRange.location + match.location, length: match.length)
                    isApplyingUpdate = true
                    textView.textStorage?.setAttributedString(makeAttributedString(document))
                    currentDocument = document
                    textView.setSelectedRange(range)
                    selectionAnchor = document.selectionAnchor(for: range)
                    currentSelection = externalSelection
                    textView.scrollRangeToVisible(range)
                    isApplyingUpdate = false
                    return
                }
            }
            if externalSelection == nil, currentSelection != nil {
                isApplyingUpdate = true
                textView.setSelectedRange(NSRange(location: textView.selectedRange().location, length: 0))
                selectionAnchor = nil
                currentSelection = nil
                isApplyingUpdate = false
            }
            guard textView.string != document.text else {
                currentDocument = document
                return
            }
            let clipView = textView.enclosingScrollView?.contentView
            let oldOrigin = clipView?.bounds.origin ?? .zero
            let isNearBottom: Bool
            if let clipView, let documentView = textView.enclosingScrollView?.documentView {
                isNearBottom = clipView.bounds.maxY >= documentView.bounds.maxY - 72
            } else {
                isNearBottom = true
            }

            isApplyingUpdate = true
            textView.textStorage?.setAttributedString(makeAttributedString(document))
            currentDocument = document

            if let selectionAnchor, let range = document.range(for: selectionAnchor) {
                textView.setSelectedRange(range)
                currentSelection = document.selection(for: range)
                selection.wrappedValue = currentSelection
            } else {
                textView.setSelectedRange(NSRange(location: (document.text as NSString).length, length: 0))
                self.selectionAnchor = nil
                currentSelection = nil
                if selection.wrappedValue != nil { selection.wrappedValue = nil }
            }

            if isNearBottom && currentSelection == nil {
                let end = (document.text as NSString).length
                textView.scrollRangeToVisible(NSRange(location: end, length: 0))
            } else if let clipView {
                clipView.scroll(to: oldOrigin)
                textView.enclosingScrollView?.reflectScrolledClipView(clipView)
            }
            isApplyingUpdate = false
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isApplyingUpdate,
                  let textView = notification.object as? NSTextView else { return }
            selectionAnchor = currentDocument.selectionAnchor(for: textView.selectedRange())
            currentSelection = currentDocument.selection(for: textView.selectedRange())
            selection.wrappedValue = currentSelection
        }

        private func makeAttributedString(_ document: TranscriptTextDocument) -> NSAttributedString {
            let rendered = NSMutableAttributedString(
                string: document.text,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 14),
                    .foregroundColor: NSColor.labelColor
                ]
            )
            for block in document.blocks {
                let rowStart = max(0, block.bodyRange.location - 11)
                let timestampLength = min(8, (document.text as NSString).length - rowStart)
                if timestampLength > 0 {
                    rendered.addAttributes([
                        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                        .foregroundColor: NSColor.secondaryLabelColor
                    ], range: NSRange(location: rowStart, length: timestampLength))
                }
                if !block.isFinal, block.bodyRange.length > 0 {
                    rendered.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: block.bodyRange)
                    let markerLocation = NSMaxRange(block.bodyRange)
                    let markerRange = NSRange(location: markerLocation, length: min(11, rendered.length - markerLocation))
                    if markerRange.length > 0 {
                        rendered.addAttributes([
                            .font: NSFont.systemFont(ofSize: 11),
                            .foregroundColor: NSColor.tertiaryLabelColor
                        ], range: markerRange)
                    }
                }
            }
            return rendered
        }
    }
}
