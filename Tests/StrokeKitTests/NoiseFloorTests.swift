import CoreGraphics
import XCTest
@testable import StrokeKit

/// Детерминированный шум: тест не должен плавать от запуска к запуску.
private struct SeededNoise {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
    /// Примерно нормальный: сумма 12 равномерных минус 6.
    mutating func gaussian() -> Double {
        (0..<12).reduce(0.0) { sum, _ in sum + next() } - 6
    }
}

/// Три удара с длинными паузами между ними и заданным дрожанием суставов.
private func track(jitter: Double, seed: UInt64 = 7) -> PoseTrack {
    var rng = SeededNoise(seed: seed)
    let fps = 60.0
    let frames = (0..<Int(12 * fps)).map { i -> PoseFrame in
        let t = Double(i) / fps
        let x = [2.0, 6.0, 10.0].reduce(400.0) { $0 + 300 * tanh((t - $1) / 0.08) }
        var points: [BodyJoint: CGPoint] = [
            .neck: CGPoint(x: 500, y: 100), .root: CGPoint(x: 500, y: 300),
            .leftShoulder: CGPoint(x: 470, y: 120), .rightShoulder: CGPoint(x: 530, y: 120),
            .leftElbow: CGPoint(x: 430, y: 220), .rightElbow: CGPoint(x: (530 + x) / 2, y: 190),
            .leftWrist: CGPoint(x: 420, y: 300), .rightWrist: CGPoint(x: x, y: 200),
            .leftHip: CGPoint(x: 460, y: 300), .rightHip: CGPoint(x: 540, y: 300),
            .leftKnee: CGPoint(x: 460, y: 420), .rightKnee: CGPoint(x: 540, y: 420),
            .leftAnkle: CGPoint(x: 460, y: 540), .rightAnkle: CGPoint(x: 540, y: 540),
        ]
        for key in points.keys {
            points[key]!.x += jitter * rng.gaussian()
            points[key]!.y += jitter * rng.gaussian()
        }
        return PoseFrame(time: t, joints: points.mapValues { JointSample(point: $0, confidence: 0.9) })
    }
    return PoseTrack(frames: frames, displaySize: CGSize(width: 1080, height: 1920), frameRate: fps, duration: 12)
}

final class NoiseFloorTests: XCTestCase {
    func testCleanTrackHasAlmostNoNoise() {
        let analysis = StrokeAnalyzer().analyze(track: track(jitter: 0), handedness: .right)
        XCTAssertGreaterThan(analysis.noise.quietSeconds, 1)
        XCTAssertLessThan(analysis.noise.noise(for: .elbowAtContact) ?? 99, 0.5)
        XCTAssertLessThan(analysis.noise.noise(for: .contactHeight) ?? 99, 0.01)
        XCTAssertTrue(MetricKey.allCases.allSatisfy { analysis.noise.isMeasurable($0) })
    }

    func testJitterRaisesTheEstimate() {
        let quiet = StrokeAnalyzer().analyze(track: track(jitter: 0), handedness: .right).noise
        let noisy = StrokeAnalyzer().analyze(track: track(jitter: 4), handedness: .right).noise
        for key in [MetricKey.elbowAtContact, .minKneeAngle, .contactHeight, .contactDepth] {
            XCTAssertGreaterThan(noisy.noise(for: key) ?? 0, (quiet.noise(for: key) ?? 0) + 0.001, "\(key)")
        }
        // Локоть: 4 px дрожания на плече в 100 px — заметные доли градуса
        // после сглаживания, а не тысячные.
        XCTAssertGreaterThan(noisy.noise(for: .elbowAtContact) ?? 0, 0.5)
    }

