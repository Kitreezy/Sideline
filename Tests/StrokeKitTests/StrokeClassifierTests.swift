import CoreGraphics
import XCTest
@testable import StrokeKit

/// Синтетический удар с управляемой геометрией: можно задать, какое плечо
/// развёрнуто вперёд, на какой высоте контакт и есть ли отдельный замах.
private func swingTrack(
    contactTime: Double = 1.0,
    dominantShoulderLeads: Bool,
    wristY: Double = 250,
    withBackswing: Bool = false,
    fps: Double = 120,
    duration: Double = 2.0
) -> PoseTrack {
    let frameCount = Int(duration * fps)
    var frames: [PoseFrame] = []

    // Корпус 200 px: шея на 100, таз на 300.
    let leftShoulderX = dominantShoulderLeads ? 450.0 : 550.0
    let rightShoulderX = dominantShoulderLeads ? 550.0 : 450.0

    for i in 0..<frameCount {
        let t = Double(i) / fps
        var x = 400 + 300 * tanh((t - contactTime) / 0.08)
        if withBackswing {
            let u = (t - (contactTime - 0.45)) / 0.12
            x -= 150 * exp(-u * u)
        }
        let wrist = CGPoint(x: x, y: wristY)

        let points: [BodyJoint: CGPoint] = [
            .neck: CGPoint(x: 500, y: 100),
            .root: CGPoint(x: 500, y: 300),
            .leftShoulder: CGPoint(x: leftShoulderX, y: 120),
            .rightShoulder: CGPoint(x: rightShoulderX, y: 120),
            .leftElbow: CGPoint(x: 430, y: 220),
            .rightElbow: CGPoint(x: (rightShoulderX + wrist.x) / 2, y: (120 + wrist.y) / 2 + 30),
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
            PoseFrame(time: t, joints: points.mapValues { JointSample(point: $0, confidence: 0.9) })
        )
    }

    return PoseTrack(
        frames: frames,
        displaySize: CGSize(width: 1080, height: 1920),
        frameRate: fps,
        duration: duration
    )
}

private func firstStroke(_ track: PoseTrack) -> Stroke? {
    StrokeAnalyzer().analyze(track: track, handedness: .right).strokes.first
}

final class StrokeClassifierTests: XCTestCase {
    func testNonDominantShoulderLeadingIsAForehand() {
        let stroke = firstStroke(swingTrack(dominantShoulderLeads: false))
        XCTAssertEqual(stroke?.type, .forehand)
    }

    func testDominantShoulderLeadingIsABackhand() {
        let stroke = firstStroke(swingTrack(dominantShoulderLeads: true))
        XCTAssertEqual(stroke?.type, .backhand)
    }

    func testWristFarAboveTheNeckIsAnOverhead() {
        // Кисть на 0.65 корпуса выше шеи — рука выпрямлена вверх.
        let stroke = firstStroke(swingTrack(dominantShoulderLeads: false, wristY: -30))
        XCTAssertEqual(stroke?.type, .serve)
    }

    func testHighForehandIsNotAnOverhead() {
        // Регрессия: правило «кисть выше шеи» без запаса записывало в подачи
        // любой высокий форхенд и любую проводку над плечом.
        let stroke = firstStroke(swingTrack(dominantShoulderLeads: false, wristY: 40))
        XCTAssertEqual(stroke?.type, .forehand)
    }

    // MARK: - Замах

    func testBackswingIsMeasuredWhenItExists() {
        guard let stroke = firstStroke(swingTrack(dominantShoulderLeads: false, withBackswing: true)) else {
            return XCTFail("удар не нашёлся")
        }
        XCTAssertTrue(stroke.phases.hasBackswing)
        XCTAssertGreaterThan(stroke.value(.backswingDuration), 0)
        XCTAssertLessThan(stroke.value(.backswingDuration), 1.2)
    }

    func testMissingBackswingIsNotReportedAsZero() {
        // Регрессия: раньше конец замаха совпадал с началом окна разгона,
        // и длительность замаха у каждого удара выходила ровно 0.00.
        guard let stroke = firstStroke(swingTrack(dominantShoulderLeads: false, withBackswing: false)) else {
            return XCTFail("удар не нашёлся")
        }
        XCTAssertFalse(stroke.phases.hasBackswing)
        XCTAssertTrue(
            stroke.value(.backswingDuration).isNaN,
            "«замаха не видно» и «замах длился ноль секунд» — разные утверждения"
        )
    }

    func testPhasesStayOrderedWithBackswing() {
        guard let stroke = firstStroke(swingTrack(dominantShoulderLeads: false, withBackswing: true)) else {
            return XCTFail("удар не нашёлся")
        }
        XCTAssertLessThan(stroke.phases.start, stroke.phases.transition)
        XCTAssertLessThan(stroke.phases.transition, stroke.phases.contact)
        XCTAssertLessThan(stroke.phases.contact, stroke.phases.end)
    }
}
