import AVFoundation
import CoreGraphics
import Foundation
import Vision

public enum PoseExtractionError: Error, LocalizedError {
    case noVideoTrack
    case readerFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "В файле нет видеодорожки."
        case .readerFailed(let reason):
            return "Не удалось прочитать видео: \(reason)"
        }
    }
}

/// Результат прогона видео через Vision.
public struct PoseTrack: Sendable {
    public let frames: [PoseFrame]
    /// Размер кадра после применения ориентации съёмки — в этих координатах лежат точки.
    public let displaySize: CGSize
    public let frameRate: Double
    public let duration: TimeInterval
    /// Кадры, на которых Vision вернул ошибку, а не «никого не нашёл».
    /// Это разные вещи: во втором случае в кадре просто нет человека,
    /// в первом — распознавание вообще не запустилось.
    public let analysisFailures: Int

    public init(
        frames: [PoseFrame],
        displaySize: CGSize,
        frameRate: Double,
        duration: TimeInterval,
        analysisFailures: Int = 0
    ) {
        self.frames = frames
        self.displaySize = displaySize
        self.frameRate = frameRate
        self.duration = duration
        self.analysisFailures = analysisFailures
    }
}

public struct PoseExtractor: Sendable {
    public init() {}

    /// Гоняет каждый кадр через body-pose. Всё локально, ничего не уходит с устройства.
    /// `onProgress` вызывается с долей 0...1.
    public func extract(
        from url: URL,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> PoseTrack {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw PoseExtractionError.noVideoTrack
        }

        let (naturalSize, transform, nominalRate) = try await track.load(
            .naturalSize, .preferredTransform, .nominalFrameRate
        )
        let duration = try await asset.load(.duration).seconds

        let orientation = Self.orientation(for: transform)
        let displaySize = Self.displaySize(naturalSize: naturalSize, orientation: orientation)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw PoseExtractionError.readerFailed(reader.error?.localizedDescription ?? "неизвестная ошибка")
        }

        var request = DetectHumanBodyPoseRequest()
        request.detectsHands = false

        var frames: [PoseFrame] = []
        var lastProgressReport = 0.0
        var tracker = PlayerTracker()
        var analysisFailures = 0

        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard time.isFinite else { continue }

            var observations: [HumanBodyPoseObservation] = []
            do {
                observations = try await request.perform(on: buffer, orientation: orientation)
            } catch {
                analysisFailures += 1
            }
            let candidates = observations.map {
                PoseCandidate(joints: Self.joints(from: $0, displaySize: displaySize))
            }

            // Игрок выбирается по близости к предыдущему кадру, а не по размеру:
            // иначе Vision перескакивает на соперника за сеткой.
            if let index = tracker.select(from: candidates, at: time) {
                frames.append(PoseFrame(time: time, joints: candidates[index].joints))
            } else {
                frames.append(PoseFrame(time: time, joints: [:]))
            }

            if duration > 0 {
                let progress = min(1, time / duration)
                if progress - lastProgressReport > 0.01 {
                    lastProgressReport = progress
                    onProgress(progress)
                }
            }
        }

        if reader.status == .failed {
            throw PoseExtractionError.readerFailed(reader.error?.localizedDescription ?? "чтение прервалось")
        }
        onProgress(1)

        let measuredRate = Self.measuredFrameRate(frames: frames) ?? Double(nominalRate)
        return PoseTrack(
            frames: frames,
            displaySize: displaySize,
            frameRate: measuredRate,
            duration: duration,
            analysisFailures: analysisFailures
        )
    }

    // MARK: - Разбор наблюдения

    static let jointMap: [HumanBodyPoseObservation.JointName: BodyJoint] = [
        .neck: .neck,
        .root: .root,
        .leftShoulder: .leftShoulder, .rightShoulder: .rightShoulder,
        .leftElbow: .leftElbow, .rightElbow: .rightElbow,
        .leftWrist: .leftWrist, .rightWrist: .rightWrist,
        .leftHip: .leftHip, .rightHip: .rightHip,
        .leftKnee: .leftKnee, .rightKnee: .rightKnee,
        .leftAnkle: .leftAnkle, .rightAnkle: .rightAnkle,
    ]

    static func joints(
        from observation: HumanBodyPoseObservation,
        displaySize: CGSize
    ) -> [BodyJoint: JointSample] {
        PoseMapping.joints(from: observation, displaySize: displaySize)
    }

    // MARK: - Ориентация

    static func orientation(for transform: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (transform.a, transform.b, transform.c, transform.d) {
        case (0, 1, -1, 0): return .right
        case (0, -1, 1, 0): return .left
        case (-1, 0, 0, -1): return .down
        default: return .up
        }
    }

    static func displaySize(naturalSize: CGSize, orientation: CGImagePropertyOrientation) -> CGSize {
        switch orientation {
        case .left, .right, .leftMirrored, .rightMirrored:
            return CGSize(width: naturalSize.height, height: naturalSize.width)
        default:
            return naturalSize
        }
    }

    private static func measuredFrameRate(frames: [PoseFrame]) -> Double? {
        guard frames.count > 2 else { return nil }
        let step = SignalProcessing.medianStep(frames.map(\.time))
        guard step > 0 else { return nil }
        return 1 / step
    }
}
