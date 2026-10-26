import MurmurCore
import SwiftUI

/// An inline quote that scrolls the transcript to its entry and highlights the line.
struct QuoteChip: View {
    let label: String
    let entry: Int
    let reveal: (Int) -> Void

    var body: some View {
        Button {
            reveal(entry)
        } label: {
            Text(label)
                .font(LiveTheme.ui(13))
                .foregroundStyle(LiveTheme.accent)
                .underline()
                .multilineTextAlignment(.leading)
                .lineLimit(3)
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
                .frame(minHeight: 24, alignment: .leading)
        }
        .buttonStyle(.plain)
        .help("Show in transcript")
        .accessibilityLabel("Show in transcript: \(label)")
    }
}

/// "Proposed" and "No quote" tags.
struct NoteTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(LiveTheme.ui(11, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(LiveTheme.warnSoft, in: RoundedRectangle(cornerRadius: 4))
    }
}
