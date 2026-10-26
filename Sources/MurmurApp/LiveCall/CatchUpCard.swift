import MurmurCore
import SwiftUI

/// "Catch me up": a window picker, one control, and a recap that says what is waiting on you first.
struct CatchUpCard: View {
    @Bindable var model: LiveCallModel

    private static let windows = [2, 5, 10, 20]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.isEnded {
                controls
            }
            content
        }
        .padding(.init(top: 14, leading: 16, bottom: 16, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LiveTheme.raised, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(LiveTheme.line, lineWidth: 1))
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                Task { await model.catchUp() }
            } label: {
                HStack(spacing: 8) {
                    Text(model.isSummarizing ? "Summarizing…" : "Catch me up")
                    Text("C")
                        .font(LiveTheme.ui(12))
                        .padding(.horizontal, 5)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.5), lineWidth: 1))
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(LiveTheme.accent)
            .keyboardShortcut("c", modifiers: [])
            .disabled(!model.canCatchUp)
            .accessibilityLabel(model.isSummarizing ? "Summarizing" : "Catch me up")
            .accessibilityHint("Summarizes the last few minutes and lists what is waiting on you. Shortcut: C")
            Spacer(minLength: 0)
            Picker("How far back", selection: $model.recapMinutes) {
                ForEach(Self.windows, id: \.self) { minutes in
                    Text("\(minutes) min").tag(minutes)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 230)
            .accessibilityLabel("How far back")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.recapError {
            Text(error + " Try again.")
                .font(LiveTheme.ui(12))
                .foregroundStyle(LiveTheme.warn)
        }
        if let recap = model.recap {
            RecapBody(model: model, recap: recap)
        } else if model.recapError == nil {
            Text("Lost the thread? This summarizes the last few minutes and lists what is waiting on you.")
                .font(LiveTheme.ui(13))
                .foregroundStyle(.secondary)
        }
    }
}

private struct RecapBody: View {
    var model: LiveCallModel
    let recap: LiveRecap

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                WaitingOnYou(model: model, asks: recap.asks)
                Text(recap.now)
                    .font(LiveTheme.reading(17, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(recap.points) { point in
                    RecapPoint(model: model, point: point)
                }
            }
            .opacity(model.isRecapStale ? 0.55 : 1)
            AsOfLine(model: model)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct RecapPoint: View {
    var model: LiveCallModel
    let point: LiveRecapPoint

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•").font(LiveTheme.reading(17))
            VStack(alignment: .leading, spacing: 2) {
                Text(point.text)
                    .font(LiveTheme.reading(17))
                    .fixedSize(horizontal: false, vertical: true)
                if !point.entries.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(point.entries, id: \.self) { entry in
                            QuoteChip(label: String(entry), entry: entry) { model.reveal(entry: $0) }
                        }
                    }
                }
            }
        }
    }
}

/// "Waiting on you" comes first: asks aimed at you that nobody has answered.
private struct WaitingOnYou: View {
    var model: LiveCallModel
    let asks: [LiveAsk]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(asks.isEmpty ? "Nothing waiting on you." : "Waiting on you")
                .font(LiveTheme.ui(13, weight: .semibold))
            ForEach(asks) { ask in
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(ask.text)
                        .font(LiveTheme.reading(16))
                        .fixedSize(horizontal: false, vertical: true)
                    if let entry = ask.entry {
                        QuoteChip(label: model.snippet(forEntry: entry), entry: entry) { model.reveal(entry: $0) }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(asks.isEmpty ? LiveTheme.accentSoft : LiveTheme.warnSoft, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}

private struct AsOfLine: View {
    var model: LiveCallModel

    var body: some View {
        if let asOf = model.recapAsOfText {
            HStack(spacing: 0) {
                Text(asOf)
                if let hint = model.staleHint {
                    Text(" · ")
                    Text(hint).fontWeight(.semibold).foregroundStyle(LiveTheme.warn)
                }
            }
            .font(LiveTheme.ui(13))
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
    }
}
