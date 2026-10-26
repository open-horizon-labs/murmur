import AppKit
import XCTest
@testable import MurmurApp
@testable import MurmurCore

final class WindowFrameFitTests: XCTestCase {
    func testPreservesFrameThatAlreadyFits() {
        let frame = CGRect(x: 40, y: 70, width: 1000, height: 720)
        XCTAssertEqual(WindowFrameFit.fit(frame, inside: CGRect(x: 0, y: 0, width: 1440, height: 900)), frame)
    }

    func testMovesAndShrinksRestoredFrameIntoVisibleArea() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let restored = CGRect(x: 1320, y: -40, width: 1000, height: 720)

        let fitted = WindowFrameFit.fit(restored, inside: visible)

        XCTAssertEqual(fitted, CGRect(x: 440, y: 0, width: 1000, height: 720))
        XCTAssertTrue(visible.contains(fitted))
    }

    func testShrinksOnlyWhenWindowExceedsVisibleDimensions() {
        let visible = CGRect(x: 100, y: 50, width: 800, height: 600)
        let fitted = WindowFrameFit.fit(CGRect(x: 90, y: 40, width: 900, height: 700), inside: visible)

        XCTAssertEqual(fitted, visible)
    }
}
