import AppKit
import SwiftUI
import XCTest
@testable import MurmurApp
@testable import MurmurCore

@MainActor
final class AgentMarkdownTests: XCTestCase {
    func testPreservesBlockStructureAndInlineFormatting() throws {
        let parsed = try AgentMarkdownParser().attributedString(for: Self.fixture)
        let kinds = parsed.runs.flatMap { $0.presentationIntent?.components.map(\.kind) ?? [] }
        XCTAssertTrue(kinds.contains { if case .header(level: 2) = $0 { true } else { false } })
        XCTAssertTrue(kinds.contains { if case .orderedList = $0 { true } else { false } })
        XCTAssertTrue(kinds.contains { if case .unorderedList = $0 { true } else { false } })
        XCTAssertTrue(kinds.contains { if case .blockQuote = $0 { true } else { false } })
        XCTAssertTrue(kinds.contains { if case .codeBlock = $0 { true } else { false } })
        XCTAssertTrue(kinds.contains { if case .table = $0 { true } else { false } })
        XCTAssertTrue(parsed.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        let paragraphs = Set(parsed.runs.compactMap { run in
            run.presentationIntent?.components.first(where: { if case .paragraph = $0.kind { true } else { false } })?.identity
        })
        XCTAssertGreaterThan(paragraphs.count, 4)
        XCTAssertTrue(parsed.runs.contains { ($0.presentationIntent?.components.filter { if case .unorderedList = $0.kind { true } else { false } }.count ?? 0) == 2 })
    }

    func testLinksAndImagesKeepReadableLabelsWithoutExternalResources() throws {
        let parsed = try AgentMarkdownParser().attributedString(for: "## Evidence\n\n[Read the file](file:///private/example) and ![chart description](https://example.invalid/tracker.png).\n\nNext paragraph.")
        XCTAssertFalse(parsed.runs.contains { $0.link != nil || $0.imageURL != nil })
        XCTAssertTrue(String(parsed.characters).contains("Read the file"))
        XCTAssertTrue(String(parsed.characters).contains("chart description"))
        XCTAssertTrue(parsed.runs.contains { $0.presentationIntent?.components.contains(where: { if case .header = $0.kind { true } else { false } }) == true })
    }

    func testOptInOfflineMarkdownPreviews() throws {
        guard let directory = ProcessInfo.processInfo.environment["MURMUR_MARKDOWN_PREVIEWS"] else {
            throw XCTSkip("Set MURMUR_MARKDOWN_PREVIEWS to render standalone fixtures without opening Murmur.")
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for width in [320, 640] {
            for dark in [false, true] {
                let view = AgentMarkdownView(markdown: Self.fixture)
                    .padding(20)
                    .frame(width: CGFloat(width), alignment: .topLeading)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: view)
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.frame = NSRect(x: 0, y: 0, width: width, height: 1600)
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                let size = host.fittingSize
                XCTAssertGreaterThan(size.height, 300, "Markdown should lay out multiple distinct blocks")
                XCTAssertLessThanOrEqual(size.width, CGFloat(width) + 1)
                host.setFrameSize(size)
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("context-\(width)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    private static let fixture = """
    ## Understanding

    A **mobile trading product** needs reliable pricing and a clear delivery scope. The estimate remains conditional on agreed requirements.

    This is a separate paragraph, with *emphasis* and `inline code`.

    ## Decisions & next steps

    - Keep the data platform separate from the money path.
      - Confirm the interface with the trading team.
      - Agree on ownership before implementation.
    - Review the proposal after the call.

    1. Share the design notes.
    2. Schedule the systems discussion.

    > Two to three months is an estimate, not an agreed deadline.

    ## Open questions

    | Topic | Status |
    | --- | --- |
    | Feed latency | Needs measurement |
    | Delivery scope | Awaiting review |

    ```swift
    let nextStep = "Review requirements"
    print(nextStep)
    ```

    A hard line break follows here.  
    This must start on a new line.
    """
}
