import CoreGraphics
import XCTest
@testable import StrokeKit

private func frame(
    time: Double,
    shoulderHalfWidth: Double,
    leftIsOnTheLeft: Bool
) -> PoseFrame {
    let centerX = 500.0
    let leftX = leftIsOnTheLeft ? centerX - shoulderHalfWidth : centerX + shoulderHalfWidth
    let rightX = leftIsOnTheLeft ? centerX + shoulderHalfWidth : centerX - shoulderHalfWidth
    return PoseFrame(time: time, joints: [
        .neck: JointSample(point: CGPoint(x: centerX, y: 100), confidence: 0.9),
        .root: JointSample(point: CGPoint(x: centerX, y: 300), confidence: 0.9),
        .leftShoulder: JointSample(point: CGPoint(x: leftX, y: 120), confidence: 0.9),
        .rightShoulder: JointSample(point: CGPoint(x: rightX, y: 120), confidence: 0.9),
    ])
}

private func frames(count: Int = 60, halfWidth: Double, leftIsOnTheLeft: Bool) -> [PoseFrame] {
    (0..<count).map {
        frame(time: Double($0) / 60, shoulderHalfWidth: halfWidth, leftIsOnTheLeft: leftIsOnTheLeft)
    }
}

final class CameraViewTests: XCTestCase {
    // Корпус в этих данных — 200 px, значит ширина плеч 2*halfWidth.

    func testNarrowShouldersMeanSideView() {
        // Плечи сложились в профиль: 40 px против корпуса в 200.
        let view = CameraViewDetector.detect(frames: frames(halfWidth: 20, leftIsOnTheLeft: true))
        XCTAssertEqual(view, .side)
    }

    func testLeftShoulderOnTheLeftMeansWeSeeTheBack() {
        let view = CameraViewDetector.detect(frames: frames(halfWidth: 70, leftIsOnTheLeft: true))
        XCTAssertEqual(view, .behind)
    }

    func testLeftShoulderOnTheRightMeansPlayerFacesUs() {
        let view = CameraViewDetector.detect(frames: frames(halfWidth: 70, leftIsOnTheLeft: false))
        XCTAssertEqual(view, .facing)
    }

    func testChangingAngleIsReportedAsMixed() {
        let half = frames(count: 40, halfWidth: 20, leftIsOnTheLeft: true)
        let other = frames(count: 40, halfWidth: 70, leftIsOnTheLeft: true)
        XCTAssertEqual(CameraViewDetector.detect(frames: half + other), .mixed)
    }

    func testTooFewFramesIsUnknown() {
        XCTAssertEqual(CameraViewDetector.detect(frames: frames(count: 5, halfWidth: 70, leftIsOnTheLeft: true)), .unknown)
    }

    func testDepthMetricsAreDisabledUnlessShotFromTheSide() {
        XCTAssertTrue(MetricKey.contactDepth.isReliable(in: .side))
        XCTAssertFalse(MetricKey.contactDepth.isReliable(in: .behind))
        XCTAssertFalse(MetricKey.shoulderRotationRange.isReliable(in: .facing))
        XCTAssertNotNil(MetricKey.contactDepth.unreliabilityReason(in: .behind))
    }

    func testHeightSurvivesAnyAngle() {
        // Вертикаль остаётся вертикалью в любом ракурсе.
        for view in [CameraView.side, .behind, .facing, .mixed] {
            XCTAssertTrue(MetricKey.contactHeight.isReliable(in: view))
            XCTAssertTrue(MetricKey.peakWristSpeed.isReliable(in: view))
        }
    }
}
