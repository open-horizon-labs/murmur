import AppKit
import SwiftUI
import Foundation
import XCTest
@testable import MurmurApp

final class TranscriptViewTests: XCTestCase {
    func testSelectionMapsAcrossEntriesWithoutIncludingTimestamps() throws {
        let document = TranscriptTextDocument(entries: [
            entry("first", "Hello world"),
            entry("second", "Hello again")
        ])
        let first = try XCTUnwrap(document.blocks.first)
        let last = try XCTUnwrap(document.blocks.last)
        let start = first.bodyRange.location + 6
        let selectedRange = NSRange(location: start, length: NSMaxRange(last.bodyRange) - start)

        let selection = try XCTUnwrap(document.selection(for: selectedRange))

        XCTAssertEqual(selection.text, "world Hello again")
        XCTAssertEqual(selection.entryIDs, ["first", "second"])
        XCTAssertNil(document.selection(for: NSRange(location: 0, length: 8)))
    }

    func testSelectionAnchorSurvivesTranscriptAppendAndRepeatedPassage() throws {
        let original = TranscriptTextDocument(entries: [
            entry("first", "Repeated words"),
            entry("second", "Repeated words")
        ])
        let second = try XCTUnwrap(original.blocks.last)
        let anchor = try XCTUnwrap(original.selectionAnchor(for: second.bodyRange))

        let updated = TranscriptTextDocument(entries: [
            entry("first", "Repeated words"),
            entry("second", "Repeated words"),
            entry("third", "New speech arrives")
        ])
        let restoredRange = try XCTUnwrap(updated.range(for: anchor))
        let restoredSelection = try XCTUnwrap(updated.selection(for: restoredRange))

        XCTAssertEqual(restoredSelection.text, "Repeated words")
        XCTAssertEqual(restoredSelection.entryIDs, ["second"])
    }

    func testSelectionOffsetsUseUTF16AndIgnorePartialMarker() throws {
        let partialDocument = TranscriptTextDocument(entries: [
            entry("partial", "🧭 Acme rollout", isFinal: false)
        ])
        let block = try XCTUnwrap(partialDocument.blocks.first)
        let body = partialDocument.text as NSString
        let acme = body.range(of: "Acme")
        let selection = try XCTUnwrap(partialDocument.selection(for: acme))
        let anchor = try XCTUnwrap(partialDocument.selectionAnchor(for: acme))
        let markerRange = NSRange(location: NSMaxRange(block.bodyRange) + 1, length: 9)

        XCTAssertEqual(selection.text, "Acme")
        XCTAssertEqual(anchor.startOffset, 3) // The compass occupies two UTF-16 code units.
        XCTAssertNil(partialDocument.selection(for: markerRange))
    }

    @MainActor
    func testCitationSelectsExactEntryAndSurvivesAppend() throws {
        var selected: TranscriptSelection?
        let coordinator = TranscriptTextView.Coordinator(selection: Binding(
            get: { selected }, set: { selected = $0 }
        ))
        let view = NSTextView()
        let entries = [entry("first", "🧭 Repeated words"), entry("second", "🧭 Repeated words")]
        let document = TranscriptTextDocument(entries: entries)
        let citation = TranscriptSelection(text: "Repeated words", entryIDs: ["second"])
        selected = citation
        coordinator.update(view, document: document, externalSelection: citation)
        XCTAssertEqual(document.selection(for: view.selectedRange())?.entryIDs, ["second"])
        XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), "Repeated words")

        let appended = TranscriptTextDocument(entries: entries + [entry("third", "New speech")])
        coordinator.update(view, document: appended, externalSelection: citation)
        XCTAssertEqual(appended.selection(for: view.selectedRange())?.entryIDs, ["second"])
        XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), "Repeated words")
    }

    func testEvidenceLinksStayInsideCanonicalWorkspace() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let inWorkspace = root.appendingPathComponent("notes.md")
        try Data("workspace file".utf8).write(to: inWorkspace)
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).md")
        try Data("outside file".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let symlink = root.appendingPathComponent("linked.md")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)

        XCTAssertEqual(WorkspaceEvidenceLink.fileURL(path: "notes.md#L4-6", workspace: root), inWorkspace.resolvingSymlinksInPath())
        XCTAssertNil(WorkspaceEvidenceLink.fileURL(path: "../outside-\(outside.lastPathComponent)", workspace: root))
        XCTAssertNil(WorkspaceEvidenceLink.fileURL(path: "linked.md", workspace: root))
        XCTAssertNil(WorkspaceEvidenceLink.fileURL(path: outside.path, workspace: root))
    }

    private func entry(_ id: String, _ text: String, isFinal: Bool = true) -> TranscriptEntry {
        TranscriptEntry(id: id, timestamp: Date(timeIntervalSince1970: 1_700_000_000), text: text, isFinal: isFinal)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MurmurTranscriptTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
