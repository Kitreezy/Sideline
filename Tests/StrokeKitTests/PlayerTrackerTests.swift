import CoreGraphics
import XCTest
@testable import StrokeKit

private func candidate(centerX: Double, centerY: Double = 300, torso: Double) -> PoseCandidate {
    PoseCandidate(joints: [
        .neck: JointSample(point: CGPoint(x: centerX, y: centerY - torso), confidence: 0.9),
        .root: JointSample(point: CGPoint(x: centerX, y: centerY), confidence: 0.9),
    ])
}

final class PlayerTrackerTests: XCTestCase {
    func testPicksLargestWhenNothingIsKnownYet() {
        var tracker = PlayerTracker()
        let index = tracker.select(
            from: [candidate(centerX: 100, torso: 80), candidate(centerX: 900, torso: 200)],
            at: 0
        )
        XCTAssertEqual(index, 1)
    }

    func testStaysWithTheSamePlayerEvenWhenSomeoneBiggerAppears() {
        // Ровно этот случай ломал разбор: Vision видит соперника за сеткой,
        // тот на кадр оказывается крупнее, и кисть «телепортируется».
        var tracker = PlayerTracker()
        _ = tracker.select(from: [candidate(centerX: 500, torso: 200)], at: 0)

        let index = tracker.select(
            from: [
                candidate(centerX: 505, torso: 200),   // наш игрок, чуть сместился
                candidate(centerX: 1400, torso: 260),  // кто-то крупнее, но далеко
            ],
            at: 1.0 / 60
        )
        XCTAssertEqual(index, 0)
    }

    func testKeepsFollowingThePlayerWhoRunsAway() {
        // Игрок убегает от камеры и становится мельче стоящего рядом человека.
        // Выбор «самый крупный в кадре» на этом бы переключился, трекер — нет.
        var tracker = PlayerTracker()
        var x = 500.0
        var torso = 200.0
        var index: Int?
        for frame in 0..<30 {
            x += 12
            torso -= 2
            index = tracker.select(
                from: [candidate(centerX: 200, torso: 150), candidate(centerX: x, torso: torso)],
                at: Double(frame) / 60
            )
        }
        XCTAssertLessThan(torso, 150, "к концу игрок должен стать мельче соседа")
        XCTAssertEqual(index, 1, "трекер должен вести того же игрока, а не самого крупного")
    }

    func testResetsAfterLongGap() {
        var tracker = PlayerTracker()
        _ = tracker.select(from: [candidate(centerX: 500, torso: 200)], at: 0)
        // Игрока не было секунду — держаться за старую позицию больше нельзя.
        let index = tracker.select(
            from: [candidate(centerX: 505, torso: 90), candidate(centerX: 1400, torso: 260)],
            at: 1.0
        )
        XCTAssertEqual(index, 1)
    }

    func testEmptyFrameSelectsNobody() {
        var tracker = PlayerTracker()
        XCTAssertNil(tracker.select(from: [], at: 0))
    }
}
