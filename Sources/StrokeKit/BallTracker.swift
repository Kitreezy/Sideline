import AVFoundation
import CoreGraphics
import Foundation
import Vision

/// Кусок полёта мяча, как его видит детектор траекторий: параболическая
/// дуга мелкого объекта. Отскок разрывает дугу, удар — тем более.
public struct BallTrajectory: Sendable, Codable, Identifiable {
    public let id: UUID
    public let start: TimeInterval
    public let end: TimeInterval
    /// В пикселях кадра, начало координат сверху слева.
    public let points: [CGPoint]

    public init(id: UUID, start: TimeInterval, end: TimeInterval, points: [CGPoint]) {
        self.id = id
        self.start = start
        self.end = end
        self.points = points
    }

    public var first: CGPoint? { points.first }
    public var last: CGPoint? { points.last }
}

/// Гоняет `DetectTrajectoriesRequest` по окнам вокруг ударов.
///
/// Детектор видит любой мелкий движущийся объект — на дальней съёмке кисть
/// и стопа размером с мяч. Поэтому сам по себе список траекторий шумный,
/// и отделять мяч от тела — работа `BallContactMatcher`, а не этого класса.
public struct BallTracker: Sendable {
    public struct Tuning: Sendable {
        /// Минимум точек, чтобы дуга считалась траекторией. Меньше — ловим шум.
        public var trajectoryLength = 10
        /// Радиус объекта в долях кадра. Мяч на дальней съёмке — 5–6 px из 1920.
        public var minRadius: Float = 0.002
        public var maxRadius: Float = 0.012
        /// Сколько взять до и после предполагаемого контакта: входящему мячу
        /// нужно время долететь, а оценка контакта по кисти может опоздать.
        public var leadTime: TimeInterval = 1.5
        public var lagTime: TimeInterval = 0.6

        public init() {}
    }

    public var tuning: Tuning

    public init(tuning: Tuning = Tuning()) {
        self.tuning = tuning
    }

    /// Окна вокруг моментов контакта, слитые там, где перекрываются.
    public func windows(around contactTimes: [TimeInterval], duration: TimeInterval) -> [ClosedRange<TimeInterval>] {
        let raw = contactTimes.map { time -> ClosedRange<TimeInterval> in
            let start = max(0, time - tuning.leadTime)
            let end = min(duration, time + tuning.lagTime)
            return start...max(start, end)
        }
        return StrokeWindowFinder.merge(raw)
    }

    public func trajectories(
        in url: URL,
        windows: [ClosedRange<TimeInterval>],
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> [BallTrajectory] {
        guard !windows.isEmpty else { return [] }
        var result: [BallTrajectory] = []
        let total = windows.reduce(0.0) { $0 + ($1.upperBound - $1.lowerBound) }
        var done = 0.0

        for window in windows {
            // Детектор с состоянием: между окнами лежит необработанное время,
            // и продолжать одну и ту же цепочку через разрыв нельзя.
            result += try await scan(url: url, window: window)
            done += window.upperBound - window.lowerBound
            onProgress(total > 0 ? done / total : 1)
        }
        return result
    }

    private func scan(url: URL, window: ClosedRange<TimeInterval>) async throws -> [BallTrajectory] {
        let source = try await VideoSource(
            url: url,
            timeRange: CMTimeRange(
                start: CMTime(seconds: window.lowerBound, preferredTimescale: 600),
                end: CMTime(seconds: window.upperBound, preferredTimescale: 600)
            )
        )

        let request = DetectTrajectoriesRequest(
            trajectoryLength: tuning.trajectoryLength,
            frameAnalysisSpacing: .zero
        )
        request.objectMinimumNormalizedRadius = tuning.minRadius
        request.objectMaximumNormalizedRadius = tuning.maxRadius

        // Одна траектория приходит много раз, пока растёт; оставляем последнюю версию.
        var latest: [UUID: BallTrajectory] = [:]
        while let sample = source.output.copyNextSampleBuffer() {
            let observations = (try? await request.perform(on: sample, orientation: source.orientation)) ?? []
            for observation in observations {
                guard let range = observation.timeRange, !observation.detectedPoints.isEmpty else { continue }
                latest[observation.uuid] = BallTrajectory(
                    id: observation.uuid,
                    start: range.start.seconds,
                    end: range.end.seconds,
                    points: observation.detectedPoints.map {
                        $0.toImageCoordinates(source.displaySize, origin: .upperLeft)
                    }
                )
            }
        }
        return latest.values.sorted { $0.start < $1.start }
    }
}

/// Мяч, оборвавшийся у игрока.
public struct BallContact: Sendable, Codable {
    public let time: TimeInterval
    public let point: CGPoint
    public let trajectoryID: UUID

