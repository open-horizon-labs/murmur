import AppKit
import MurmurCore
import SwiftUI

/// Call state, elapsed time, provenance, level meters and the one primary control.
struct HeaderBar: View {
    var model: LiveCallModel

    var body: some View {
        HStack(spacing: 20) {
            Text("Live Call")
                .font(LiveTheme.ui(15, weight: .semibold))
            StatusLabel(model: model)
            Text(model.provenanceText)
                .font(LiveTheme.ui(12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
            Spacer(minLength: 0)
            if model.phase == .listening || model.phase == .stopping {
                LevelMeters(levels: model.levels)
            }
            if model.isEnded {
                CopyNotesButton(model: model)
            }
            if model.isCallScreen {
                PrimaryCallButton(model: model)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(LiveTheme.surface)
    }
}

private struct StatusLabel: View {
    var model: LiveCallModel

    private var showsClock: Bool { model.phase == .listening || model.phase == .stopping }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.phase == .listening ? LiveTheme.ok : Color.secondary)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(model.statusText)
                .font(LiveTheme.ui(13))
                .foregroundStyle(model.phase == .listening ? Color.primary : Color.secondary)
            if showsClock {
                Text("· " + model.elapsedText)
                    .font(LiveTheme.ui(13))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 150, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(showsClock ? "\(model.statusText), \(model.elapsedText) elapsed" : model.statusText)
    }
}

/// Two thin bars, "me" and "them", that move only with real audio. Decorative for VoiceOver.
struct LevelMeters: View {
    let levels: [String: Double]

    var body: some View {
        HStack(spacing: 14) {
            LevelMeter(name: "me", level: levels["me"] ?? 0)
            LevelMeter(name: "them", level: levels["them"] ?? 0)
        }
        .accessibilityHidden(true)
    }
}

private struct LevelMeter: View {
    let name: String
    let level: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let trackWidth: CGFloat = 56

    var body: some View {
        HStack(spacing: 6) {
            Text(name)
                .font(LiveTheme.ui(12))
                .foregroundStyle(.secondary)
            ZStack(alignment: .leading) {
                Capsule().fill(LiveTheme.line)
                Capsule()
                    .fill(LiveTheme.accent)
                    .frame(width: trackWidth * CGFloat(max(0, min(1, level))))
                    .animation(reduceMotion ? nil : .linear(duration: 0.09), value: level)
            }
            .frame(width: trackWidth, height: 4)
        }
    }
}

private struct CopyNotesButton: View {
    var model: LiveCallModel

    var body: some View {
        Button(model.copied ? "Copied" : "Copy notes") {
            let board = NSPasteboard.general
            board.clearContents()
            board.setString(model.notesClipboardText, forType: .string)
            model.markCopied()
        }
        .buttonStyle(.bordered)
        .accessibilityHint("Copies the notes, or the transcript when there are no notes")
    }
}

/// Filled while it starts something, quiet outline while it stops the call (as on the web page).
private struct PrimaryCallButton: View {
    var model: LiveCallModel

    var body: some View {
        Group {
            if model.phase == .listening {
                Button(model.primaryTitle) { run() }
                    .buttonStyle(.bordered)
            } else {
                Button(model.primaryTitle) { run() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .tint(LiveTheme.accent)
        .disabled(!model.primaryEnabled)
    }

    private func run() {
        Task { await model.primaryAction() }
    }
}
