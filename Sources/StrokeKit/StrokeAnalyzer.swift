import CoreGraphics
import Foundation

/// Ряды, посчитанные по всему видео. Нужны и для метрик, и для графиков.
public struct AnalyzedSignals: Sendable {
    public let times: [TimeInterval]
    public let wristSpeed: Signal      // длин корпуса в секунду
    public let elbowAngle: Signal
    public let shoulderAngle: Signal
    public let hipAngle: Signal
    public let kneeAngle: Signal
    public let wristX: Signal
    public let wristY: Signal
    public let hipX: Signal            // центр таза со стороны бьющей руки
    public let hipY: Signal
    public let torsoScale: Double      // пикселей в одной «длине корпуса»
    /// Индексы, перед которыми скелет разрывается: склейка в ролике,
    /// потеря трекинга или перескок Vision на другого человека в кадре.
    public let cutIndices: Set<Int>

    /// Положение таза в кадре, если оно вообще было видно.
    public func hipReference(at index: Int) -> (x: Double, y: Double)? {
        guard index >= 0, index < hipX.count else { return nil }
        let x = hipX.values[index], y = hipY.values[index]
        guard x.isFinite, y.isFinite else { return nil }
        return (x, y)
    }
}

/// Границы одного удара в индексах кадров.
public struct StrokePhases: Sendable {
    public let start: Int
    public let transition: Int   // конец замаха / начало разгона
    public let contact: Int      // оценка момента контакта
    public let end: Int
    /// Нашёлся ли отдельный горб замаха. Если нет, длительность замаха
    /// не считается: ноль здесь означал бы «замаха не было», а на деле
    /// это «мы его не увидели».
    public let hasBackswing: Bool
}

public struct Stroke: Sendable, Identifiable {
    public let id: Int
    public let type: StrokeType
    public let phases: StrokePhases
    public let startTime: TimeInterval
    public let contactTime: TimeInterval
    public let endTime: TimeInterval
    public let values: [MetricKey: Double]

    public func value(_ key: MetricKey) -> Double { values[key] ?? .nan }
}

public struct AnalysisWarning: Sendable, Identifiable {
    public let id = UUID()
    public let text: String
}

public struct SessionAnalysis: Sendable {
    public let track: PoseTrack
    public let handedness: Handedness
    public let cameraView: CameraView
    public let signals: AnalyzedSignals
    public let strokes: [Stroke]
    public let warnings: [AnalysisWarning]

    public func strokes(of type: StrokeType) -> [Stroke] {
        strokes.filter { $0.type == type }
    }

    /// Типы ударов, которые реально нашлись, от самого частого к редкому.
    public var presentTypes: [StrokeType] {
        var counts: [StrokeType: Int] = [:]
        for stroke in strokes { counts[stroke.type, default: 0] += 1 }
        return counts.sorted { $0.value > $1.value }.map(\.key)
    }

    /// Разброс считается отдельно по каждому типу удара: смешивать форхенды
    /// с бэкхендами бессмысленно, у них разная геометрия.
    public func summaries(of type: StrokeType) -> [MetricSummary] {
        let values = strokes(of: type)
        return MetricKey.allCases.map { key in
            MetricSummary(key: key, values: values.map { $0.value(key) })
        }
    }

    /// От самой «гуляющей» метрики к стабильной. Метрики, которые в этом
    /// ракурсе не работают, сюда не попадают вовсе.
    public func ranked(of type: StrokeType) -> [MetricSummary] {
        summaries(of: type)
            .filter { $0.key.isReliable(in: cameraView) }
            .filter { $0.standardDeviation.isFinite && $0.mean.isFinite }
            .sorted { $0.instability > $1.instability }
    }

    /// Метрики, выключенные из-за ракурса — их надо показать отдельно,
    /// иначе непонятно, куда они делись.
    public var disabledMetrics: [MetricKey] {
        MetricKey.allCases.filter { !$0.isReliable(in: cameraView) }
    }
}

