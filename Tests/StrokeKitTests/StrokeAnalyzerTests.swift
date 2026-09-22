import CoreGraphics
import XCTest
@testable import StrokeKit

/// Синтетическое видео: неподвижный корпус и кисть, которая делает три резких
/// прохода. Настоящего видео тут нет, зато точно известно, где контакт.
private func makeSyntheticTrack(
    contactTimes: [Double] = [0.6, 1.8, 3.0],
    fps: Double = 120,
    duration: Double = 4.0
) -> PoseTrack {
    let frameCount = Int(duration * fps)
    var frames: [PoseFrame] = []

    for i in 0..<frameCount {
        let t = Double(i) / fps
        // Каждый удар — резкий проход кисти слева направо.
        let wristX = contactTimes.reduce(400.0) { partial, tc in
            partial + 300 * tanh((t - tc) / 0.08)
        }
        let wrist = CGPoint(x: wristX, y: 200)
        let shoulder = CGPoint(x: 550, y: 120)
        let elbow = CGPoint(
            x: (shoulder.x + wrist.x) / 2,
            y: (shoulder.y + wrist.y) / 2 + 30
        )

        let points: [BodyJoint: CGPoint] = [
            .neck: CGPoint(x: 500, y: 100),
            .root: CGPoint(x: 500, y: 300),
            .leftShoulder: CGPoint(x: 450, y: 120),
            .rightShoulder: shoulder,
            .leftElbow: CGPoint(x: 430, y: 220),
            .rightElbow: elbow,
            .leftWrist: CGPoint(x: 420, y: 300),
            .rightWrist: wrist,
            .leftHip: CGPoint(x: 460, y: 300),
            .rightHip: CGPoint(x: 540, y: 300),
            .leftKnee: CGPoint(x: 460, y: 420),
            .rightKnee: CGPoint(x: 540, y: 420),
            .leftAnkle: CGPoint(x: 460, y: 540),
            .rightAnkle: CGPoint(x: 540, y: 540),
        ]

        frames.append(
            PoseFrame(
                time: t,
                joints: points.mapValues { JointSample(point: $0, confidence: 0.9) }
            )
        )
    }

    return PoseTrack(
        frames: frames,
        displaySize: CGSize(width: 1080, height: 1920),
        frameRate: fps,
        duration: duration
    )
}

final class StrokeAnalyzerTests: XCTestCase {
    func testFindsEveryStroke() {
        let analysis = StrokeAnalyzer().analyze(track: makeSyntheticTrack(), handedness: .right)
        XCTAssertEqual(analysis.strokes.count, 3)
    }

    func testContactLandsOnTheFastestMoment() {
        let expected = [0.6, 1.8, 3.0]
        let analysis = StrokeAnalyzer().analyze(
            track: makeSyntheticTrack(contactTimes: expected), handedness: .right
        )
        XCTAssertEqual(analysis.strokes.count, expected.count)
        for (stroke, want) in zip(analysis.strokes, expected) {
            XCTAssertEqual(stroke.contactTime, want, accuracy: 0.03)
        }
    }

    func testPhasesAreOrdered() {
        let analysis = StrokeAnalyzer().analyze(track: makeSyntheticTrack(), handedness: .right)
        for stroke in analysis.strokes {
            XCTAssertLessThanOrEqual(stroke.phases.start, stroke.phases.transition)
            XCTAssertLessThan(stroke.phases.transition, stroke.phases.contact)
            XCTAssertLessThan(stroke.phases.contact, stroke.phases.end)
        }
    }

    func testSpeedIsNormalisedByBodySize() {
        // То же движение, снятое «вдвое ближе», должно дать ту же скорость в корпусах.
        let near = StrokeAnalyzer().analyze(track: makeSyntheticTrack(), handedness: .right)

        let scaled = makeSyntheticTrack()
        let doubled = PoseTrack(
            frames: scaled.frames.map { frame in
                PoseFrame(
                    time: frame.time,
                    joints: frame.joints.mapValues {
                        JointSample(
                            point: CGPoint(x: $0.point.x * 2, y: $0.point.y * 2),
                            confidence: $0.confidence
                        )
                    }
                )
            },
            displaySize: CGSize(width: 2160, height: 3840),
            frameRate: scaled.frameRate,
            duration: scaled.duration
        )
        let far = StrokeAnalyzer().analyze(track: doubled, handedness: .right)

        XCTAssertEqual(near.strokes.count, far.strokes.count)
        for (a, b) in zip(near.strokes, far.strokes) {
            XCTAssertEqual(
                a.value(.peakWristSpeed), b.value(.peakWristSpeed), accuracy: 0.05,
                "скорость не должна зависеть от расстояния до камеры"
            )
        }
    }

    func testIdenticalStrokesLookPerfectlyStable() {
        let analysis = StrokeAnalyzer().analyze(track: makeSyntheticTrack(), handedness: .right)
        let typeSummaries = analysis.summaries(of: analysis.strokes[0].type)
        guard let speed = typeSummaries.first(where: { $0.key == .peakWristSpeed }) else {
            return XCTFail("нет сводки по скорости")
        }
        XCTAssertLessThan(speed.standardDeviation, 0.2)
    }

    func testStillVideoHasNoStrokes() {
        let still = makeSyntheticTrack(contactTimes: [], fps: 120, duration: 2)
        let analysis = StrokeAnalyzer().analyze(track: still, handedness: .right)
        XCTAssertTrue(analysis.strokes.isEmpty)
    }

