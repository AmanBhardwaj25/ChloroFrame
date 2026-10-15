//
//  CodecRegressionTests.swift
//  ChloroFrameTests
//
//  The codec regression run: phase list, HDR expectation, verdict rules and config decoding.
//

import XCTest
@testable import ChloroFrame

final class CodecRegressionTests: XCTestCase {

    private func result(codec: String = "h265", received: VideoCodec? = .hevc, fps: Double = 60,
                        seconds: Int = 300, expectedHdr: Bool = false, receivedHdr: Bool? = false,
                        lostTotal: Int = 0) -> PyroWaveExperimentReport.PhaseResult {
        var r = PyroWaveExperimentReport.PhaseResult(
            name: "x", partialDelivery: true, lossPercent: 0, burstLength: 1, seconds: Double(seconds),
            fps: [], start: PyroWaveExperimentSample(), end: PyroWaveExperimentSample(), failure: nil)
        r.codec = codec
        r.receivedCodec = received
        r.requestedFps = 60
        r.expectedHdr = expectedHdr
        r.receivedHdr = receivedHdr
        r.samples = (0..<seconds).map { i in
            var s = CodecSecondSample()
            s.fps = fps
            s.framesLost = i == seconds - 1 ? lostTotal : 0
            return s
        }
        return r
    }

    func testPhasesCoverEveryCodecWithHDROffAndOn() {
        let phases = CodecRegression.phases(minutes: 5)
        XCTAssertEqual(phases.count, 8)
        XCTAssertEqual(Set(phases.compactMap(\.codec)), ["h264", "h265", "av1", "pyrowave"])
        for codec in CodecRegression.codecs {
            XCTAssertEqual(phases.filter { $0.codec == codec }.compactMap(\.hdr).sorted { !$0 && $1 }, [false, true])
        }
        XCTAssertTrue(phases.allSatisfy { $0.minutes == 5 })
    }

    func testHDRIsExpectedOnlyForHDRCodecsOnAnHDRDisplay() {
        XCTAssertFalse(CodecRegression.expectsHDR(codecSetting: "h264", hdrRequested: true, displayHDR: true))
        XCTAssertTrue(CodecRegression.expectsHDR(codecSetting: "pyrowave", hdrRequested: true, displayHDR: true))
        XCTAssertFalse(CodecRegression.expectsHDR(codecSetting: "av1", hdrRequested: true, displayHDR: false))
        XCTAssertFalse(CodecRegression.expectsHDR(codecSetting: "h265", hdrRequested: false, displayHDR: true))
    }

    func testCleanRunPasses() {
        XCTAssertEqual(CodecRegression.verdict(result()).grade, .pass)
    }

    func testDowngradedCodecFails() {
        let v = CodecRegression.verdict(result(codec: "av1", received: .hevc))
        XCTAssertEqual(v.grade, .fail)
        XCTAssertTrue(v.reasons.joined().contains("asked for AV1, got HEVC"))
    }

    func testLowFrameRateFails() {
        XCTAssertEqual(CodecRegression.verdict(result(fps: 50)).grade, .fail)
    }

    func testMissingHDRAndLossOnlyWarn() {
        XCTAssertEqual(CodecRegression.verdict(result(expectedHdr: true, receivedHdr: false)).grade, .warn)
        XCTAssertEqual(CodecRegression.verdict(result(lostTotal: 10)).grade, .warn, "2 lost/min over 5 min")
        XCTAssertEqual(CodecRegression.verdict(result(lostTotal: 4)).grade, .pass, "0.8 lost/min")
    }

    func testNotMeasuredFails() {
        var r = result()
        r.failure = "no stream within 90 s"
        XCTAssertEqual(CodecRegression.verdict(r).grade, .fail)
        XCTAssertTrue(CodecRegression.format(r).contains("FAIL"))
    }

    func testConfigDecodesCodecPhasesWithoutPartialDeliveryKey() throws {
        let json = #"{"quitWhenDone": true, "phases": [{"name": "a", "minutes": 5, "codec": "av1", "hdr": true}]}"#
        let cfg = try JSONDecoder().decode(PyroWaveExperimentConfig.self, from: Data(json.utf8))
        XCTAssertEqual(cfg.phases.first?.codec, "av1")
        XCTAssertEqual(cfg.phases.first?.hdr, true)
        XCTAssertEqual(cfg.phases.first?.partialDelivery, true)
    }

    func testReportAndSummaryNameTheGrade() {
        let r = result()
        XCTAssertTrue(CodecRegression.format(r).contains("===== x: PASS ====="))
        XCTAssertTrue(CodecRegression.summaryTable([r]).contains("PASS"))
    }
}
