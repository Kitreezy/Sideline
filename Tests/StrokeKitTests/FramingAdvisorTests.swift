import CoreGraphics
import XCTest
@testable import StrokeKit

/// Кадр высотой 1000: длина корпуса прямо задаёт долю от высоты кадра.
private func framingFrames(
    count: Int = 30,
    torso: Double = 150,
    withAnkles: Bool = true,
    shoulderHalfWidth: Double = 20,
    leftIsOnTheLeft: Bool = true
) -> [PoseFrame] {
    (0..<count).map { index in
        let centerX = 500.0
        let neckY = 300.0
        var joints: [BodyJoint: JointSample] = [
            .neck: JointSample(point: CGPoint(x: centerX, y: neckY), confidence: 0.9),
            .root: JointSample(point: CGPoint(x: centerX, y: neckY + torso), confidence: 0.9),
            .leftShoulder: JointSample(
                point: CGPoint(x: centerX + (leftIsOnTheLeft ? -shoulderHalfWidth : shoulderHalfWidth), y: neckY + 20),
                confidence: 0.9
            ),
            .rightShoulder: JointSample(
                point: CGPoint(x: centerX + (leftIsOnTheLeft ? shoulderHalfWidth : -shoulderHalfWidth), y: neckY + 20),
                confidence: 0.9
            ),
            .leftHip: JointSample(point: CGPoint(x: centerX - 20, y: neckY + torso), confidence: 0.9),
            .rightHip: JointSample(point: CGPoint(x: centerX + 20, y: neckY + torso), confidence: 0.9),
            .leftKnee: JointSample(point: CGPoint(x: centerX - 20, y: neckY + torso * 1.5), confidence: 0.9),
            .rightKnee: JointSample(point: CGPoint(x: centerX + 20, y: neckY + torso * 1.5), confidence: 0.9),
        ]
        if withAnkles {
            joints[.leftAnkle] = JointSample(point: CGPoint(x: centerX - 20, y: neckY + torso * 2), confidence: 0.9)
            joints[.rightAnkle] = JointSample(point: CGPoint(x: centerX + 20, y: neckY + torso * 2), confidence: 0.9)
        }
        return PoseFrame(time: Double(index) / 15, joints: joints)
    }
}

private let frameSize = CGSize(width: 1000, height: 1000)

final class FramingAdvisorTests: XCTestCase {
    private func report(_ frames: [PoseFrame]) -> FramingReport {
        FramingAdvisor().evaluate(recent: frames, frameSize: frameSize)
    }

    private func check(_ report: FramingReport, _ id: String) -> FramingCheck? {
        report.checks.first { $0.id == id }
    }

    func testEmptyViewIsNotReadyToRecord() {
        let result = report([])
        XCTAssertFalse(result.canRecord)
        XCTAssertEqual(check(result, "visible")?.status, .problem)
    }

    func testWellFramedPlayerIsReady() {
        // Корпус 150 из 1000 — 15% высоты кадра, как на реальной записи.
        let result = report(framingFrames(torso: 150))
        XCTAssertTrue(result.canRecord)
        XCTAssertEqual(check(result, "size")?.status, .ok)
        XCTAssertEqual(check(result, "whole")?.status, .ok)
    }

    func testTooFarAwayBlocksRecording() {
        let result = report(framingFrames(torso: 60))
        XCTAssertFalse(result.canRecord)
        XCTAssertEqual(check(result, "size")?.status, .problem)
    }

    func testTooCloseBlocksRecording() {
        let result = report(framingFrames(torso: 500))
        XCTAssertFalse(result.canRecord)
        XCTAssertEqual(check(result, "size")?.status, .problem)
    }

    func testSlightlySmallIsOnlyAWarning() {
        let result = report(framingFrames(torso: 100))
        XCTAssertTrue(result.canRecord, "снимать можно, просто будет менее точно")
        XCTAssertEqual(check(result, "size")?.status, .warning)
    }

    func testMissingFeetBlocksRecording() {
        // Без стоп не посчитать работу ног, и это самая частая ошибка кадра.
        let result = report(framingFrames(withAnkles: false))
        XCTAssertFalse(result.canRecord)
        XCTAssertEqual(check(result, "whole")?.status, .problem)
    }

    func testSideViewIsTheGoodCase() {
        let result = report(framingFrames(shoulderHalfWidth: 20))
        XCTAssertEqual(result.cameraView, .side)
        XCTAssertEqual(check(result, "view")?.status, .ok)
    }

    func testWrongAngleWarnsButDoesNotBlock() {
        // Снимать сзади — осознанный выбор, просто часть метрик не посчитается.
        let result = report(framingFrames(shoulderHalfWidth: 60, leftIsOnTheLeft: true))
        XCTAssertEqual(result.cameraView, .behind)
        XCTAssertEqual(check(result, "view")?.status, .warning)
        XCTAssertTrue(result.canRecord)
    }
}
