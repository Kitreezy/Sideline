import CoreGraphics
import XCTest
@testable import StrokeKit

/// Сессия из готовых значений метрик — движку выводов нужны только они.
private func session(
    _ rows: [[MetricKey: Double]],
    type: StrokeType = .forehand,
    cameraView: CameraView = .side
) -> SessionAnalysis {
    let empty = Signal(times: [], values: [])
    let signals = AnalyzedSignals(
        times: [], wristSpeed: empty, elbowAngle: empty, shoulderAngle: empty,
        hipAngle: empty, kneeAngle: empty, wristX: empty, wristY: empty,
        hipX: empty, hipY: empty, torsoScale: 200, cutIndices: []
    )
    let phases = StrokePhases(start: 0, transition: 1, contact: 2, end: 3, hasBackswing: false)
    let shape = StrokeShape(forwardDisplacement: 2, forwardPath: 2, followThrough: 1, prominence: 4, hasBackswing: false)
    let strokes = rows.enumerated().map { index, values in
        Stroke(
            id: index, type: type, shape: shape, doubts: [], phases: phases,
            startTime: Double(index), contactTime: Double(index) + 0.5, endTime: Double(index) + 1,
            values: values
        )
    }
    return SessionAnalysis(
        track: PoseTrack(frames: [], displaySize: CGSize(width: 1080, height: 1920), frameRate: 60, duration: 10),
        handedness: .right, cameraView: cameraView, signals: signals, strokes: strokes, warnings: []
    )
}

/// Ровный, «правильный» удар — база, от которой отклоняем одну метрику.
private func decentStroke(speed: Double = 8) -> [MetricKey: Double] {
    [
        .peakWristSpeed: speed, .elbowAtContact: 140, .shoulderRotationRange: 80,
        .maxSeparation: 30, .contactHeight: 0.7, .contactDepth: 0.5,
        .minKneeAngle: 130, .backswingDuration: 0.4, .forwardSwingDuration: 0.2,
    ]
}

final class InsightEngineTests: XCTestCase {
    func testTooFewStrokesGiveNoInsights() {
        let analysis = session(Array(repeating: decentStroke(), count: 4))
        XCTAssertTrue(InsightEngine.insights(for: analysis, type: .forehand).isEmpty)
    }

    func testDecentSeriesHasNothingToComplainAbout() {
        let rows = (0..<8).map { i -> [MetricKey: Double] in
            var row = decentStroke(speed: 8 + Double(i) * 0.05)
            row[.elbowAtContact] = 140 + Double(i % 2) * 2   // шум, не разброс
            return row
        }
        let insights = InsightEngine.insights(for: session(rows), type: .forehand)
        XCTAssertTrue(insights.isEmpty, "\(insights.map(\.title))")
    }

    func testLateContactIsReportedAsShortfall() {
        // Контакт на уровне бедра на каждом ударе — самая частая ошибка.
        let rows = (0..<8).map { _ in
            var row = decentStroke()
            row[.contactDepth] = 0.05
            return row
        }
        let insights = InsightEngine.insights(for: session(rows), type: .forehand)
        XCTAssertEqual(insights.first?.key, .contactDepth)
        XCTAssertEqual(insights.first?.kind, .shortfall)
        XCTAssertNotNil(insights.first?.cue)
    }

    func testWanderingElbowIsReportedAsSpread() {
        let rows = (0..<8).map { i in
            var row = decentStroke()
            row[.elbowAtContact] = i % 2 == 0 ? 90 : 170
            return row
        }
        let insights = InsightEngine.insights(for: session(rows), type: .forehand)
        XCTAssertEqual(insights.first?.key, .elbowAtContact)
        XCTAssertEqual(insights.first?.kind, .spread)
    }

    func testBestStrokesAreComparedWithWorst() {
        // Быстрые удары — с разворотом плеч, слабые — без. Всё остальное ровно.
        let rows = (0..<9).map { i -> [MetricKey: Double] in
            var row = decentStroke(speed: Double(i) + 5)
            row[.shoulderRotationRange] = i >= 6 ? 95 : (i < 3 ? 35 : 65)
            return row
        }
        let insights = InsightEngine.insights(for: session(rows), type: .forehand)
        let comparison = insights.first { $0.kind == .bestVsWorst }
        XCTAssertNotNil(comparison, "\(insights.map(\.title))")
        XCTAssertEqual(comparison?.key, .shoulderRotationRange)
    }

    func testDepthIsNeverJudgedFromBehind() {
        // Сзади глубины в кадре нет — и выводов по ней быть не должно,
        // какими бы плохими ни были числа.
        let rows = (0..<8).map { _ in
            var row = decentStroke()
            row[.contactDepth] = -0.5
            return row
        }
        let insights = InsightEngine.insights(for: session(rows, cameraView: .behind), type: .forehand)
        XCTAssertFalse(insights.contains { $0.key == .contactDepth })
    }

    func testOneInsightPerMetric() {
        // Локоть и гуляет, и у лучших ударов другой — но место одно.
        let rows = (0..<9).map { i -> [MetricKey: Double] in
            var row = decentStroke(speed: Double(i) + 5)
            row[.elbowAtContact] = i >= 6 ? 170 : (i < 3 ? 90 : 130 + Double(i % 2) * 30)
            return row
        }
        let insights = InsightEngine.insights(for: session(rows), type: .forehand)
        XCTAssertEqual(insights.filter { $0.key == .elbowAtContact }.count, 1)
    }

    func testNoMoreThanThree() {
        let rows = (0..<8).map { i -> [MetricKey: Double] in
            var row = decentStroke()
            row[.contactDepth] = 0.0
            row[.minKneeAngle] = 175
            row[.shoulderRotationRange] = 20
            row[.elbowAtContact] = i % 2 == 0 ? 90 : 170
            return row
        }
        XCTAssertLessThanOrEqual(InsightEngine.insights(for: session(rows), type: .forehand).count, 3)
    }

    func testStableMetricIsAcknowledged() {
        let rows = (0..<8).map { i -> [MetricKey: Double] in
            var row = decentStroke()
            row[.contactHeight] = 0.7 + Double(i % 2) * 0.01
            return row
        }
        let strength = InsightEngine.strength(for: session(rows), type: .forehand)
        XCTAssertNotNil(strength)
        XCTAssertEqual(strength?.kind, .strength)
    }

    func testRejectedStrokesDoNotInfluenceInsights() {
        var analysis = session((0..<8).map { _ in decentStroke() } + [{
            var bad = decentStroke()
            bad[.contactDepth] = -3   // одно чудовищное значение
            return bad
        }()])
        let outlier = analysis.strokes.last!
        analysis.setRejected(true, for: outlier)
        let insights = InsightEngine.insights(for: analysis, type: .forehand)
        XCTAssertFalse(insights.contains { $0.key == .contactDepth }, "\(insights.map(\.title))")
    }
}
