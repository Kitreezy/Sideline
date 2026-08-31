import CoreGraphics
import XCTest
@testable import StrokeKit

/// Серия с паузами и ударами разной силы: слабый удар — тот самый случай,
/// на котором ломается неверно посчитанный порог.
private func sessionFrames(
    contacts: [(time: Double, amplitude: Double)],
    fps: Double = 120,
    duration: Double = 14
) -> [PoseFrame] {
    (0..<Int(duration * fps)).map { i in
        let t = Double(i) / fps
        let x = contacts.reduce(400.0) { partial, stroke in
            partial + stroke.amplitude * tanh((t - stroke.time) / 0.15)
        }
        let wrist = CGPoint(x: x, y: 200)
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
        return PoseFrame(
            time: t,
            joints: points.mapValues { JointSample(point: $0, confidence: 0.9) }
        )
    }
}

private let contacts: [(time: Double, amplitude: Double)] = [
    (2.0, 300), (5.0, 300), (8.0, 110), (11.0, 300),
]

private func track(_ frames: [PoseFrame], boundaries: Set<Int> = [], background: BackgroundMotion? = nil) -> PoseTrack {
    PoseTrack(
        frames: frames,
        displaySize: CGSize(width: 1080, height: 1920),
        frameRate: 120,
        duration: 14,
        segmentBoundaries: boundaries,
        totalFrames: Int(14 * 120),
        backgroundMotion: background
    )
}

/// Оставляет только окна вокруг ударов — так выглядит дорожка после второго прохода.
private func windowed(_ frames: [PoseFrame], padding: Double = 0.35) -> (frames: [PoseFrame], boundaries: Set<Int>) {
    var kept: [PoseFrame] = []
    var boundaries: Set<Int> = []
    var previousTime: Double?

    for frame in frames {
        let inWindow = contacts.contains { abs(frame.time - $0.time) <= padding }
        guard inWindow else { continue }
        if let previousTime, frame.time - previousTime > 2.5 / 120 {
            boundaries.insert(kept.count)
        }
        kept.append(frame)
        previousTime = frame.time
    }
    return (kept, boundaries)
}

final class TwoPassEquivalenceTests: XCTestCase {
    func testFullScanFindsEveryStroke() {
        let analysis = StrokeAnalyzer().analyze(
            track: track(sessionFrames(contacts: contacts)), handedness: .right
        )
        XCTAssertEqual(analysis.strokes.count, contacts.count)
    }

    func testTwoPassFindsTheSameStrokesAsFullScan() {
        let full = sessionFrames(contacts: contacts)
        let reference = StrokeAnalyzer().analyze(track: track(full), handedness: .right)

        let cut = windowed(full)
        let twoPass = StrokeAnalyzer().analyze(
            track: track(
                cut.frames,
                boundaries: cut.boundaries,
                background: StrokeWindowFinder.backgroundMotion(frames: full)
            ),
            handedness: .right
        )

        XCTAssertEqual(twoPass.strokes.count, reference.strokes.count)
        for (a, b) in zip(reference.strokes, twoPass.strokes) {
            XCTAssertEqual(a.contactTime, b.contactTime, accuracy: 0.02)
        }
    }

    func testWithoutBackgroundMeasurementWeakStrokesAreLost() {
        // Регрессия. Порог удара привязан к медианной скорости кисти. Если
        // считать её по дорожке, в которой остались одни удары, медиана
        // подскакивает вместе с порогом, и слабый удар исчезает.
        let full = sessionFrames(contacts: contacts)
        let cut = windowed(full)

        let withBackground = StrokeAnalyzer().analyze(
            track: track(cut.frames, boundaries: cut.boundaries,
                         background: StrokeWindowFinder.backgroundMotion(frames: full)),
            handedness: .right
        ).strokes.count

        let withoutBackground = StrokeAnalyzer().analyze(
            track: track(cut.frames, boundaries: cut.boundaries, background: nil),
            handedness: .right
        ).strokes.count

        XCTAssertEqual(withBackground, contacts.count)
        XCTAssertLessThan(
            withoutBackground, withBackground,
            "тест сторожит именно эту разницу — если она исчезла, замер фона стал не нужен"
        )
    }

    func testBackgroundMeasurementIsHandednessAware() {
        let background = StrokeWindowFinder.backgroundMotion(frames: sessionFrames(contacts: contacts))
        XCTAssertNotNil(background)
        // Двигалась только правая кисть, левая стояла на месте.
        XCTAssertGreaterThan(background!.median(for: .right), background!.median(for: .left))
    }

    func testThresholdPrefersMeasuredBackgroundOverTrimmedMedian() {
        let noisy = Signal(times: (0..<100).map { Double($0) * 0.01 },
                           values: [Double](repeating: 5.0, count: 100))
        let fromSignal = StrokeAnalyzer.strokeThreshold(noisy, floor: 2.0, medianFactor: 3.0)
        let fromBackground = StrokeAnalyzer.strokeThreshold(
            noisy, floor: 2.0, medianFactor: 3.0, background: 0.3
        )
        XCTAssertEqual(fromSignal, 15.0, accuracy: 0.001)
        XCTAssertEqual(fromBackground, 2.0, accuracy: 0.001)
    }
}
