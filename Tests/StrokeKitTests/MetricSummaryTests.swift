import XCTest
@testable import StrokeKit

final class MetricSummaryTests: XCTestCase {
    func testRangeIgnoresMissingValues() {
        // Регрессия: краш на устройстве. Длительность замаха не считается,
        // когда замаха не видно, и массив значений содержит NaN. Сравнения
        // с NaN ложны, поэтому min() и max() возвращали границы в обратном
        // порядке, а построение диапазона роняло приложение.
        let summary = MetricSummary(
            key: .backswingDuration,
            values: [0.3, .nan, 0.5, .nan, 0.4]
        )
        guard let range = summary.range else { return XCTFail("диапазон потерялся") }
        XCTAssertEqual(range.lowerBound, 0.3, accuracy: 0.001)
        XCTAssertEqual(range.upperBound, 0.5, accuracy: 0.001)
    }

    func testRangeWithLeadingNaNDoesNotInvert() {
        // Порядок важен: именно с NaN в начале min() возвращал NaN.
        let summary = MetricSummary(key: .elbowAtContact, values: [.nan, 120, 90, 150])
        guard let range = summary.range else { return XCTFail("диапазон потерялся") }
        XCTAssertEqual(range.lowerBound, 90, accuracy: 0.001)
        XCTAssertEqual(range.upperBound, 150, accuracy: 0.001)
    }

    func testAllMissingGivesNoRange() {
        let summary = MetricSummary(key: .backswingDuration, values: [.nan, .nan])
        XCTAssertNil(summary.range)
        XCTAssertTrue(summary.mean.isNaN)
    }

    func testEmptyGivesNoRange() {
        XCTAssertNil(MetricSummary(key: .peakWristSpeed, values: []).range)
    }

    func testSingleValueIsAValidRange() {
        let summary = MetricSummary(key: .peakWristSpeed, values: [7.5, .nan])
        XCTAssertEqual(summary.range?.lowerBound, 7.5)
        XCTAssertEqual(summary.range?.upperBound, 7.5)
        XCTAssertEqual(summary.standardDeviation, 0, accuracy: 0.001)
    }

    func testStatisticsSkipMissingValues() {
        let summary = MetricSummary(key: .peakWristSpeed, values: [10, .nan, 20])
        XCTAssertEqual(summary.mean, 15, accuracy: 0.001)
        XCTAssertTrue(summary.standardDeviation.isFinite)
    }
}
