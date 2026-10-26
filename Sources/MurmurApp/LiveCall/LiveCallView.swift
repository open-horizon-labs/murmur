import MurmurCore
import SwiftUI

/// The live-call window: idle (readiness and start), call (two panes), ended (saved, with the notes still readable).
struct LiveCallView: View {
    var model: LiveCallModel

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(model: model)
            Divider()
            if let banner = model.banner {
                NoticeStrip(text: banner)
                Divider()
            }
            if model.isCallScreen {
                CallPanes(model: model)
            } else {
                IdleView(model: model)
            }
        }
        .background(LiveTheme.background)
        .frame(minWidth: 520, minHeight: 440)
        .task { await model.refreshReadiness() }
    }
}

/// A calm strip, not a dialog: something is degraded and what still works.
private struct NoticeStrip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(LiveTheme.ui(13))
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LiveTheme.warnSoft)
            .accessibilityLabel(text)
    }
}

/// Transcript left, notes right; below 760 pt they stack with the notes (and Catch me up) first.
private struct CallPanes: View {
    var model: LiveCallModel

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width < 760 {
                VStack(spacing: 0) {
                    NotesPane(model: model)
                    Divider()
                    TranscriptPane(model: model)
                        .frame(minHeight: 240)
                }
            } else {
                HStack(spacing: 0) {
                    TranscriptPane(model: model)
                        .frame(maxWidth: .infinity)
                    Divider()
                    NotesPane(model: model)
                        .frame(minWidth: 320, idealWidth: 400, maxWidth: 480)
                }
            }
        }
    }
}

private struct IdleView: View {
    var model: LiveCallModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Know what was said, and what is waiting on you.")
                    .font(LiveTheme.ui(28, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("Murmur transcribes your call on this computer as people speak and keeps notes you can check against the transcript.")
                    .font(LiveTheme.ui(16))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 16)
                ReadinessList(rows: model.readiness)
                    .padding(.bottom, 16)
                StartActions(model: model)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.init(top: 56, leading: 24, bottom: 40, trailing: 24))
        }
    }
}

/// Start call and Try a sample call; the sample is the filled button until a first call has been made.
private struct StartActions: View {
    var model: LiveCallModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if model.hasSeenCall {
                    startButton.buttonStyle(.borderedProminent)
                    sampleButton.buttonStyle(.bordered)
                } else {
                    startButton.buttonStyle(.bordered)
                    sampleButton.buttonStyle(.borderedProminent)
                }
            }
            .tint(LiveTheme.accent)
            Text("The sample uses no audio and sends nothing out.")
                .font(LiveTheme.ui(13))
                .foregroundStyle(.secondary)
        }
    }

    private var startButton: some View {
        Button("Start call") { model.startCall() }
            .disabled(!model.canStart)
    }

    private var sampleButton: some View {
        Button("Try a sample call") { model.startSample() }
    }
}