    public init(time: TimeInterval, point: CGPoint, trajectoryID: UUID) {
        self.time = time
        self.point = point
        self.trajectoryID = trajectoryID
    }
}

/// Отличает мяч от рук и ног по одному признаку: мяч прилетает издалека
/// и обрывается у кисти. Рука никуда не прилетает — она всегда рядом.
public enum BallContactMatcher {
    public struct Tuning: Sendable {
        /// Откуда должна прийти траектория, в корпусах от кисти. Рука и ракетка
        /// начинаются ближе; мяч — из-за сетки.
        public var minApproach: Double = 2.0
        /// Насколько близко к кисти должна оборваться. Ракетка длиннее руки,
        /// контакт может быть на корпус дальше кисти.
        public var maxArrival: Double = 1.6
        /// Мяч прилетает до пика скорости кисти или почти на нём. После пика
        /// у кисти обрывается только обод ракетки в проводке — он тоже идёт
        /// издалека, потому что при большом замахе стартует далеко от того
        /// места, где кисть окажется на контакте.
        public var earlyTolerance: TimeInterval = 0.8
        public var lateTolerance: TimeInterval = 0.15
        /// Штраф за каждую секунду окончания после пика: мяч прилетает
        /// до пика, ракетка заканчивает путь после.
        public var latePenalty: Double = 6.0

        public init() {}
    }

    /// Кандидат с расстояниями — чтобы было видно, почему выбран именно он.
    public struct Candidate: Sendable {
        public let trajectory: BallTrajectory
        public let arrival: Double
        public let approach: Double
        public let wrist: CGPoint
    }

    /// Все траектории, подходящие по времени, с расстояниями до кисти.
    public static func candidates(
        near estimatedContact: TimeInterval,
        trajectories: [BallTrajectory],
        signals: AnalyzedSignals,
        tuning: Tuning = Tuning()
    ) -> [Candidate] {
        var result: [Candidate] = []
        for trajectory in trajectories {
            guard let first = trajectory.first, let last = trajectory.last else { continue }
            guard trajectory.end >= estimatedContact - tuning.earlyTolerance,
                  trajectory.end <= estimatedContact + tuning.lateTolerance,
                  let (wrist, scale) = wristAndScale(signals: signals, at: trajectory.end)
            else { continue }
            result.append(Candidate(
                trajectory: trajectory,
                arrival: Geometry.distance(last, wrist) / scale,
                approach: Geometry.distance(first, wrist) / scale,
                wrist: wrist
            ))
        }
        return result.sorted { $0.trajectory.end < $1.trajectory.end }
    }

    /// Ищет входящую траекторию, оборвавшуюся у кисти около момента контакта.
    public static func contact(
        near estimatedContact: TimeInterval,
        trajectories: [BallTrajectory],
        signals: AnalyzedSignals,
        tuning: Tuning = Tuning()
    ) -> BallContact? {
        var best: (contact: BallContact, arrival: Double)?
        for trajectory in trajectories {
            guard let first = trajectory.first, let last = trajectory.last else { continue }
            guard trajectory.end >= estimatedContact - tuning.earlyTolerance,
                  trajectory.end <= estimatedContact + tuning.lateTolerance
            else { continue }
            guard let (wrist, scale) = wristAndScale(signals: signals, at: trajectory.end) else { continue }

            let arrival = Geometry.distance(last, wrist) / scale
            let approach = Geometry.distance(first, wrist) / scale
            guard arrival <= tuning.maxArrival, approach >= tuning.minApproach else { continue }

            // Из подходящих берём ту, что пришла из самого далека и оборвалась
            // раньше: чем дальше старт, тем меньше шансов, что это ракетка
            // или стопа, а конец после пика — почти всегда проводка.
            let late = max(0, trajectory.end - estimatedContact)
            let score = approach - arrival - late * tuning.latePenalty
            if best == nil || score > best!.arrival {
                best = (BallContact(time: trajectory.end, point: last, trajectoryID: trajectory.id), score)
            }
        }
        return best?.contact
    }

    /// Кисть и масштаб в момент времени — по ближайшему кадру. Масштаб именно
    /// этого кадра: игрок у камеры втрое крупнее, чем на задней линии.
    static func wristAndScale(signals: AnalyzedSignals, at time: TimeInterval) -> (CGPoint, Double)? {
        guard let wrist = wristPosition(signals: signals, at: time),
              let index = StrokeAnalyzer.frameIndex(nearest: time, in: signals.times) else { return nil }
        let scale = signals.scale(at: index)
        guard scale > 0 else { return nil }
        return (wrist, scale)
    }

    /// Положение кисти в момент времени — по ближайшему кадру.
    public static func wristPosition(signals: AnalyzedSignals, at time: TimeInterval) -> CGPoint? {
        let times = signals.times
        guard !times.isEmpty else { return nil }
        var lo = 0, hi = times.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] < time { lo = mid + 1 } else { hi = mid }
        }
        // Ближайший из двух соседей, и только если он действительно рядом.
        var index = lo
        if lo > 0, abs(times[lo - 1] - time) < abs(times[lo] - time) { index = lo - 1 }
        guard abs(times[index] - time) < 0.1 else { return nil }
        let x = signals.wristX.values[index], y = signals.wristY.values[index]
        guard x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: x, y: y)
    }
}
