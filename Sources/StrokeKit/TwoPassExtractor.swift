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
        /// К какой частоте прореживать первый проход. Разгон настоящего удара
        /// длится 0.3–0.5 с; 15 кадров в секунду дают на него 5–7 точек,
        /// а синтетический вдвое резче удар находится и так (есть тест).
        public var coarseFrameRate: Double = 15
        /// Ширина кадра для первого прохода. Модель Vision внутри всё равно
        /// уменьшает кадр; подать ей маленький — минус треть времени на кадр
        /// при тех же 98% найденных скелетов (замерено на живой записи).
        public var coarseDecodeWidth = 640
        public var windows = StrokeWindowFinder.Tuning()
        /// Ниже этого числа кадров прореживать нет смысла — накладные
        /// расходы на второй проход съедят выигрыш.
        public var minFramesToBother: Int = 900
        /// Первый проход стоит примерно 0.65/stride полного (кадры меньше).
        /// При stride 2 это треть — окупается, если окна покрывают меньше
        /// двух третей записи; на тренировке они покрывают пятую часть.
        public var minStride: Int = 2
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
        onProgress: @escaping @Sendable (ExtractionProgress) -> Void = { _ in }
    ) async throws -> PoseTrack {
        onProgress(ExtractionProgress(stage: .opening, fraction: 0))
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

        // Первый проход — примерно 1/stride работы, но время на чтение кадров
        // фиксированное, поэтому ему отводится доля побольше расчётной.
        let coarseShare = 0.3
        let coarseSource = try await VideoSource(url: url, decodeWidth: tuning.coarseDecodeWidth)
        let coarse = try await scan(source: coarseSource, shouldAnalyse: { index, _ in
            index % stride == 0
        }, progress: { onProgress(ExtractionProgress(stage: .scanning, fraction: $0 * coarseShare)) })

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
            onProgress(ExtractionProgress(stage: .scanning, fraction: 1))
            return coarse.track(
                source: source,
                totalFrames: coarse.totalFrames,
                boundaries: [],
                background: nil
            )
        }

        // Каждое окно читается своим ридером с перемоткой: декодировать
        // всё видео заново ради пятой части кадров — лишние минуты.
        var fine = ScanResult()
        fine.totalFrames = coarse.totalFrames
        let totalSpan = windows.reduce(0.0) { $0 + ($1.upperBound - $1.lowerBound) }
        var doneSpan = 0.0

        for (number, window) in windows.enumerated() {
            let windowSource = try await VideoSource(
                url: url,
                timeRange: CMTimeRange(
                    start: CMTime(seconds: window.lowerBound, preferredTimescale: 600),
                    end: CMTime(seconds: window.upperBound, preferredTimescale: 600)
                )
            )
            let span = window.upperBound - window.lowerBound
            let spanBefore = doneSpan
            let part = try await scan(source: windowSource, shouldAnalyse: { _, _ in true }, progress: { share in
                let fraction = totalSpan > 0 ? (spanBefore + share * span) / totalSpan : 1
                onProgress(ExtractionProgress(
                    stage: .analysing(window: number + 1, of: windows.count),
                    fraction: coarseShare + fraction * (1 - coarseShare)
                ))
            })
            fine.frames += part.frames
            fine.failures += part.failures
            doneSpan += span
        }

        onProgress(ExtractionProgress(stage: .analysing(window: windows.count, of: windows.count), fraction: 1))
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

            if source.span > 0 {
                let share = min(1, max(0, (time - source.spanStart) / source.span))
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
    /// Размер кадра после поворота — в этих координатах лежат точки скелета,
    /// даже если декодировали уменьшенную копию.
    let displaySize: CGSize
    let orientation: CGImagePropertyOrientation
    let duration: TimeInterval
    let nominalFrameRate: Float
    /// Читаемый отрезок — для прогресса.
    let spanStart: TimeInterval
    let span: TimeInterval

    init(url: URL, timeRange: CMTimeRange? = nil, decodeWidth: Int? = nil) async throws {
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

        if let timeRange {
            spanStart = timeRange.start.seconds
            span = timeRange.duration.seconds
        } else {
            spanStart = 0
            span = duration
        }

        reader = try AVAssetReader(asset: asset)
        if let timeRange { reader.timeRange = timeRange }
        var settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        if let decodeWidth, decodeWidth < Int(naturalSize.width) {
            // Декодер уменьшает сам — дешевле, чем масштабировать потом.
            let scale = Double(decodeWidth) / Double(naturalSize.width)
            settings[kCVPixelBufferWidthKey as String] = decodeWidth
            settings[kCVPixelBufferHeightKey as String] = Int((Double(naturalSize.height) * scale).rounded())
        }
        output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw PoseExtractionError.readerFailed(
                reader.error?.localizedDescription ?? "неизвестная ошибка"
            )
        }
    }
}