public struct StrokeAnalyzer: Sendable {
    public struct Tuning: Sendable {
        /// Ниже этой скорости кисти это не удар, а подготовка.
        public var minPeakSpeed: Double = 2.0
        /// Два удара не могут идти подряд быстрее, чем раз в столько секунд.
        public var minStrokeSeparation: TimeInterval = 0.6
        /// Границы удара — там, где скорость упала до этой доли от пика.
        public var boundaryFraction: Double = 0.25
        public var maxBackswing: TimeInterval = 1.2
        public var maxFollowThrough: TimeInterval = 1.0
        /// Порог удара поднимается до этого множителя от медианной скорости кисти.
        /// Без этого один и тот же порог не переносится между съёмками:
        /// замедленное видео и другой масштаб кадра сдвигают все скорости разом.
        public var medianSpeedFactor: Double = 3.0
        /// За сколько длин корпуса за кадр шея не может уехать без склейки.
        public var cutJumpThreshold: Double = 0.35
        /// Горб замаха должен быть заметнее шума, но медленнее разгона —
        /// иначе за замах примется соседний удар.
        public var backswingMinShare: Double = 0.12
        public var backswingMaxShare: Double = 0.6
        /// Между замахом и разгоном обязана быть пауза: скорость должна
        /// провалиться хотя бы до этой доли от вершины замаха. Без этой
        /// проверки за «горб замаха» принимается сама граница окна разгона,
        /// где скорость по построению равна доле от пика.
        public var backswingDipShare: Double = 0.7

        public init() {}
    }

    public var tuning: Tuning

    public init(tuning: Tuning = Tuning()) {
        self.tuning = tuning
    }

    public func analyze(track: PoseTrack, handedness: Handedness) -> SessionAnalysis {
        let signals = Self.buildSignals(track: track, handedness: handedness)
        let threshold = Self.strokeThreshold(
            signals.wristSpeed,
            floor: tuning.minPeakSpeed,
            medianFactor: tuning.medianSpeedFactor,
            background: track.backgroundMotion?.median(for: handedness)
        )
        let peaks = SignalProcessing.findPeaks(
            signals.wristSpeed,
            minHeight: threshold,
            minSeparation: tuning.minStrokeSeparation
        )

        var strokes: [Stroke] = []
        for (order, peak) in peaks.enumerated() {
            guard let phases = phases(around: peak, signals: signals) else { continue }
            let values = Self.metrics(for: phases, signals: signals, handedness: handedness)
            let type = StrokeClassifier.classify(
                phases: phases,
                frames: track.frames,
                signals: signals,
                handedness: handedness
            )
            strokes.append(
                Stroke(
                    id: order,
                    type: type,
                    phases: phases,
                    startTime: signals.times[phases.start],
                    contactTime: signals.times[phases.contact],
                    endTime: signals.times[phases.end],
                    values: values
                )
            )
        }

        let cameraView = CameraViewDetector.detect(frames: track.frames)

        return SessionAnalysis(
            track: track,
            handedness: handedness,
            cameraView: cameraView,
            signals: signals,
            strokes: strokes,
            warnings: Self.warnings(
                track: track,
                signals: signals,
                strokeCount: strokes.count,
                cameraView: cameraView
            )
        )
    }

    /// Абсолютный порог не переносится между видео, поэтому берём максимум из
    /// него и величины, пропорциональной медианной скорости кисти в этом ролике.
    /// Медиана — это «фон» движения игрока между ударами.
    static func strokeThreshold(
        _ speed: Signal,
        floor: Double,
        medianFactor: Double,
        background: Double? = nil
    ) -> Double {
        if let background, background.isFinite {
            return Swift.max(floor, background * medianFactor)
        }
        let finite = speed.values.filter { $0.isFinite }.sorted()
        guard !finite.isEmpty else { return floor }
        let median = finite[finite.count / 2]
        return Swift.max(floor, median * medianFactor)
    }

    // MARK: - Ряды

