import CoreGraphics
import XCTest
@testable import StrokeKit

/// Сводка тренировки из готовых чисел — движку прогресса нужны только они.
private func digest(
    _ metrics: [MetricKey: (mean: Double, spread: Double, count: Int)],
    type: StrokeType = .forehand,
    strokeCount: Int? = nil,
    noise: [MetricKey: Double] = [:],
    cameraView: CameraView = .side
) -> SessionDigest {
    let count = strokeCount ?? metrics.values.map(\.count).max() ?? 0
    let built = metrics.mapValues { MetricDigest(mean: $0.mean, spread: $0.spread, count: $0.count) }
    return SessionDigest(
        cameraView: cameraView,
        quietSeconds: 3,
        noise: noise,
        types: [type: TypeDigest(strokeCount: count, metrics: built)]
    )
}

private func series(_ digests: [SessionDigest]) -> [ProgressSession] {
    digests.enumerated().map { index, digest in
        ProgressSession(
            id: UUID(),
            date: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 86_400),
            digest: digest
        )
    }
}

private func trend(_ digests: [SessionDigest], _ key: MetricKey, type: StrokeType = .forehand) -> MetricTrend? {
    ProgressEngine.trends(in: series(digests), type: type).first { $0.key == key }
}

final class ProgressEngineTests: XCTestCase {

    // MARK: - Разброс

    func testSmallSpreadChangeOnFewStrokesIsInconclusive() {
        // Главное обещание экрана. Разброс, посчитанный по восьми ударам,
        // знает себя с точностью 27%: ±18° и ±13° по восьми ударам —
        // это одно и то же измерение, хотя выглядит как заметный прогресс.
        let trend = trend([
            digest([.elbowAtContact: (mean: 140, spread: 18, count: 8)]),
            digest([.elbowAtContact: (mean: 140, spread: 13, count: 8)]),
        ], .elbowAtContact)
        XCTAssertEqual(trend?.spread.verdict, .inconclusive)
    }

    func testBigSpreadDropOnManyStrokesIsImprovement() {
        let trend = trend([
            digest([.elbowAtContact: (mean: 140, spread: 18, count: 20)]),
            digest([.elbowAtContact: (mean: 140, spread: 7, count: 20)]),
        ], .elbowAtContact)
        XCTAssertEqual(trend?.spread.verdict, .improved)
        XCTAssertGreaterThan(trend?.spread.ratio ?? 0, 1)
    }

    func testSpreadGrowthIsCalledOut() {
        let trend = trend([
            digest([.elbowAtContact: (mean: 140, spread: 7, count: 25)]),
            digest([.elbowAtContact: (mean: 140, spread: 18, count: 25)]),
        ], .elbowAtContact)
        XCTAssertEqual(trend?.spread.verdict, .worsened)
    }

    func testSameSpreadOnManyStrokesIsStillInconclusive() {
        let trend = trend([
            digest([.elbowAtContact: (mean: 140, spread: 12, count: 30)]),
            digest([.elbowAtContact: (mean: 140, spread: 12, count: 30)]),
        ], .elbowAtContact)
        XCTAssertEqual(trend?.spread.verdict, .inconclusive)
        XCTAssertEqual(trend?.spread.delta, 0)
    }

    // MARK: - Среднее

    func testMeanShiftBelowNoiseIsInconclusive() {
        // По случайной погрешности сдвиг на 0.07 корпуса на двадцати ударах
        // достоверен. Но прибор на этой записи мерил с шумом ±0.12 — значит,
        // не достоверен: камеру подвинуть дешевле, чем поменять технику.
        let trend = trend([
            digest([.contactDepth: (mean: 0.40, spread: 0.05, count: 20)], noise: [.contactDepth: 0.12]),
            digest([.contactDepth: (mean: 0.47, spread: 0.05, count: 20)], noise: [.contactDepth: 0.12]),
        ], .contactDepth)
        XCTAssertEqual(trend?.mean.verdict, .inconclusive)
    }

    func testSameMeanShiftOnQuietFootageIsImprovement() {
        // Та же пара чисел, но запись тихая: вывод появляется.
        let trend = trend([
            digest([.contactDepth: (mean: 0.40, spread: 0.05, count: 20)], noise: [.contactDepth: 0.02]),
            digest([.contactDepth: (mean: 0.47, spread: 0.05, count: 20)], noise: [.contactDepth: 0.02]),
        ], .contactDepth)
        XCTAssertEqual(trend?.mean.verdict, .improved)
    }

    func testMeanDropOnDirectedMetricIsWorsening() {
        let trend = trend([
            digest([.contactDepth: (mean: 0.50, spread: 0.05, count: 20)]),
            digest([.contactDepth: (mean: 0.30, spread: 0.05, count: 20)]),
        ], .contactDepth)
        XCTAssertEqual(trend?.mean.verdict, .worsened)
    }

