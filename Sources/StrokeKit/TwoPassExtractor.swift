import AVFoundation
import CoreGraphics
import Foundation
import Vision

/// Разбор видео в два прохода.
///
/// Vision стоит одинаково на каждом кадре — около 9 мс. На записи серии
/// в слоу-мо это десятки тысяч кадров и минуты ожидания, хотя удары занимают
/// меньше десятой части времени. Первый проход по прореженным кадрам находит,
/// где всплески вообще есть; второй разбирает на полной частоте только эти окна.
///
/// Точность контакта не страдает: внутри окон обрабатывается каждый кадр.
public struct TwoPassExtractor: Sendable {
    public struct Tuning: Sendable {
        /// К какой частоте прореживать первый проход. Замах с проводкой
        /// длятся доли секунды, так что 30 кадров в секунду их не пропустят.
        public var coarseFrameRate: Double = 30
        public var windows = StrokeWindowFinder.Tuning()
        /// Ниже этого числа кадров прореживать нет смысла — накладные
        /// расходы на второй проход съедят выигрыш.
        public var minFramesToBother: Int = 900
        /// Первый проход стоит 1/stride полного. При stride 2 он съедает
        /// половину экономии и разбор выходит дороже одного прохода —
        /// проверено на записи 60 fps. Два прохода окупаются на слоу-мо,
        /// то есть ровно там, где полный проход и невыносим.
        public var minStride: Int = 3
        /// Принудительно, в обход проверок — для сравнения режимов.
        public var force = false

        public init() {}
    }

    public var tuning: Tuning

    public init(tuning: Tuning = Tuning()) {
        self.tuning = tuning
    }

    public func extract(
        from url: URL,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> PoseTrack {
        let source = try await VideoSource(url: url)

        // Короткое видео дешевле разобрать целиком, чем городить два прохода.
        let expectedFrames = Int(source.duration * Double(source.nominalFrameRate))
        if expectedFrames > 0, expectedFrames < tuning.minFramesToBother, !tuning.force {
            return try await PoseExtractor().extract(from: url, onProgress: onProgress)
        }

        let stride = max(1, Int((Double(source.nominalFrameRate) / tuning.coarseFrameRate).rounded()))
        if stride < tuning.minStride, !tuning.force {
            return try await PoseExtractor().extract(from: url, onProgress: onProgress)
        }

        let coarse = try await scan(source: source, shouldAnalyse: { index, _ in
            index % stride == 0
        }, progress: { onProgress($0 * 0.35) })

        let windows = StrokeWindowFinder.candidateWindows(
            frames: coarse.frames,
            duration: source.duration,
            tuning: tuning.windows
        )
        // Фон замеряется по всей записи и переезжает во второй проход:
        // в нём останутся только окна ударов, и медиана по ним фоном уже не будет.
        let background = StrokeWindowFinder.backgroundMotion(frames: coarse.frames)

        // Ничего похожего на удар — отдаём то, что уже посчитали, вместе
        // с его статистикой: приложению есть что показать и объяснить.
        guard !windows.isEmpty else {
            onProgress(1)
            return coarse.track(
                source: source,
                totalFrames: coarse.totalFrames,
                boundaries: [],
                background: nil
            )
        }

        let fine = try await scan(source: try await VideoSource(url: url), shouldAnalyse: { _, time in
            windows.contains { $0.contains(time) }
        }, progress: { onProgress(0.35 + $0 * 0.65) })

        onProgress(1)
        return fine.track(
            source: source,
            totalFrames: fine.totalFrames,
            boundaries: boundaries(in: fine.frames, frameRate: Double(source.nominalFrameRate)),
            background: background
        )
    }

    // MARK: - Проход

    private struct ScanResult {
        var frames: [PoseFrame] = []
        var failures = 0
        var totalFrames = 0

        func track(
            source: VideoSource,
            totalFrames: Int,
            boundaries: Set<Int>,
            background: BackgroundMotion?
        ) -> PoseTrack {
            let step = SignalProcessing.medianStep(frames.map(\.time))
            return PoseTrack(
                frames: frames,
                displaySize: source.displaySize,
                frameRate: step > 0 ? 1 / step : Double(source.nominalFrameRate),
                duration: source.duration,
                analysisFailures: failures,
                segmentBoundaries: boundaries,
                totalFrames: totalFrames,
                backgroundMotion: background
            )
        }
    }

    private func scan(
        source: VideoSource,
        shouldAnalyse: (Int, TimeInterval) -> Bool,
        progress: @Sendable (Double) -> Void
    ) async throws -> ScanResult {
        var request = DetectHumanBodyPoseRequest()
        request.detectsHands = false

        var tracker = PlayerTracker()
        var result = ScanResult()
        var index = 0
        var lastReport = 0.0

        while let sample = source.output.copyNextSampleBuffer() {
            defer { index += 1 }
            result.totalFrames += 1

            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard time.isFinite, shouldAnalyse(index, time) else { continue }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }

            var observations: [HumanBodyPoseObservation] = []
            do {
                observations = try await request.perform(on: buffer, orientation: source.orientation)
            } catch {
                result.failures += 1
            }

            let candidates = observations.map {
                PoseCandidate(joints: PoseMapping.joints(from: $0, displaySize: source.displaySize))
            }
            let chosen = tracker.select(from: candidates, at: time)
            result.frames.append(
                PoseFrame(time: time, joints: chosen.map { candidates[$0].joints } ?? [:])
            )

            if source.duration > 0 {
                let share = min(1, time / source.duration)
                if share - lastReport > 0.01 {
                    lastReport = share
                    progress(share)
                }
            }
        }

        if source.reader.status == .failed {
            throw PoseExtractionError.readerFailed(
                source.reader.error?.localizedDescription ?? "чтение прервалось"
            )
        }
        return result
    }

    /// Границы кусков: там, где между соседними кадрами лежит пропущенное время.
    private func boundaries(in frames: [PoseFrame], frameRate: Double) -> Set<Int> {
        guard frames.count > 1 else { return [] }
        let expected = frameRate > 0 ? 1 / frameRate : 1 / 30.0
        let tolerance = expected * 2.5

        var result: Set<Int> = []
        for index in 1..<frames.count where frames[index].time - frames[index - 1].time > tolerance {
            result.insert(index)
        }
        return result
    }
}

/// Настроенный на чтение видеофайл: чтобы оба прохода заводились одинаково.
struct VideoSource {
    let reader: AVAssetReader
    let output: AVAssetReaderTrackOutput
    let displaySize: CGSize
    let orientation: CGImagePropertyOrientation
    let duration: TimeInterval
    let nominalFrameRate: Float

    init(url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw PoseExtractionError.noVideoTrack
        }
        let (naturalSize, transform, rate) = try await track.load(
            .naturalSize, .preferredTransform, .nominalFrameRate
        )
        duration = try await asset.load(.duration).seconds
        nominalFrameRate = rate > 0 ? rate : 30
        orientation = PoseExtractor.orientation(for: transform)
        displaySize = PoseExtractor.displaySize(naturalSize: naturalSize, orientation: orientation)

        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw PoseExtractionError.readerFailed(
                reader.error?.localizedDescription ?? "неизвестная ошибка"
            )
        }
    }
}
