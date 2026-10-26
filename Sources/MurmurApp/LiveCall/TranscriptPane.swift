import MurmurCore
import SwiftUI

/// The transcript: newest at the bottom, pinned unless the reader scrolls up.
struct TranscriptPane: View {
    var model: LiveCallModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var userIsScrolling = false

    private static let bottomID = "transcript-bottom"
    private var partialSpeakers: [String] { model.partials.keys.sorted() }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.entries) { entry in
                        TranscriptLine(entry: entry, isHighlighted: model.highlightedEntryID == entry.id)
                            .id(entry.id)
                            .transition(reduceMotion ? AnyTransition.identity : AnyTransition.opacity.combined(with: AnyTransition.offset(y: 3)))
                    }
                    ForEach(partialSpeakers, id: \.self) { speaker in
                        PartialLine(speaker: speaker, text: model.partials[speaker] ?? "")
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(.vertical, 8)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: model.entries.count)
            }
            .onScrollPhaseChange { _, phase in
                userIsScrolling = (phase == .tracking || phase == .interacting || phase == .decelerating)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height < 80
            } action: { _, nearBottom in
                // Content growing under a pinned reader is not the reader scrolling away.
                if userIsScrolling || nearBottom { model.pinnedToLatest = nearBottom }
            }
            .onChange(of: model.entries.count) { _, _ in followIfPinned(proxy) }
            .onChange(of: model.partials) { _, _ in followIfPinned(proxy) }
            .onChange(of: model.scrollRequest) { _, request in
                guard let request else { return }
                proxy.scrollTo(request.entryID, anchor: .center)
            }
            .overlay(alignment: .bottom) {
                if !model.pinnedToLatest {
                    Button("Jump to latest") {
                        model.jumpToLatest()
                        proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.primary)
                    .controlSize(.small)
                    .padding(.bottom, 12)
                }
            }
        }
        .background(LiveTheme.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transcript")
    }

    private func followIfPinned(_ proxy: ScrollViewProxy) {
        guard model.pinnedToLatest else { return }
        proxy.scrollTo(Self.bottomID, anchor: .bottom)
    }
}

/// One finished line: speaker and time on the left (me on the right edge of the gutter, in the accent), text in a serif.
private struct TranscriptLine: View {
    let entry: LiveEntry
    let isHighlighted: Bool

    private var isMe: Bool { entry.speaker == "me" }

    var body: some View {
        LineLayout(speaker: entry.speaker, time: LiveEntry.clock(entry.start), text: entry.text, isMe: isMe, isPartial: false)
            .background(isHighlighted ? LiveTheme.accentSoft : Color.clear)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(entry.speaker), \(LiveEntry.clock(entry.start)): \(entry.text)")
    }
}

/// Words still being recognized; replaced by the finished line when it arrives.
private struct PartialLine: View {
    let speaker: String
    let text: String

    var body: some View {
        LineLayout(speaker: speaker, time: "", text: text + " …", isMe: speaker == "me", isPartial: true)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(speaker), still speaking: \(text)")
    }
}

private struct LineLayout: View {
    let speaker: String
    let time: String
    let text: String
    let isMe: Bool
    let isPartial: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(speaker)
                    .font(LiveTheme.ui(13, weight: .semibold))
                    .foregroundStyle(isMe ? LiveTheme.accent : Color.primary)
                Text(time)
                    .font(LiveTheme.ui(12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .frame(width: 74, alignment: .trailing)
            Text(text)
                .font(LiveTheme.reading(17, weight: isMe && !isPartial ? .semibold : .regular))
                .foregroundStyle(isPartial ? Color.secondary : Color.primary)
                .lineSpacing(5)
                .textSelection(.enabled)
                .frame(maxWidth: 560, alignment: .leading)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}