    func testMeanShiftWithoutDirectionIsJustAChange() {
        // У угла локтя «правильного» значения нет — только разброс.
        let trend = trend([
            digest([.elbowAtContact: (mean: 130, spread: 5, count: 20)]),
            digest([.elbowAtContact: (mean: 150, spread: 5, count: 20)]),
        ], .elbowAtContact)
        XCTAssertEqual(trend?.mean.verdict, .changed)
    }

    func testGrowthBeyondTheBandIsNotProgress() {
        // «Больше — лучше, до разумного предела»: 120° → 140° разворота
        // плеч уже за ориентиром, и хвалить тут не за что.
        let trend = trend([
            digest([.shoulderRotationRange: (mean: 120, spread: 5, count: 20)]),
            digest([.shoulderRotationRange: (mean: 140, spread: 5, count: 20)]),
        ], .shoulderRotationRange)
        XCTAssertEqual(trend?.mean.verdict, .changed)
    }

    func testGrowthTowardTheBandIsProgress() {
        let trend = trend([
            digest([.shoulderRotationRange: (mean: 50, spread: 5, count: 20)]),
            digest([.shoulderRotationRange: (mean: 75, spread: 5, count: 20)]),
        ], .shoulderRotationRange)
        XCTAssertEqual(trend?.mean.verdict, .improved)
    }

    // MARK: - Отбор тренировок в ряд

    func testTypeNeedsTwoSessionsToBeCompared() {
        let sessions = series([
            digest([.elbowAtContact: (mean: 140, spread: 10, count: 10)], type: .forehand),
            digest([.elbowAtContact: (mean: 140, spread: 10, count: 10)], type: .backhand),
        ])
        XCTAssertTrue(ProgressEngine.types(in: sessions).isEmpty)
    }

    func testMostFrequentTypeComesFirst() {
        let sessions = series([
            SessionDigest(cameraView: .side, quietSeconds: 3, noise: [:], types: [
                .forehand: TypeDigest(strokeCount: 6, metrics: [:]),
                .backhand: TypeDigest(strokeCount: 20, metrics: [:]),
            ]),
            SessionDigest(cameraView: .side, quietSeconds: 3, noise: [:], types: [
                .forehand: TypeDigest(strokeCount: 6, metrics: [:]),
                .backhand: TypeDigest(strokeCount: 20, metrics: [:]),
            ]),
        ])
        XCTAssertEqual(ProgressEngine.types(in: sessions), [.backhand, .forehand])
    }

    func testUnrecognisedStrokesAreNotATypeToTrack() {
        let sessions = series([
            digest([.elbowAtContact: (mean: 140, spread: 10, count: 10)], type: .unknown),
            digest([.elbowAtContact: (mean: 140, spread: 10, count: 10)], type: .unknown),
        ])
        XCTAssertTrue(ProgressEngine.types(in: sessions).isEmpty)
    }

    func testThinSessionDoesNotEnterTheSeries() {
        // Четыре удара — не тренировка: в разборе по ним и выводов не делают.
        let sessions = series([
            digest([.elbowAtContact: (mean: 140, spread: 10, count: 10)], strokeCount: 10),
            digest([.elbowAtContact: (mean: 120, spread: 4, count: 4)], strokeCount: 4),
            digest([.elbowAtContact: (mean: 140, spread: 10, count: 10)], strokeCount: 10),
        ])
        let trend = ProgressEngine.trends(in: sessions, type: .forehand).first { $0.key == .elbowAtContact }
        XCTAssertEqual(trend?.points.count, 2)
    }

    func testMetricMissingFromOneSessionSkipsThatPoint() {
        // Ракурс сменился — глубина контакта в одной из записей не мерялась.
        let sessions = series([
            digest([.contactDepth: (mean: 0.4, spread: 0.05, count: 10)]),
            digest([.elbowAtContact: (mean: 140, spread: 10, count: 10)], cameraView: .behind),
            digest([.contactDepth: (mean: 0.5, spread: 0.05, count: 10)]),
        ])
        let trend = ProgressEngine.trends(in: sessions, type: .forehand).first { $0.key == .contactDepth }
        XCTAssertEqual(trend?.points.count, 2)
    }

    func testSingleSessionGivesNoTrends() {
        let sessions = series([digest([.elbowAtContact: (mean: 140, spread: 10, count: 10)])])
        XCTAssertTrue(ProgressEngine.trends(in: sessions, type: .forehand).isEmpty)
    }