    static func buildSignals(track: PoseTrack, handedness: Handedness) -> AnalyzedSignals {
        let frames = track.frames
        let times = frames.map(\.time)
        let scale = torsoScale(frames: frames, fallbackHeight: track.displaySize.height)

        // Разрывы бывают двух родов: найденные по прыжку скелета и заранее
        // известные — границы окон при двухпроходном разборе.
        let cuts = detectCuts(frames: frames, scale: scale, threshold: 0.35)
            .union(track.segmentBoundaries)

        func series(_ transform: (PoseFrame) -> Double) -> Signal {
            let raw = Signal(times: times, values: frames.map(transform))
            return SignalProcessing.perSegment(raw, boundaries: cuts) {
                SignalProcessing.smooth(SignalProcessing.interpolateGaps($0))
            }
        }

        let wristX = series { frame in
            frame.point(handedness.wrist).map { Double($0.x) } ?? .nan
        }
        let wristY = series { frame in
            frame.point(handedness.wrist).map { Double($0.y) } ?? .nan
        }

        let vx = SignalProcessing.perSegment(wristX, boundaries: cuts, SignalProcessing.derivative)
        let vy = SignalProcessing.perSegment(wristY, boundaries: cuts, SignalProcessing.derivative)
        var speedValues = [Double](repeating: .nan, count: times.count)
        for i in 0..<times.count {
            let a = vx.values[i], b = vy.values[i]
            guard !a.isNaN, !b.isNaN else { continue }
            speedValues[i] = (a * a + b * b).squareRoot() / scale
        }
        let wristSpeed = SignalProcessing.perSegment(
            Signal(times: times, values: speedValues),
            boundaries: cuts
        ) { SignalProcessing.smooth($0, sigmaSeconds: 0.02) }

        let elbowAngle = series { frame in
            guard let shoulder = frame.point(handedness.shoulder),
                  let elbow = frame.point(handedness.elbow),
                  let wrist = frame.point(handedness.wrist) else { return .nan }
            return Geometry.angle(shoulder, vertex: elbow, wrist)
        }

        let shoulderAngle = series { frame in
            guard let l = frame.point(.leftShoulder), let r = frame.point(.rightShoulder) else { return .nan }
            return Geometry.lineAngle(from: l, to: r)
        }

        let hipAngle = series { frame in
            guard let l = frame.point(.leftHip), let r = frame.point(.rightHip) else { return .nan }
            return Geometry.lineAngle(from: l, to: r)
        }

        let hipX = series { frame in
            guard let hip = frame.point(handedness.hip) ?? frame.point(.root) else { return .nan }
            return Double(hip.x)
        }
        let hipY = series { frame in
            guard let hip = frame.point(handedness.hip) ?? frame.point(.root) else { return .nan }
            return Double(hip.y)
        }

        let kneeAngle = series { frame in
            guard let hip = frame.point(handedness.hip),
                  let knee = frame.point(handedness.knee),
                  let ankle = frame.point(handedness == .right ? .rightAnkle : .leftAnkle) else { return .nan }
            return Geometry.angle(hip, vertex: knee, ankle)
        }

        return AnalyzedSignals(
            times: times,
            wristSpeed: wristSpeed,
            elbowAngle: elbowAngle,
            shoulderAngle: shoulderAngle,
            hipAngle: hipAngle,
            kneeAngle: kneeAngle,
            wristX: wristX,
            wristY: wristY,
            hipX: hipX,
            hipY: hipY,
            torsoScale: scale,
            cutIndices: cuts
        )
    }

    /// Кадры, на которых скелет не мог оказаться там, где оказался: склейка в
    /// монтаже, потеря трекинга или перескок Vision на другого человека.
    /// Без этого разрыв даёт всплеск скорости и читается как мощнейший удар.
    static func detectCuts(frames: [PoseFrame], scale: Double, threshold: Double) -> Set<Int> {
        var cuts: Set<Int> = []
        guard frames.count > 1, scale > 0 else { return cuts }

        for index in 1..<frames.count {
            let previous = frames[index - 1]
            let current = frames[index]

            let hadSkeleton = previous.joints.count >= 8
            let hasSkeleton = current.joints.count >= 8
            if hadSkeleton != hasSkeleton {
                cuts.insert(index)
                continue
            }

            // Прыжок опорных точек.
            for joint in [BodyJoint.neck, .root] {
                guard let a = previous.point(joint), let b = current.point(joint) else { continue }
                if Geometry.distance(a, b) / scale > threshold {
                    cuts.insert(index)
                    break
                }
            }
            if cuts.contains(index) { continue }

            // Резкая смена масштаба человека — верный признак смены плана.
            if let neckA = previous.point(.neck), let rootA = previous.point(.root),
               let neckB = current.point(.neck), let rootB = current.point(.root) {
                let before = Geometry.distance(neckA, rootA)
                let after = Geometry.distance(neckB, rootB)
                if before > 1, after > 1, max(before, after) / min(before, after) > 1.3 {
                    cuts.insert(index)
                }
            }
        }
        return cuts
    }

