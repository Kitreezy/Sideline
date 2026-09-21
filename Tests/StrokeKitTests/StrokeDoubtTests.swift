import CoreGraphics
import XCTest
@testable import StrokeKit

/// Движение кисти задаётся функцией от времени — так можно подсунуть
/// анализатору что угодно: удар, сплит-степ, дрожание.
private func trackWithWrist(_ wristX: (Double) -> Double, fps: Double = 120, duration: Double = 3) -> PoseTrack {
    let frames = (0..<Int(duration * fps)).map { i -> PoseFrame in
        let t = Double(i) / fps
        let wrist = CGPoint(x: wristX(t), y: 200)
        let points: [BodyJoint: CGPoint] = [
            .neck: CGPoint(x: 500, y: 100),
            .root: CGPoint(x: 500, y: 300),
            .leftShoulder: CGPoint(x: 450, y: 120),
            .rightShoulder: CGPoint(x: 550, y: 120),
            .leftElbow: CGPoint(x: 430, y: 220),
            .rightElbow: CGPoint(x: (550 + wrist.x) / 2, y: 190),
            .leftWrist: CGPoint(x: 420, y: 300),
            .rightWrist: wrist,
            .leftHip: CGPoint(x: 460, y: 300),
            .rightHip: CGPoint(x: 540, y: 300),
            .leftKnee: CGPoint(x: 460, y: 420),
            .rightKnee: CGPoint(x: 540, y: 420),
            .leftAnkle: CGPoint(x: 460, y: 540),
            .rightAnkle: CGPoint(x: 540, y: 540),
        ]
        return PoseFrame(time: t, joints: points.mapValues { JointSample(point: $0, confidence: 0.9) })
    }
    return PoseTrack(frames: frames, displaySize: CGSize(width: 1080, height: 1920), frameRate: fps, duration: duration)
}

final class StrokeDoubtTests: XCTestCase {
    func testProperSwingRaisesNoDoubts() {
        // Кисть проходит три корпуса по прямой — это удар.
        let analysis = StrokeAnalyzer().analyze(
            track: trackWithWrist { t in 400 + 300 * tanh((t - 1.5) / 0.08) },
            handedness: .right
        )
        XCTAssertEqual(analysis.strokes.count, 1)
        XCTAssertTrue(analysis.strokes[0].doubts.isEmpty, "\(analysis.strokes[0].doubts)")
        XCTAssertEqual(analysis.acceptedStrokes.count, 1)
    }

    func testTinyJerkIsDoubted() {
        // Резкий, но короткий рывок: кисть сдвинулась на треть корпуса.
        // Скорость при этом выше порога удара — раньше это считалось ударом.
        let analysis = StrokeAnalyzer().analyze(
            track: trackWithWrist { t in 400 + 60 * tanh((t - 1.5) / 0.03) },
            handedness: .right
        )
        XCTAssertEqual(analysis.strokes.count, 1, "всплеск должен найтись, но попасть под сомнение")
        XCTAssertTrue(analysis.strokes[0].doubts.contains(.tinySwing))
        XCTAssertTrue(analysis.acceptedStrokes.isEmpty)
        XCTAssertEqual(analysis.rejectedStrokes.count, 1)
    }

    func testJitterIsDoubted() {
        // Кисть дрожит туда-сюда: скорость большая, а сдвига нет.
        let analysis = StrokeAnalyzer().analyze(
            track: trackWithWrist { t in
                (1.2...1.8).contains(t) ? 400 + 80 * sin(2 * .pi * 8 * t) : 400
            },
            handedness: .right
        )
        XCTAssertFalse(analysis.strokes.isEmpty, "всплеск скорости должен быть найден")
        for stroke in analysis.strokes {
            XCTAssertTrue(stroke.isDoubtful, "дрожание не должно проходить как удар")
        }
        XCTAssertTrue(analysis.acceptedStrokes.isEmpty)
    }

    func testDoubtedStrokesStayOutOfStatistics() {
        let analysis = StrokeAnalyzer().analyze(
            track: trackWithWrist { t in
                400 + 300 * tanh((t - 1.0) / 0.08) + 60 * tanh((t - 2.2) / 0.03)
            },
            handedness: .right
        )
        XCTAssertEqual(analysis.strokes.count, 2)
        XCTAssertEqual(analysis.acceptedStrokes.count, 1)
        XCTAssertEqual(analysis.presentTypes.count, 1)
        let type = analysis.acceptedStrokes[0].type
        XCTAssertEqual(analysis.strokes(of: type).count, 1)
    }

    func testUserCanOverrideTheVerdict() {
        var analysis = StrokeAnalyzer().analyze(
            track: trackWithWrist { t in
                400 + 300 * tanh((t - 1.0) / 0.08) + 60 * tanh((t - 2.2) / 0.03)
            },
            handedness: .right
        )
        let doubted = analysis.rejectedStrokes[0]
        let accepted = analysis.acceptedStrokes[0]

        // Пользователь видит запись: возвращает один, выкидывает другой.
        analysis.setRejected(false, for: doubted)
        analysis.setRejected(true, for: accepted)

        XCTAssertFalse(analysis.isRejected(doubted))
        XCTAssertTrue(analysis.isRejected(accepted))
        XCTAssertEqual(analysis.acceptedStrokes.map(\.id), [doubted.id])
    }
}
