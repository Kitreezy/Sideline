#if DEBUG
import CoreGraphics
import Foundation
import StrokeKit

/// Тренировка из синтетического скелета — в симуляторе Vision не работает,
/// а интерфейс с ударами, выводами и разделом «на проверку» смотреть надо.
/// Только для отладочных сборок.
@MainActor
enum DemoSession {
    static func make(in store: SessionStore) throws -> SavedSession {
        let fps = 60.0
        let duration = 40.0
        // Удары разной силы и с разным локтем, три из них «слабые» —
        // чтобы были и выводы, и сомнения.
        let contacts: [(time: Double, amplitude: Double, elbowDrop: Double)] = [
            (3, 300, 0), (7, 320, 40), (11, 280, 0), (15, 60, 0), (19, 310, 60),
            (23, 290, 0), (27, 300, 20), (31, 50, 0), (35, 330, 0),
        ]
        var frames: [PoseFrame] = []
        for i in 0..<Int(duration * fps) {
            let t = Double(i) / fps
            let x = contacts.reduce(400.0) { $0 + $1.amplitude * tanh((t - $1.time) / 0.12) }
            let elbowDrop = contacts.reduce(0.0) { $0 + $1.elbowDrop * exp(-pow((t - $1.time) / 0.15, 2)) }
            let wrist = CGPoint(x: x, y: 200)
            let points: [BodyJoint: CGPoint] = [
                .neck: CGPoint(x: 500, y: 100), .root: CGPoint(x: 500, y: 300),
                .leftShoulder: CGPoint(x: 470, y: 120), .rightShoulder: CGPoint(x: 530, y: 120),
                .leftElbow: CGPoint(x: 430, y: 220),
                .rightElbow: CGPoint(x: (530 + wrist.x) / 2, y: 190 + elbowDrop),
                .leftWrist: CGPoint(x: 420, y: 300), .rightWrist: wrist,
                .leftHip: CGPoint(x: 460, y: 300), .rightHip: CGPoint(x: 540, y: 300),
                .leftKnee: CGPoint(x: 460, y: 420), .rightKnee: CGPoint(x: 540, y: 420),
                .leftAnkle: CGPoint(x: 460, y: 540), .rightAnkle: CGPoint(x: 540, y: 540),
            ]
            frames.append(PoseFrame(time: t, joints: points.mapValues { JointSample(point: $0, confidence: 0.9) }))
        }
        let track = PoseTrack(
            frames: frames, displaySize: CGSize(width: 1080, height: 1920),
            frameRate: fps, duration: duration
        )

        // Мяч у шести ударов: тогда включается раздел «на проверку».
        let signals = StrokeAnalyzer.buildSignals(track: track, handedness: .right)
        var trajectories: [BallTrajectory] = []
        for stroke in contacts.prefix(6) {
            let end = stroke.time - 0.1
            guard let wrist = BallContactMatcher.wristPosition(signals: signals, at: end) else { continue }
            let points = (0..<10).map { k -> CGPoint in
                let f = Double(k) / 9
                return CGPoint(x: wrist.x - 900 * (1 - f), y: wrist.y - 250 * (1 - f))
            }
            trajectories.append(BallTrajectory(id: UUID(), start: end - 0.5, end: end, points: points))
        }

        let analysis = StrokeAnalyzer().analyze(track: track, handedness: .right, ballTrajectories: trajectories)

        // Видео-заглушка: плеер покажет чёрное, миниатюры останутся серыми.
        let placeholder = URL.temporaryDirectory.appending(path: "demo-\(UUID().uuidString).mov")
        try Data().write(to: placeholder)

        return try store.save(
            track: track, ballTrajectories: trajectories, analysis: analysis,
            handedness: .right, videoURL: placeholder
        ).session
    }
}
#endif