    /// Длина корпуса в пикселях — единица измерения, не зависящая от расстояния до камеры.
    static func torsoScale(frames: [PoseFrame], fallbackHeight: CGFloat) -> Double {
        var lengths: [Double] = []
        for frame in frames {
            if let neck = frame.point(.neck, minConfidence: 0.5),
               let root = frame.point(.root, minConfidence: 0.5) {
                lengths.append(Geometry.distance(neck, root))
            }
        }
        if lengths.isEmpty {
            for frame in frames {
                if let l = frame.point(.leftShoulder, minConfidence: 0.5),
                   let r = frame.point(.rightShoulder, minConfidence: 0.5) {
                    lengths.append(Geometry.distance(l, r) * 1.8)
                }
            }
        }
        guard !lengths.isEmpty else { return max(1, Double(fallbackHeight) / 3) }
        lengths.sort()
        let median = lengths[lengths.count / 2]
        return median > 1 ? median : max(1, Double(fallbackHeight) / 3)
    }

    // MARK: - Границы удара

    func phases(around peak: Int, signals: AnalyzedSignals) -> StrokePhases? {
        let speed = signals.wristSpeed
        guard peak > 0, peak < speed.count - 1 else { return nil }
        let peakValue = speed.values[peak]
        guard peakValue.isFinite else { return nil }
        let floorValue = peakValue * tuning.boundaryFraction

        // Удар не может начаться до склейки и закончиться после неё.
        if signals.cutIndices.contains(peak) { return nil }

        var start = peak
        while start > 0 {
            if signals.cutIndices.contains(start) { break }
            let t = signals.times[peak] - signals.times[start]
            if t > tuning.maxBackswing { break }
            let v = speed.values[start]
            if v.isNaN { break }
            if v < floorValue, t > 0.1 { break }
            start -= 1
        }

        var end = peak
        while end < speed.count - 1 {
            if signals.cutIndices.contains(end + 1) { break }
            let t = signals.times[end] - signals.times[peak]
            if t > tuning.maxFollowThrough { break }
            let v = speed.values[end]
            if v.isNaN { break }
            if v < floorValue, t > 0.1 { break }
            end += 1
        }

        guard end > start + 2 else { return nil }

        // Замах — это отдельный, более низкий горб скорости перед разгоном.
        // Ищем его строго до начала окна разгона, иначе «конец замаха»
        // вырождается в границу окна и длительность выходит нулевой.
        if start > 0,
           let hump = backswingHump(before: start - 1, peak: peak, peakValue: peakValue, signals: signals) {
            let transition = trough(between: hump, and: peak, signals: signals)
            let humpValue = signals.wristSpeed.values[hump]
            let troughValue = signals.wristSpeed.values[transition]

            let hasRealDip = transition > hump
                && humpValue.isFinite && troughValue.isFinite
                && troughValue <= humpValue * tuning.backswingDipShare

            if hasRealDip {
                return StrokePhases(
                    start: windowStart(of: hump, signals: signals),
                    transition: transition,
                    contact: peak,
                    end: end,
                    hasBackswing: true
                )
            }
        }

        return StrokePhases(
            start: start,
            transition: start,
            contact: peak,
            end: end,
            hasBackswing: false
        )
    }

