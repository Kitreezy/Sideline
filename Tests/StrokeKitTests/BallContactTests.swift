import CoreGraphics
import XCTest
@testable import StrokeKit

/// Один удар: кисть проходит tanh-разгон с контактом (пиком скорости) в 1.5 с.
/// Корпус 200 px, кисть у контакта около x=400.
private func swingTrack(fps: Double = 120, duration: Double = 3) -> PoseTrack {
    let frames = (0..<Int(duration * fps)).map { i -> PoseFrame in
        let t = Double(i) / fps
        let wrist = CGPoint(x: 400 + 300 * tanh((t - 1.5) / 0.08), y: 200)
        let points: [BodyJoint: CGPoint] = [
            .neck: CGPoint(x: 500, y: 100), .root: CGPoint(x: 500, y: 300),
            .leftShoulder: CGPoint(x: 450, y: 120), .rightShoulder: CGPoint(x: 550, y: 120),
            .leftElbow: CGPoint(x: 430, y: 220), .rightElbow: CGPoint(x: (550 + wrist.x) / 2, y: 190),
            .leftWrist: CGPoint(x: 420, y: 300), .rightWrist: wrist,
            .leftHip: CGPoint(x: 460, y: 300), .rightHip: CGPoint(x: 540, y: 300),
            .leftKnee: CGPoint(x: 460, y: 420), .rightKnee: CGPoint(x: 540, y: 420),
            .leftAnkle: CGPoint(x: 460, y: 540), .rightAnkle: CGPoint(x: 540, y: 540),
        ]
        return PoseFrame(time: t, joints: points.mapValues { JointSample(point: $0, confidence: 0.9) })
    }
    return PoseTrack(frames: frames, displaySize: CGSize(width: 1080, height: 1920), frameRate: fps, duration: duration)
}

private func trajectory(from start: CGPoint, to end: CGPoint, start t0: Double, end t1: Double) -> BallTrajectory {
    let points = (0..<10).map { i -> CGPoint in
        let f = Double(i) / 9
        return CGPoint(x: start.x + (end.x - start.x) * f, y: start.y + (end.y - start.y) * f)
    }
    return BallTrajectory(id: UUID(), start: t0, end: t1, points: points)
}

final class BallContactTests: XCTestCase {
    private var signals: AnalyzedSignals {
        StrokeAnalyzer.buildSignals(track: swingTrack(), handedness: .right)
    }

    /// Кисть в момент t — из тех же рядов, что использует сопоставление.
    private func wrist(at t: Double) -> CGPoint {
        BallContactMatcher.wristPosition(signals: signals, at: t)!
    }

    func testIncomingBallEndingAtWristIsMatched() {
        // Мяч прилетел с 5 корпусов и оборвался у кисти за 0.1 с до пика.
        let end = wrist(at: 1.4)
        let ball = trajectory(from: CGPoint(x: end.x - 1000, y: end.y - 300), to: end, start: 0.9, end: 1.4)
        let contact = BallContactMatcher.contact(near: 1.5, trajectories: [ball], signals: signals)
        XCTAssertNotNil(contact)
        XCTAssertEqual(contact?.time ?? 0, 1.4, accuracy: 0.001)
    }

    func testRacketHeadEndingAfterPeakIsIgnored() {
        // Обод ракетки тоже «прилетает издалека», но обрывается в проводке —
        // после пика. Это главный источник ложных совпадений.
        let end = wrist(at: 1.9)
        let racket = trajectory(from: CGPoint(x: end.x - 600, y: end.y + 200), to: end, start: 1.3, end: 1.9)
        XCTAssertNil(BallContactMatcher.contact(near: 1.5, trajectories: [racket], signals: signals))
    }

    func testBodyPartStartingNearWristIsIgnored() {
        let end = wrist(at: 1.4)
        let hand = trajectory(from: CGPoint(x: end.x - 150, y: end.y), to: end, start: 1.1, end: 1.4)
        XCTAssertNil(BallContactMatcher.contact(near: 1.5, trajectories: [hand], signals: signals))
    }

    func testTrajectoryEndingFarFromWristIsIgnored() {
        let end = wrist(at: 1.4)
        let far = trajectory(from: CGPoint(x: end.x - 1000, y: end.y), to: CGPoint(x: end.x - 500, y: end.y), start: 0.9, end: 1.4)
        XCTAssertNil(BallContactMatcher.contact(near: 1.5, trajectories: [far], signals: signals))
    }

    func testFartherApproachWins() {
        let end = wrist(at: 1.4)
        let near = trajectory(from: CGPoint(x: end.x - 450, y: end.y), to: end, start: 1.0, end: 1.4)
        let far = trajectory(from: CGPoint(x: end.x - 1200, y: end.y), to: end, start: 0.8, end: 1.4)
        let contact = BallContactMatcher.contact(near: 1.5, trajectories: [near, far], signals: signals)
        XCTAssertEqual(contact?.trajectoryID, far.id)
    }

