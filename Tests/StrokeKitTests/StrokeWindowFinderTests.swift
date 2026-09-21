import CoreGraphics
import XCTest
@testable import StrokeKit

/// Прореженный первый проход: та же геометрия, что и в остальных тестах,
/// но частота кадров низкая — как её видит первый проход.
private func coarseTrack(
    contactTimes: [Double],
    movingJoint: BodyJoint = .rightWrist,
    fps: Double = 30,
    duration: Double = 6.0
) -> [PoseFrame] {
    let frameCount = Int(duration * fps)
    return (0..<frameCount).map { i in
        let t = Double(i) / fps
        let swing = contactTimes.reduce(400.0) { partial, tc in
            partial + 300 * tanh((t - tc) / 0.08)
        }
        var points: [BodyJoint: CGPoint] = [
            .neck: CGPoint(x: 500, y: 100),
            .root: CGPoint(x: 500, y: 300),
            .leftShoulder: CGPoint(x: 450, y: 120),
            .rightShoulder: CGPoint(x: 550, y: 120),
            .leftHip: CGPoint(x: 460, y: 300),
            .rightHip: CGPoint(x: 540, y: 300),
            .leftWrist: CGPoint(x: 420, y: 300),
            .rightWrist: CGPoint(x: 420, y: 300),
        ]
        points[movingJoint] = CGPoint(x: swing, y: 200)
        return PoseFrame(
            time: t,
            joints: points.mapValues { JointSample(point: $0, confidence: 0.9) }
        )
    }
}

final class StrokeWindowFinderTests: XCTestCase {
    func testFindsAWindowAroundEveryStroke() {
        // Удары через 4 с: с запасом 1.2 с окна не пересекаются, и каждому
        // удару достаётся своё.
        let contacts = [1.5, 5.5, 9.5]
        let windows = StrokeWindowFinder.candidateWindows(
            frames: coarseTrack(contactTimes: contacts, duration: 12), duration: 12
        )
        XCTAssertEqual(windows.count, contacts.count)
        for contact in contacts {
            XCTAssertTrue(
                windows.contains { $0.contains(contact) },
                "удар на \(contact) с не попал ни в одно окно"
            )
        }
    }

    func testSparseCoarsePassStillFindsEveryStroke() {
        // Первый проход на 60 fps идёт с шагом 4 — это 15 кадров в секунду.
        // Синтетический удар здесь резче настоящего (разгон 0.16 с против
        // 0.3–0.5), так что если находится он — найдётся и настоящий.
        for fps in [20.0, 15.0] {
            let contacts = [1.5, 5.5, 9.5]
            let windows = StrokeWindowFinder.candidateWindows(
                frames: coarseTrack(contactTimes: contacts, fps: fps, duration: 12), duration: 12
            )
            for contact in contacts {
                XCTAssertTrue(windows.contains { $0.contains(contact) }, "\(fps) fps: удар на \(contact) с потерян")
            }
        }
    }

    func testWindowLeavesRoomForBackswingAndFollowThrough() {
        // Если окно обрезано по самому контакту, второй проход не увидит фаз.
        let windows = StrokeWindowFinder.candidateWindows(
            frames: coarseTrack(contactTimes: [3.0]), duration: 6
        )
        guard let window = windows.first else { return XCTFail("окно не нашлось") }
        XCTAssertLessThan(window.lowerBound, 2.5)
        XCTAssertGreaterThan(window.upperBound, 3.5)
    }

    func testEitherHandTriggersAWindow() {
        // Рука в первом проходе неизвестна, и ошибиться в ней нельзя:
        // пропущенный удар потом уже не вернуть.
        let windows = StrokeWindowFinder.candidateWindows(
            frames: coarseTrack(contactTimes: [2.0], movingJoint: .leftWrist), duration: 6
        )
        XCTAssertEqual(windows.count, 1)
        XCTAssertTrue(windows[0].contains(2.0))
    }

    func testStillVideoGivesNoWindows() {
        let windows = StrokeWindowFinder.candidateWindows(
            frames: coarseTrack(contactTimes: []), duration: 6
        )
        XCTAssertTrue(windows.isEmpty)
    }

    func testCloseStrokesShareOneWindow() {
        // Два удара в 0.5 с друг от друга: окна перекрываются и должны слиться,
        // иначе второй проход разберёт кусок дважды.
        let windows = StrokeWindowFinder.candidateWindows(
            frames: coarseTrack(contactTimes: [2.0, 2.5]), duration: 6
        )
        XCTAssertEqual(windows.count, 1)
        XCTAssertTrue(windows[0].contains(2.0))
        XCTAssertTrue(windows[0].contains(2.5))
    }

    func testMergeJoinsTouchingRanges() {
        let merged = StrokeWindowFinder.merge([3.0...4.0, 1.0...2.0, 1.5...2.5])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].lowerBound, 1.0, accuracy: 0.001)
        XCTAssertEqual(merged[0].upperBound, 2.5, accuracy: 0.001)
    }

    // MARK: - Границы кусков

    func testAnalyzerHonoursDeclaredSegmentBoundaries() {
        // Между окнами лежат неразобранные секунды. Даже если скелет по обе
        // стороны разрыва стоит на одном месте — и детектор прыжков молчит —
        // сглаживать и искать удар через этот разрыв нельзя.
        let first = coarseTrack(contactTimes: [0.5], fps: 120, duration: 1.0)
        let second = coarseTrack(contactTimes: [0.5], fps: 120, duration: 1.0)
            .map { PoseFrame(time: $0.time + 10, joints: $0.joints) }

        let frames = first + second
        let track = PoseTrack(
            frames: frames,
            displaySize: CGSize(width: 1080, height: 1920),
            frameRate: 120,
            duration: 11,
            segmentBoundaries: [first.count],
            totalFrames: 1320
        )

        let analysis = StrokeAnalyzer().analyze(track: track, handedness: .right)
        for stroke in analysis.strokes {
            let crossesGap = stroke.startTime < first.last!.time && stroke.endTime > 10
            XCTAssertFalse(crossesGap, "удар не может начаться до разрыва и кончиться после")
        }
    }
}