    /// Вершина замаха: заметная, но заведомо более медленная, чем разгон.
    /// Верхняя граница отсекает соседний удар, нижняя — шум трекинга.
    private func backswingHump(
        before windowStart: Int,
        peak: Int,
        peakValue: Double,
        signals: AnalyzedSignals
    ) -> Int? {
        var best: (index: Int, value: Double)?
        var index = windowStart
        while index > 0 {
            if signals.cutIndices.contains(index) { break }
            if signals.times[peak] - signals.times[index] > tuning.maxBackswing { break }
            let value = signals.wristSpeed.values[index]
            if value.isFinite, best == nil || value > best!.value {
                best = (index, value)
            }
            index -= 1
        }

        guard let best else { return nil }
        let low = peakValue * tuning.backswingMinShare
        let high = peakValue * tuning.backswingMaxShare
        guard best.value >= low, best.value <= high else { return nil }
        return best.index
    }

    /// Пауза между замахом и разгоном — самая медленная точка между ними.
    private func trough(between hump: Int, and peak: Int, signals: AnalyzedSignals) -> Int {
        var index = hump
        var slowest = (index: hump, value: Double.infinity)
        while index < peak {
            let value = signals.wristSpeed.values[index]
            if value.isFinite, value < slowest.value {
                slowest = (index, value)
            }
            index += 1
        }
        return slowest.index
    }

    /// Начало замаха — там, где кисть ещё почти не двигалась.
    private func windowStart(of hump: Int, signals: AnalyzedSignals) -> Int {
        let humpValue = signals.wristSpeed.values[hump]
        guard humpValue.isFinite else { return hump }
        let floorValue = humpValue * tuning.boundaryFraction
        var index = hump
        while index > 0 {
            if signals.cutIndices.contains(index) { break }
            if signals.times[hump] - signals.times[index] > tuning.maxBackswing { break }
            let value = signals.wristSpeed.values[index]
            if !value.isFinite { break }
            if value < floorValue { break }
            index -= 1
        }
        return index
    }

    // MARK: - Метрики удара

    static func metrics(
        for phases: StrokePhases,
        signals: AnalyzedSignals,
        handedness: Handedness
    ) -> [MetricKey: Double] {
        var values: [MetricKey: Double] = [:]
        let contact = phases.contact

        values[.peakWristSpeed] = signals.wristSpeed.values[contact]
        values[.elbowAtContact] = signals.elbowAngle.values[contact]

        values[.shoulderRotationRange] = spread(signals.shoulderAngle, from: phases.start, to: phases.end)
        values[.minKneeAngle] = extremum(signals.kneeAngle, from: phases.start, to: phases.end, pick: min)

        // X-factor: максимальное расхождение линии плеч и линии таза до контакта.
        var maxSeparation = Double.nan
        for i in phases.start...contact {
            let s = signals.shoulderAngle.values[i]
            let h = signals.hipAngle.values[i]
            guard s.isFinite, h.isFinite else { continue }
            let diff = abs(s - h)
            if maxSeparation.isNaN || diff > maxSeparation { maxSeparation = diff }
        }
        values[.maxSeparation] = maxSeparation

        values[.backswingDuration] = phases.hasBackswing
            ? signals.times[phases.transition] - signals.times[phases.start]
            : .nan
        values[.forwardSwingDuration] = signals.times[contact] - signals.times[phases.transition]

        // Геометрия контакта — в длинах корпуса относительно таза.
        let frameIndex = contact
        let wristYValue = signals.wristY.values[frameIndex]
        let wristXValue = signals.wristX.values[frameIndex]
        let hipPoint = signals.hipReference(at: frameIndex)

        if let hipPoint, wristYValue.isFinite {
            // Ось Y растёт вниз, поэтому «выше таза» — это меньшее значение.
            values[.contactHeight] = (hipPoint.y - wristYValue) / signals.torsoScale
        } else {
            values[.contactHeight] = .nan
        }

        if let hipPoint, wristXValue.isFinite {
            // Знак скорости кисти на контакте задаёт, где для игрока «вперёд».
            let vx = SignalProcessing.derivative(signals.wristX).values[frameIndex]
            let forward: Double = vx.isFinite && vx != 0 ? (vx > 0 ? 1 : -1) : 1
            values[.contactDepth] = (wristXValue - hipPoint.x) * forward / signals.torsoScale
        } else {
            values[.contactDepth] = .nan
        }

        return values
    }