    func testLowFrameRateIsCalledOut() {
        let analysis = StrokeAnalyzer().analyze(
            track: makeSyntheticTrack(fps: 30), handedness: .right
        )
        XCTAssertTrue(analysis.warnings.contains { $0.text.contains("кадрах в секунду") })
    }

    // MARK: - Склейки

    /// Сдвигает всего человека вбок начиная с заданного момента — так выглядит
    /// склейка монтажа или перескок Vision на другого человека в кадре.
    private func trackWithCut(at cutTime: Double) -> PoseTrack {
        let base = makeSyntheticTrack()
        let frames = base.frames.map { frame -> PoseFrame in
            guard frame.time >= cutTime else { return frame }
            return PoseFrame(
                time: frame.time,
                joints: frame.joints.mapValues {
                    JointSample(
                        point: CGPoint(x: $0.point.x + 600, y: $0.point.y),
                        confidence: $0.confidence
                    )
                }
            )
        }
        return PoseTrack(
            frames: frames,
            displaySize: base.displaySize,
            frameRate: base.frameRate,
            duration: base.duration
        )
    }

    func testCutIsDetected() {
        let analysis = StrokeAnalyzer().analyze(track: trackWithCut(at: 2.4), handedness: .right)
        XCTAssertFalse(analysis.signals.cutIndices.isEmpty)
    }

    func testCutDoesNotBecomeAStroke() {
        // Телепорт на 3 корпуса за кадр — это скорость, которая перебьёт любой
        // настоящий удар, если её не выбросить.
        let analysis = StrokeAnalyzer().analyze(track: trackWithCut(at: 2.4), handedness: .right)
        XCTAssertEqual(analysis.strokes.count, 3)
        for stroke in analysis.strokes {
            XCTAssertGreaterThan(
                abs(stroke.contactTime - 2.4), 0.1,
                "склейка не должна превращаться в удар"
            )
        }
    }

    func testStrokeWindowStopsAtCut() {
        // Склейка сразу после удара: проводка обязана обрезаться по ней.
        let analysis = StrokeAnalyzer().analyze(track: trackWithCut(at: 1.9), handedness: .right)
        guard let stroke = analysis.strokes.first(where: { abs($0.contactTime - 1.8) < 0.1 }) else {
            return XCTFail("удар на 1.8 с потерялся")
        }
        XCTAssertLessThanOrEqual(stroke.endTime, 1.95)
    }

    func testCompilationIsCalledOut() {
        // Нарезка: после каждой склейки игрок стоит в другом месте кадра
        // и остаётся там. Сдвиг на один кадр — это дрожание, а не склейка.
        let base = makeSyntheticTrack().frames
        let cutTimes = [0.9, 1.3, 2.2, 2.7, 3.4]
        let frames = base.map { frame -> PoseFrame in
            let shifts = cutTimes.filter { frame.time >= $0 }.count
            let dx = CGFloat(shifts % 2 == 0 ? 0 : 900)
            return PoseFrame(
                time: frame.time,
                joints: frame.joints.mapValues {
                    JointSample(point: CGPoint(x: $0.point.x + dx, y: $0.point.y), confidence: $0.confidence)
                }
            )
        }
        let track = PoseTrack(frames: frames, displaySize: CGSize(width: 1080, height: 1920), frameRate: 120, duration: 4)
        let analysis = StrokeAnalyzer().analyze(track: track, handedness: .right)
        XCTAssertGreaterThanOrEqual(analysis.signals.cutIndices.count, cutTimes.count)
        XCTAssertTrue(analysis.warnings.contains { $0.text.contains("скелет пропадает") })
    }

    func testSingleFrameGlitchIsNotACut() {
        // Один кадр улетел и вернулся — так дрожит трекинг на мелком игроке.
        var frames = makeSyntheticTrack().frames
        let index = Int(2.4 * 120)
        frames[index] = PoseFrame(
            time: frames[index].time,
            joints: frames[index].joints.mapValues {
                JointSample(point: CGPoint(x: $0.point.x + 900, y: $0.point.y), confidence: $0.confidence)
            }
        )
        let track = PoseTrack(frames: frames, displaySize: CGSize(width: 1080, height: 1920), frameRate: 120, duration: 4)
        let analysis = StrokeAnalyzer().analyze(track: track, handedness: .right)
        XCTAssertTrue(analysis.signals.cutIndices.isEmpty, "\(analysis.signals.cutIndices)")
    }

    func testThresholdRisesWithNoisyFootage() {
        // Если игрок всё время машет руками, порог обязан подняться сам.
        let quiet = Signal(times: (0..<100).map { Double($0) * 0.01 }, values: [Double](repeating: 0.2, count: 100))
        let busy = Signal(times: (0..<100).map { Double($0) * 0.01 }, values: [Double](repeating: 4.0, count: 100))
        let quietThreshold = StrokeAnalyzer.strokeThreshold(quiet, floor: 2.0, medianFactor: 3.0)
        let busyThreshold = StrokeAnalyzer.strokeThreshold(busy, floor: 2.0, medianFactor: 3.0)
        XCTAssertEqual(quietThreshold, 2.0, accuracy: 0.001)
        XCTAssertEqual(busyThreshold, 12.0, accuracy: 0.001)
    }
}