    // MARK: - Через анализатор

    func testBallRefinesContactAndOverridesShapeDoubts() {
        let track = swingTrack()
        let plain = StrokeAnalyzer().analyze(track: track, handedness: .right)
        XCTAssertEqual(plain.strokes.count, 1)
        let peak = plain.strokes[0].contactTime

        let signals = plain.signals
        let end = BallContactMatcher.wristPosition(signals: signals, at: peak - 0.1)!
        let ball = trajectory(from: CGPoint(x: end.x - 1000, y: end.y - 300), to: end, start: peak - 0.6, end: peak - 0.1)

        let withBall = StrokeAnalyzer().analyze(track: track, handedness: .right, ballTrajectories: [ball])
        XCTAssertEqual(withBall.strokes.count, 1)
        XCTAssertNotNil(withBall.strokes[0].ballContact)
        XCTAssertEqual(withBall.strokes[0].contactTime, peak - 0.1, accuracy: 0.02)
        XCTAssertTrue(withBall.strokes[0].doubts.isEmpty)
        XCTAssertEqual(withBall.ballConfirmedCount, 1)
    }

    func testPeakSpeedStaysThePeakAfterRefinement() {
        // Пиковая скорость — это пик по окну, а не значение в кадре контакта:
        // после уточнения по мячу контакт уже не на пике.
        let track = swingTrack()
        let plain = StrokeAnalyzer().analyze(track: track, handedness: .right)
        let peak = plain.strokes[0].contactTime
        let end = BallContactMatcher.wristPosition(signals: plain.signals, at: peak - 0.12)!
        let ball = trajectory(from: CGPoint(x: end.x - 1000, y: end.y), to: end, start: peak - 0.6, end: peak - 0.12)
        let withBall = StrokeAnalyzer().analyze(track: track, handedness: .right, ballTrajectories: [ball])
        XCTAssertEqual(withBall.strokes[0].value(.peakWristSpeed), plain.strokes[0].value(.peakWristSpeed), accuracy: 0.01)
    }

    func testMissingBallIsNotHeldAgainstStrokesWhenRecallIsLow() {
        // Мяч в 12 пикселей ловится через раз: «мяча нет» ничего не значит.
        let track = swingTrack()
        let withEmpty = StrokeAnalyzer().analyze(track: track, handedness: .right, ballTrajectories: [])
        XCTAssertFalse(withEmpty.strokes[0].doubts.contains(.noBall))
        XCTAssertEqual(withEmpty.acceptedStrokes.count, 1)
    }

    func testUnconfirmedStrokesGoToReviewOnceBallIsReliable() {
        // Пять ударов с мячом и один без: без мяча — на проверку, не в статистику.
        func stroke(_ id: Int, ball: Bool) -> Stroke {
            let phases = StrokePhases(start: 0, transition: 1, contact: 2, end: 3, hasBackswing: false)
            let shape = StrokeShape(forwardDisplacement: 2, forwardPath: 2, followThrough: 1, prominence: 4, hasBackswing: false)
            return Stroke(id: id, type: .forehand, shape: shape, doubts: [],
                          ballContact: ball ? BallContact(time: 1, point: .zero, trajectoryID: UUID()) : nil,
                          phases: phases, startTime: 0, contactTime: 1, endTime: 2, values: [:])
        }
        let strokes = (0..<5).map { stroke($0, ball: true) } + [stroke(5, ball: false)]
        let judged = StrokeAnalyzer.applyingBallVerdict(to: strokes)
        XCTAssertTrue(judged[5].doubts.contains(.noBall))
        XCTAssertTrue(judged.prefix(5).allSatisfy { $0.doubts.isEmpty })

        // Четыре подтверждения — ещё не доверие детектору: никого не трогаем.
        let few = (0..<4).map { stroke($0, ball: true) } + [stroke(4, ball: false)]
        XCTAssertTrue(StrokeAnalyzer.applyingBallVerdict(to: few).allSatisfy { $0.doubts.isEmpty })
    }

    func testReplacingContactKeepsPhaseOrder() {
        let phases = StrokePhases(start: 10, transition: 30, contact: 50, end: 70, hasBackswing: true)
        let earlier = phases.replacingContact(with: 25)
        XCTAssertLessThan(earlier.transition, earlier.contact)
        XCTAssertEqual(earlier.contact, 25)
        let clamped = phases.replacingContact(with: 5)
        XCTAssertGreaterThan(clamped.contact, clamped.start)
        let late = phases.replacingContact(with: 90)
        XCTAssertLessThan(late.contact, late.end)
    }
}