    func testDrownedMetricIsNotMeasurable() {
        // Гашение по шуму проверяется подставленной оценкой: дрожание,
        // при котором угол тонет по-настоящему, у Vision не встречается,
        // а вот далёкая камера легко даёт ±15° при пороге 12.
        let plain = StrokeAnalyzer().analyze(track: track(jitter: 0), handedness: .right)
        let drowned = SessionAnalysis(
            track: plain.track, handedness: .right, cameraView: plain.cameraView,
            signals: plain.signals, strokes: plain.strokes, warnings: [],
            noise: NoiseFloor(byMetric: [.elbowAtContact: 15, .minKneeAngle: 3], quietSeconds: 4)
        )
        XCTAssertFalse(drowned.isMeasurable(.elbowAtContact))
        XCTAssertTrue(drowned.isMeasurable(.minKneeAngle))
        XCTAssertTrue(drowned.disabledMetrics.contains(.elbowAtContact))
        XCTAssertNotNil(drowned.unmeasurableReason(.elbowAtContact))
        let type = drowned.strokes[0].type
        XCTAssertFalse(drowned.ranked(of: type).contains { $0.key == .elbowAtContact })
        XCTAssertFalse(InsightEngine.insights(for: drowned, type: type).contains { $0.key == .elbowAtContact })
    }

    func testSpreadBelowTwoNoisesIsNotAnInsight() {
        // Локоть гуляет на ±14° — выше номинального порога 12, но шум ±9:
        // заметным считается только разброс от 18°.
        let plain = StrokeAnalyzer().analyze(track: track(jitter: 0), handedness: .right)
        let summary = MetricSummary(key: .elbowAtContact, values: [118, 134, 150, 118, 134, 150, 118, 150])
        XCTAssertGreaterThan(summary.standardDeviation, 12)
        XCTAssertLessThan(summary.standardDeviation, 18)
        let quiet = NoiseFloor(byMetric: [.elbowAtContact: 9], quietSeconds: 4)
        let guidance = MetricKey.elbowAtContact.guidance(for: .forehand)
        XCTAssertNil(InsightEngine.spreadInsight(summary, guidance: guidance, noise: quiet))
        XCTAssertNotNil(InsightEngine.spreadInsight(summary, guidance: guidance, noise: .unknown))
        _ = plain
    }

    func testEffectiveSpreadNeverBelowNominal() {
        let floor = NoiseFloor(byMetric: [.elbowAtContact: 2, .contactDepth: 0.2], quietSeconds: 3)
        XCTAssertEqual(floor.effectiveSpread(for: .elbowAtContact), MetricKey.elbowAtContact.noticeableSpread)
        XCTAssertEqual(floor.effectiveSpread(for: .contactDepth), 0.4, accuracy: 0.001)
        XCTAssertEqual(floor.effectiveSpread(for: .minKneeAngle), MetricKey.minKneeAngle.noticeableSpread)
    }

    func testUnknownNoiseChangesNothing() {
        XCTAssertTrue(MetricKey.allCases.allSatisfy { NoiseFloor.unknown.isMeasurable($0) })
        XCTAssertEqual(NoiseFloor.unknown.effectiveSpread(for: .elbowAtContact), 12)
    }

    func testNoQuietTimeMeansUnknown() {
        // Кисть болтается всё время — тишины нет, оценки нет, ничего не гасим.
        var rng = SeededNoise(seed: 3)
        let frames = (0..<600).map { i -> PoseFrame in
            let t = Double(i) / 60
            let wrist = CGPoint(x: 400 + 200 * sin(t * 9), y: 200 + 100 * cos(t * 7))
            let elbow = CGPoint(x: 470 + 30 * rng.gaussian(), y: 190)
            return PoseFrame(time: t, joints: [
                .neck: JointSample(point: CGPoint(x: 500, y: 100), confidence: 0.9),
                .root: JointSample(point: CGPoint(x: 500, y: 300), confidence: 0.9),
                .rightShoulder: JointSample(point: CGPoint(x: 530, y: 120), confidence: 0.9),
                .rightElbow: JointSample(point: elbow, confidence: 0.9),
                .rightWrist: JointSample(point: wrist, confidence: 0.9),
                .rightHip: JointSample(point: CGPoint(x: 540, y: 300), confidence: 0.9),
            ])
        }
        let track = PoseTrack(frames: frames, displaySize: CGSize(width: 1080, height: 1920), frameRate: 60, duration: 10)
        let analysis = StrokeAnalyzer().analyze(track: track, handedness: .right)
        XCTAssertEqual(analysis.noise.quietSeconds, 0)
        XCTAssertTrue(analysis.noise.byMetric.isEmpty)
    }
}
