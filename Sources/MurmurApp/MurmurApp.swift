import SwiftUI

@main
struct MurmurApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(MurmurQuitDelegate.self) private var quitDelegate

    var body: some Scene {
        Window("Murmur", id: "main") {
            CompanionView(model: model)
                .frame(minWidth: 760, minHeight: 520)
                .background(WindowFrameProbe().frame(width: 0, height: 0))
                .onAppear { quitDelegate.model = model }
        }
        .defaultSize(width: 1000, height: 720)
        .defaultPosition(.center)
        .windowResizability(.contentMinSize)

        MenuBarExtra("Murmur", systemImage: menuBarSymbol) {
            MenuBarControls(model: model)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarSymbol: String {
        model.phase.isActive ? "waveform.circle.fill" : "waveform.circle"
    }
}

@MainActor
private final class MurmurQuitDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var isPreparingToTerminate = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isPreparingToTerminate else { return .terminateLater }
        guard let model else {
            showQuitError("Murmur is still opening. Keep it open and try quitting again once the window is ready.", model: nil)
            return .terminateCancel
        }

        isPreparingToTerminate = true
        Task { @MainActor [weak self, weak model] in
            guard let self else { return }
            let canTerminate = if let model { await model.prepareForQuit() } else { false }
            self.isPreparingToTerminate = false
            sender.reply(toApplicationShouldTerminate: canTerminate)
            if !canTerminate {
                self.showQuitError(model?.persistenceError ?? "Murmur could not save the current conversation.", model: model)
            }
        }
        return .terminateLater
    }

    private func showQuitError(_ message: String, model: AppModel?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Murmur couldn't save before quitting"
        alert.informativeText = message
        if model != nil {
            alert.addButton(withTitle: "Retry Save & Quit")
            alert.addButton(withTitle: "Keep Open")
        } else {
            alert.addButton(withTitle: "Keep Open")
        }
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn, let model else { return }
        Task { @MainActor [weak model] in
            guard let model else { return }
            await model.retrySave()
            // Start a fresh AppKit termination request so prepareForQuit flushes
            // the retried revision before the app receives a positive reply.
            NSApp.terminate(nil)
        }
    }
}

enum WindowFrameFit {
    static func fit(_ frame: CGRect, inside visibleFrame: CGRect) -> CGRect {
        let width = min(frame.width, visibleFrame.width)
        let height = min(frame.height, visibleFrame.height)
        let originX = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - width)
        let originY = min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - height)
        return CGRect(x: originX, y: originY, width: width, height: height)
    }
}

private struct WindowFrameProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> InitialWindowFrameView {
        InitialWindowFrameView()
    }

    func updateNSView(_ view: InitialWindowFrameView, context: Context) {}
}

@MainActor
private final class InitialWindowFrameView: NSView {
    private var hasFittedInitialWindow = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !hasFittedInitialWindow, let window else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, !self.hasFittedInitialWindow, let window else { return }
            let screens = NSScreen.screens
            let frame = window.frame
            let screen = screens.max { lhs, rhs in
                frame.intersection(lhs.visibleFrame).area < frame.intersection(rhs.visibleFrame).area
            } ?? NSScreen.main
            guard let visibleFrame = screen?.visibleFrame else { return }
            let fitted = WindowFrameFit.fit(frame, inside: visibleFrame)
            if fitted != frame {
                window.setFrame(fitted, display: true)
            }
            self.hasFittedInitialWindow = true
        }
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
