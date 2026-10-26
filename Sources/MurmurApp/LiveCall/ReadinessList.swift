import MurmurCore
import SwiftUI

/// "Before you start": one row per check, each with what works, what does not, and the fix.
struct ReadinessList: View {
    let rows: [ReadinessRow]

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            ForEach(rows) { row in
                ReadinessRowView(row: row)
                Divider()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Before you start")
    }
}

private struct ReadinessRowView: View {
    let row: ReadinessRow

    private var stateWord: String {
        switch row.state {
        case .ok: "ready"
        case .warn: "needs attention"
        case .fail: "not ready"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(LiveTheme.color(for: row.state))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(row.label)
                .font(LiveTheme.ui(14, weight: .semibold))
                .frame(width: 110, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.detail)
                    .font(LiveTheme.ui(14))
                if !row.fix.isEmpty {
                    Text(row.fix)
                        .font(LiveTheme.ui(13))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.label), \(stateWord). \(row.detail) \(row.fix)")
    }
}