    func testOverallComparisonAppearsOnlyFromThirdSession() {
        let two = trend([
            digest([.elbowAtContact: (mean: 140, spread: 18, count: 20)]),
            digest([.elbowAtContact: (mean: 140, spread: 14, count: 20)]),
        ], .elbowAtContact)
        XCTAssertNil(two?.overall)

        let three = trend([
            digest([.elbowAtContact: (mean: 140, spread: 18, count: 20)]),
            digest([.elbowAtContact: (mean: 140, spread: 14, count: 20)]),
            digest([.elbowAtContact: (mean: 140, spread: 7, count: 20)]),
        ], .elbowAtContact)
        XCTAssertEqual(three?.overall?.verdict, .improved)
    }

    func testCertainFindingsComeFirst() {
        let sessions = series([
            digest([
                .elbowAtContact: (mean: 140, spread: 18, count: 20),
                .minKneeAngle: (mean: 140, spread: 12, count: 20),
            ]),
            digest([
                .elbowAtContact: (mean: 140, spread: 7, count: 20),
                .minKneeAngle: (mean: 140, spread: 11, count: 20),
            ]),
        ])
        let trends = ProgressEngine.trends(in: sessions, type: .forehand)
        XCTAssertEqual(trends.first?.key, .elbowAtContact)
    }
}

final class SessionDigestTests: XCTestCase {
    func testSurvivesJSONRoundTrip() throws {
        let original = digest(
            [.elbowAtContact: (mean: 140.5, spread: 12.25, count: 9)],
            noise: [.elbowAtContact: 6.5]
        )
        let restored = try JSONDecoder().decode(
            SessionDigest.self, from: JSONEncoder().encode(original)
        )
        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.type(.forehand)?.metric(.elbowAtContact)?.mean, 140.5)
        XCTAssertEqual(restored.noise(for: .elbowAtContact), 6.5)
    }

    func testBuiltFromAnalysisSkipsWhatTheAnalysisItselfHides() {
        // Глубина контакта из-за спины не меряется, и в разборе её не видно.
        // Попасть в ряд прогресса она не должна тем более.
        let rows = (0..<8).map { i -> [MetricKey: Double] in
            [
                .peakWristSpeed: 8 + Double(i) * 0.1,
                .elbowAtContact: 140 + Double(i % 3) * 4,
                .contactDepth: 0.5,
                .backswingDuration: .nan,
            ]
        }
        let built = SessionDigest(analysisStub(rows, cameraView: .behind))
        XCTAssertNotNil(built.type(.forehand)?.metric(.elbowAtContact))
        XCTAssertNil(built.type(.forehand)?.metric(.contactDepth), "глубина из-за спины не меряется")
        XCTAssertNil(built.type(.forehand)?.metric(.backswingDuration), "замаха не было видно ни разу")
        XCTAssertEqual(built.type(.forehand)?.strokeCount, 8)
        XCTAssertTrue(built.isCurrent)
    }

    func testNoisyMetricDoesNotEnterTheDigest() {
        let rows = (0..<8).map { _ in [MetricKey.elbowAtContact: 140.0] }
        let noisy = NoiseFloor(byMetric: [.elbowAtContact: 30], quietSeconds: 3)
        let built = SessionDigest(analysisStub(rows, noise: noisy))
        XCTAssertNil(built.type(.forehand)?.metric(.elbowAtContact))
    }
}

/// Разбор из готовых значений метрик — как в тестах движка выводов.
private func analysisStub(
    _ rows: [[MetricKey: Double]],
    cameraView: CameraView = .side,
    noise: NoiseFloor = .unknown
) -> SessionAnalysis {
    let empty = Signal(times: [], values: [])
    let signals = AnalyzedSignals(
        times: [], wristSpeed: empty, elbowAngle: empty, shoulderAngle: empty,
        hipAngle: empty, kneeAngle: empty, wristX: empty, wristY: empty,
        hipX: empty, hipY: empty, torsoScale: 200, torsoScaleSeries: empty, cutIndices: []
    )
    let phases = StrokePhases(start: 0, transition: 1, contact: 2, end: 3, hasBackswing: false)
    let shape = StrokeShape(
        forwardDisplacement: 2, forwardPath: 2, followThrough: 1, prominence: 4, hasBackswing: false
    )
    let strokes = rows.enumerated().map { index, values in
        Stroke(
            id: index, type: .forehand, shape: shape, doubts: [], ballContact: nil, phases: phases,
            startTime: Double(index), contactTime: Double(index) + 0.5, endTime: Double(index) + 1,
            values: values
        )
    }
    return SessionAnalysis(
        track: PoseTrack(
            frames: [], displaySize: CGSize(width: 1080, height: 1920), frameRate: 60, duration: 10
        ),
        handedness: .right, cameraView: cameraView, signals: signals,
        strokes: strokes, warnings: [], noise: noise
    )
}
