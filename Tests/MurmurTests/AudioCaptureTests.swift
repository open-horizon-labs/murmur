import CoreMedia
import Foundation
import XCTest
@testable import MurmurApp
@testable import MurmurCore

final class AudioCaptureTests: XCTestCase {
    func testMixerAlignsOffsetSourcesAndPreservesUnevenChunkTails() throws {
        let mixer = PCM16Mixer()
        let system = Array(repeating: Int16(100), count: 4_800)
        let microphoneFirst = Array(repeating: Int16(1_000), count: 2_388)
        let microphoneSecond = Array(repeating: Int16(2_000), count: 2_400)

        XCTAssertNil(mixer.push(data(system), at: time(0), from: .system))
        XCTAssertNil(mixer.push(data(microphoneFirst), at: time(12), from: .microphone))

        XCTAssertNil(mixer.push(data(microphoneSecond), at: time(2_400), from: .microphone))
        // Advance the clock beyond the largest input chunk; the held samples
        // must still contain both sources, including the shorter chunk's tail.
        let first = try decode(XCTUnwrap(mixer.push(data(Array(repeating: Int16.zero, count: 2_400)), at: time(4_800), from: .system)))
        XCTAssertEqual(first.count, 2_400)
        XCTAssertEqual(Array(first.prefix(12)), Array(repeating: Int16(100), count: 12))
        XCTAssertEqual(Array(first.dropFirst(12)), Array(repeating: Int16(1_100), count: 2_388))

        let second = try decode(XCTUnwrap(mixer.push(data(Array(repeating: Int16.zero, count: 2_400)), at: time(7_200), from: .system)))
        XCTAssertEqual(second, Array(repeating: Int16(2_100), count: 2_400))
        let third = try decode(XCTUnwrap(mixer.push(data(Array(repeating: Int16.zero, count: 2_400)), at: time(9_600), from: .system)))
        XCTAssertEqual(third, Array(repeating: Int16.zero, count: 2_400))
    }

    func testMixerKeepsSingleSourceSamplesWhenOtherSourceIsMissing() throws {
        let mixer = PCM16Mixer()
        let samples = Array(repeating: Int16(37), count: 4_800)

        XCTAssertNil(mixer.push(data(samples), at: time(0), from: .microphone))
        let output = try decode(XCTUnwrap(mixer.push(data(samples), at: time(4_800), from: .microphone)))

        XCTAssertEqual(output, Array(repeating: Int16(37), count: 4_800))
    }

    func testSilentSourceDoesNotEraseTheOtherInput() throws {
        let mixer = PCM16Mixer()
        XCTAssertNil(mixer.push(data(Array(repeating: Int16.zero, count: 4_800)), at: time(0), from: .system))

        XCTAssertNil(mixer.push(
            data(Array(repeating: Int16(123), count: 4_800)),
            at: time(0),
            from: .microphone
        ))
        let output = try decode(XCTUnwrap(mixer.push(
            data(Array(repeating: Int16.zero, count: 4_800)), at: time(4_800), from: .system
        )))

        XCTAssertEqual(output, Array(repeating: Int16(123), count: 4_800))
    }

    func testResetDiscardsThePreviousCaptureTimeline() {
        let mixer = PCM16Mixer()
        XCTAssertNil(mixer.push(data(Array(repeating: Int16(9), count: 2_400)), at: time(0), from: .microphone))
        mixer.reset()

        XCTAssertNil(mixer.push(data(Array(repeating: Int16(5), count: 2_400)), at: time(0), from: .microphone))
        XCTAssertEqual(mixer.push(data(Array(repeating: Int16(0), count: 2_400)), at: time(2_400), from: .system)?.count, 4_800)
    }

    private func time(_ sample: Int64) -> CMTime {
        CMTime(value: sample, timescale: 24_000)
    }

    private func data(_ samples: [Int16]) -> Data {
        samples.withUnsafeBytes { Data($0) }
    }

    private func decode(_ data: Data) throws -> [Int16] {
        XCTAssertEqual(data.count % MemoryLayout<Int16>.size, 0)
        return data.withUnsafeBytes { $0.bindMemory(to: Int16.self).map { $0 } }
    }
}