    private static func spread(_ signal: Signal, from: Int, to: Int) -> Double {
        var lo = Double.infinity, hi = -Double.infinity
        for i in from...to {
            let v = signal.values[i]
            guard v.isFinite else { continue }
            lo = Swift.min(lo, v)
            hi = Swift.max(hi, v)
        }
        return hi >= lo ? hi - lo : .nan
    }

    private static func extremum(
        _ signal: Signal,
        from: Int,
        to: Int,
        pick: (Double, Double) -> Double
    ) -> Double {
        var result = Double.nan
        for i in from...to {
            let v = signal.values[i]
            guard v.isFinite else { continue }
            result = result.isNaN ? v : pick(result, v)
        }
        return result
    }

    // MARK: - Предупреждения

    static func warnings(
        track: PoseTrack,
        signals: AnalyzedSignals,
        strokeCount: Int,
        cameraView: CameraView
    ) -> [AnalysisWarning] {
        var warnings: [AnalysisWarning] = []

        switch cameraView {
        case .side:
            break
        case .behind, .facing:
            let disabled = MetricKey.allCases.filter { !$0.isReliable(in: cameraView) }
            warnings.append(AnalysisWarning(
                text: "Снято не сбоку, а \(cameraView == .behind ? "из-за спины" : "спереди"). Метрики, которым нужна глубина, отключены: \(disabled.map(\.title).joined(separator: ", ")). Остальное считается как обычно."
            ))
        case .mixed:
            warnings.append(AnalysisWarning(
                text: "Ракурс по ходу видео меняется — похоже, это монтаж из разных планов. Метрики, зависящие от ракурса, отключены."
            ))
        case .unknown:
            warnings.append(AnalysisWarning(
                text: "Не удалось понять ракурс съёмки: слишком мало кадров, где игрок виден целиком."
            ))
        }

        if track.frameRate < 50 {
            let ms = Int((1000 / max(track.frameRate, 1)).rounded())
            warnings.append(AnalysisWarning(
                text: "Видео снято на \(Int(track.frameRate.rounded())) кадрах в секунду, поэтому момент контакта определён с точностью примерно ±\(ms) мс. Сними в слоу-мо (120 или 240 fps) — цифры станут заметно честнее."
            ))
        }

        // Ошибка распознавания и «человека в кадре нет» — разные диагнозы,
        // и советовать переснять видео во втором случае бесполезно.
        if track.analysisFailures > track.frames.count / 2 {
            warnings.append(AnalysisWarning(
                text: "Vision не смог обработать кадры: на этом устройстве распознавание позы недоступно. В симуляторе оно не работает вовсе — нужен настоящий телефон."
            ))
            return warnings
        }

        let tracked = track.frames.filter { $0.joints.count >= 8 }.count
        let ratio = track.frames.isEmpty ? 0 : Double(tracked) / Double(track.frames.count)
        if ratio < 0.6 {
            warnings.append(AnalysisWarning(
                text: "Скелет уверенно виден только в \(Int(ratio * 100))% кадров. Обычно причина в том, что игрок слишком мелкий в кадре или его перекрывает сетка."
            ))
        }

        if signals.cutIndices.count > 3 {
            warnings.append(AnalysisWarning(
                text: "В видео нашлось \(signals.cutIndices.count) мест, где скелет разрывается — это склейки монтажа или потеря трекинга. Такие места из анализа выброшены, но если это смонтированный ролик, а не одна съёмка, цифрам верить нельзя: они смешивают разные ракурсы и разных людей."
            ))
        }

        if strokeCount < 5 {
            warnings.append(AnalysisWarning(
                text: "Найдено \(strokeCount) ударов. Разброс на такой выборке ещё ничего не значит — сними серию хотя бы из 15–20 ударов."
            ))
        }

        return warnings
    }
}
