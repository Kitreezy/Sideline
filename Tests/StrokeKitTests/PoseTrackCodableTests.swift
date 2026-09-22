import CoreGraphics
import XCTest
@testable import StrokeKit

final class PoseTrackCodableTests: XCTestCase {
    private func sampleTrack() -> PoseTrack {
        let frames = (0..<5).map { i in
            PoseFrame(time: Double(i) / 60, joints: [
                .neck: JointSample(point: CGPoint(x: 500, y: 100 + Double(i)), confidence: 0.9),
                .rightWrist: JointSample(point: CGPoint(x: 600 + Double(i) * 10, y: 200), confidence: 0.7),
            ])
        }
        return PoseTrack(
            frames: frames,
            displaySize: CGSize(width: 1080, height: 1920),
            frameRate: 60,
            duration: 0.1,
            analysisFailures: 1,
            segmentBoundaries: [3],
            totalFrames: 12,
            backgroundMotion: BackgroundMotion(leftWristSpeedMedian: 0.4, rightWristSpeedMedian: 1.1)
        )
    }

    func testBinaryPlistRoundTrip() throws {
        // Именно этот формат идёт на диск: бинарный plist компактнее и быстрее
        // разбирается, чем JSON, а дорожки бывают на десятки тысяч кадров.
        let original = sampleTrack()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(original)
        let restored = try PropertyListDecoder().decode(PoseTrack.self, from: data)

        XCTAssertEqual(restored.frames.count, original.frames.count)
        XCTAssertEqual(restored.frames[2].time, original.frames[2].time)
        XCTAssertEqual(restored.frames[2].joints[.rightWrist]?.point.x, 620)
        XCTAssertEqual(restored.displaySize, original.displaySize)
        XCTAssertEqual(restored.segmentBoundaries, [3])
        XCTAssertEqual(restored.totalFrames, 12)
        XCTAssertEqual(restored.analysisFailures, 1)
        XCTAssertEqual(restored.backgroundMotion?.rightWristSpeedMedian, 1.1)
    }

    func testRestoredTrackAnalysesTheSame() throws {
        // Смысл кэша — что из него получается ровно тот же разбор.
        let original = sampleTrack()
        let data = try PropertyListEncoder().encode(original)
        let restored = try PropertyListDecoder().decode(PoseTrack.self, from: data)

        let a = StrokeAnalyzer().analyze(track: original, handedness: .right)
        let b = StrokeAnalyzer().analyze(track: restored, handedness: .right)
        XCTAssertEqual(a.strokes.count, b.strokes.count)
        XCTAssertEqual(a.cameraView, b.cameraView)
    }
}
