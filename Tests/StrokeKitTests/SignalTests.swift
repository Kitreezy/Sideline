import XCTest
@testable import StrokeKit

final class SignalTests: XCTestCase {
    private func times(_ count: Int, step: Double = 0.01) -> [Double] {
        (0..<count).map { Double($0) * step }
    }

    func testShortGapIsInterpolated() {
        let signal = Signal(times: times(5), values: [0, .nan, .nan, .nan, 4])
        let filled = SignalProcessing.interpolateGaps(signal, maxGapSeconds: 0.2)
        XCTAssertEqual(filled.values[1], 1, accuracy: 0.001)
        XCTAssertEqual(filled.values[2], 2, accuracy: 0.001)
        XCTAssertEqual(filled.values[3], 3, accuracy: 0.001)
    }

    func testLongGapIsLeftAsUnknown() {
        // Дыру в полсекунды выдумывать нельзя — там могло произойти что угодно.
        let signal = Signal(times: times(60), values: [0] + [Double](repeating: .nan, count: 58) + [59])
        let filled = SignalProcessing.interpolateGaps(signal, maxGapSeconds: 0.2)
        XCTAssertTrue(filled.values[30].isNaN)
    }

    func testEdgesAreNotExtrapolated() {
        let signal = Signal(times: times(4), values: [.nan, 1, 2, .nan])
        let filled = SignalProcessing.interpolateGaps(signal)
        XCTAssertTrue(filled.values[0].isNaN)
        XCTAssertTrue(filled.values[3].isNaN)
    }

    func testDerivativeOfLineIsSlope() {
        let t = times(20, step: 0.1)
        let signal = Signal(times: t, values: t.map { $0 * 3 })
        let d = SignalProcessing.derivative(signal)
        XCTAssertEqual(d.values[10], 3, accuracy: 0.001)
    }

    func testPeaksAreSeparated() {
        // Два острых пика в 1 секунде друг от друга плюс мелкий шум между ними.
        let t = times(300, step: 0.01)
        let values = t.map { time -> Double in
            let a = exp(-pow((time - 0.5) / 0.05, 2)) * 10
            let b = exp(-pow((time - 1.5) / 0.05, 2)) * 8
            return a + b + 0.1
        }
        let peaks = SignalProcessing.findPeaks(
            Signal(times: t, values: values), minHeight: 2, minSeparation: 0.6
        )
        XCTAssertEqual(peaks.count, 2)
        XCTAssertEqual(t[peaks[0]], 0.5, accuracy: 0.03)
        XCTAssertEqual(t[peaks[1]], 1.5, accuracy: 0.03)
    }

    func testNearbyPeaksCollapseToTheTallest() {
        let t = times(200, step: 0.01)
        let values = t.map { time -> Double in
            exp(-pow((time - 0.5) / 0.03, 2)) * 5 + exp(-pow((time - 0.6) / 0.03, 2)) * 9
        }
        let peaks = SignalProcessing.findPeaks(
            Signal(times: t, values: values), minHeight: 2, minSeparation: 0.6
        )
        XCTAssertEqual(peaks.count, 1)
        XCTAssertEqual(t[peaks[0]], 0.6, accuracy: 0.03)
    }
}
