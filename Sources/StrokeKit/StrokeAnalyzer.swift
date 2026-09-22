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
    /// Медианная длина корпуса за всё видео — запасной масштаб.
    public let torsoScale: Double
    /// Длина корпуса в каждом кадре. Игрок ходит по корту и подходит
    /// к камере — его размер в кадре меняется втрое, и одна медиана на всё
    /// видео превращает шаг у камеры в «удар».
    public let torsoScaleSeries: Signal

    /// Масштаб в конкретном кадре, с запасным значением там, где корпус не виден.
    public func scale(at index: Int) -> Double {
        guard index >= 0, index < torsoScaleSeries.count else { return torsoScale }
        let value = torsoScaleSeries.values[index]
        return value.isFinite && value > 1 ? value : torsoScale
    }
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

    /// Тот же удар, но с контактом, измеренным по мячу. Фазы до и после
    /// подтягиваются так, чтобы порядок не нарушился.
    func replacingContact(with index: Int) -> StrokePhases {
        let contact = max(start + 1, min(end - 1, index))
        return StrokePhases(
            start: start,
            transition: min(transition, contact - 1),
            contact: contact,
            end: end,
            hasBackswing: hasBackswing && transition < contact
        )
    }
}

/// Геометрия движения кисти в окне удара. По этим признакам отличается
/// удар от всего остального, что тоже разгоняет кисть: сплит-степа,
/// подбора мяча, перехвата ракетки, дрожания трекинга.
public struct StrokeShape: Sendable {
    /// Смещение кисти от конца замаха до контакта, в длинах корпуса.
    public let forwardDisplacement: Double
    /// Длина пути кисти за тот же интервал. Больше смещения, если кисть
    /// петляла: у настоящего разгона путь и смещение почти совпадают.
    public let forwardPath: Double
    /// Смещение от контакта до конца окна — проводка.
    public let followThrough: Double
    /// Во сколько раз пик выше скорости на границах окна.
    public let prominence: Double
    public let hasBackswing: Bool

    /// Насколько прямо шла кисть: 1 — по прямой, 0 — вернулась туда же.
    public var straightness: Double {
        forwardPath > 1e-9 ? forwardDisplacement / forwardPath : 0
    }
}

/// Почему всплеск скорости кисти может оказаться не ударом.
public enum StrokeDoubt: String, Sendable, Codable, CaseIterable {
    /// Кисть почти не сдвинулась: сплит-степ, перехват ракетки, подбор мяча.
    case tinySwing
    /// Кисть петляла вместо разгона по дуге — похоже на дрожание трекинга.
    case wandering
    /// Пик едва выше фона: рука просто болталась при ходьбе.
    case noBurst
    /// Скелет в момент удара потерялся — форму движения не измерить.
    case lostTracking
    /// Мяч отслеживался на этой записи, но к этому взмаху не прилетал.
    case noBall

    public var title: String {
        switch self {
        case .tinySwing: return "Кисть почти не сдвинулась"
        case .wandering: return "Движение петляло"
        case .noBurst: return "Нет выраженного всплеска"
        case .lostTracking: return "Скелет терялся в момент удара"
        case .noBall: return "Мяч у ракетки не пойман — проверь по кадру"
        }
    }
}

public struct Stroke: Sendable, Identifiable {
    public let id: Int
    public let type: StrokeType
    public let shape: StrokeShape
    /// Автоматические сомнения. Пусто — похоже на настоящий удар.
    public let doubts: [StrokeDoubt]
    /// Мяч, оборвавшийся у кисти. Если есть — контакт измерен, а не оценён.
    public let ballContact: BallContact?
    public let phases: StrokePhases
    public let startTime: TimeInterval
    public let contactTime: TimeInterval
    public let endTime: TimeInterval
    public let values: [MetricKey: Double]

    public func value(_ key: MetricKey) -> Double { values[key] ?? .nan }

    public var isDoubtful: Bool { !doubts.isEmpty }
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
    /// Шум измерения на этой записи — по тихим отрезкам, где игрок стоит.
    public let noise: NoiseFloor

    /// Удары, которые в статистику не идут. Начинается с автоматических
    /// сомнений; пользователь может вернуть удар или, наоборот, выкинуть —
    /// он видит запись, ему виднее.
    public var rejectedIDs: Set<Int>

    public init(
        track: PoseTrack,
        handedness: Handedness,
        cameraView: CameraView,
        signals: AnalyzedSignals,
        strokes: [Stroke],
        warnings: [AnalysisWarning],
        noise: NoiseFloor = .unknown
    ) {
        self.track = track
        self.handedness = handedness
        self.cameraView = cameraView
        self.signals = signals
        self.strokes = strokes
        self.warnings = warnings
        self.noise = noise
        self.rejectedIDs = Set(strokes.filter(\.isDoubtful).map(\.id))
    }

    /// Метрика считается, если её видно в этом ракурсе и шум ниже порога
    /// заметности. Иначе честнее не показывать число вовсе.
    public func isMeasurable(_ key: MetricKey) -> Bool {
        key.isReliable(in: cameraView) && noise.isMeasurable(key)
    }

    /// Почему метрика не считается — ракурс или шум.
    public func unmeasurableReason(_ key: MetricKey) -> String? {
        if let reason = key.unreliabilityReason(in: cameraView) { return reason }
        guard let level = noise.noise(for: key), !noise.isMeasurable(key) else { return nil }
        let digits = key.fractionDigits
        return String(
            format: "Шум измерения ±%.\(digits)f %@ при пороге заметности ±%.\(digits)f: игрок в кадре слишком мелкий, чтобы это мерить.",
            level, key.unit, key.noticeableSpread
        )
    }

    public var acceptedStrokes: [Stroke] {
        strokes.filter { !rejectedIDs.contains($0.id) }
    }

    /// Ударов, у которых контакт измерен по мячу, а не оценён по кисти.
    public var ballConfirmedCount: Int {
        strokes.filter { $0.ballContact != nil }.count
    }

    public var rejectedStrokes: [Stroke] {
        strokes.filter { rejectedIDs.contains($0.id) }
    }

    public func isRejected(_ stroke: Stroke) -> Bool {
        rejectedIDs.contains(stroke.id)
    }

    public mutating func setRejected(_ rejected: Bool, for stroke: Stroke) {
        if rejected { rejectedIDs.insert(stroke.id) } else { rejectedIDs.remove(stroke.id) }
    }

    public func strokes(of type: StrokeType) -> [Stroke] {
        acceptedStrokes.filter { $0.type == type }
    }

    /// Типы ударов, которые реально нашлись, от самого частого к редкому.
    public var presentTypes: [StrokeType] {
        var counts: [StrokeType: Int] = [:]
        for stroke in acceptedStrokes { counts[stroke.type, default: 0] += 1 }
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

    /// От самой «гуляющей» метрики к стабильной. Метрики, которые здесь
    /// не измеримы — по ракурсу или по шуму, — сюда не попадают вовсе.
    /// Нестабильность считается относительно порога с поправкой на шум.
    public func ranked(of type: StrokeType) -> [MetricSummary] {
        summaries(of: type)
            .filter { isMeasurable($0.key) }
            .filter { $0.standardDeviation.isFinite && $0.mean.isFinite }
            .sorted { instability(of: $0) > instability(of: $1) }
    }

    /// Разброс относительно порога, поднятого до двух шумов.
    public func instability(of summary: MetricSummary) -> Double {
        let threshold = noise.effectiveSpread(for: summary.key)
        return threshold > 0 ? summary.standardDeviation / threshold : 0
    }

    /// Метрики, выключенные из-за ракурса или шума — их надо показать
    /// отдельно, иначе непонятно, куда они делись.
    public var disabledMetrics: [MetricKey] {
        MetricKey.allCases.filter { !isMeasurable($0) }
    }
}

public struct StrokeAnalyzer: Sendable {
    public struct Tuning: Sendable {
        /// Ниже этой скорости кисти это не удар, а подготовка.
        public var minPeakSpeed: Double = 2.0
        /// Два удара одного игрока не могут идти подряд быстрее: мяч должен
        /// слетать на ту сторону и вернуться. На живой записи при 0.6 с один
        /// бэкхенд засчитывался дважды — контакт и проводка.
        public var minStrokeSeparation: TimeInterval = 1.0
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

        // Отсев не-ударов. Пороги выставлены из геометрии: рука за разгон
        // проходит от корпуса до вытянутого положения — это заведомо больше
        // половины длины корпуса даже при съёмке сзади. Проверить на живой
        // записи ещё предстоит; они вынесены сюда именно поэтому.
        /// Минимальное смещение кисти от конца замаха до контакта, в корпусах.
        public var minForwardDisplacement: Double = 0.5
        /// Минимальная прямизна пути: полукруг даёт 0.64, дрожание — около нуля.
        public var minStraightness: Double = 0.45
        /// Пик должен быть хотя бы во столько раз выше скорости на краях окна.
        public var minProminence: Double = 2.0

        public init() {}
    }

    public var tuning: Tuning

    public init(tuning: Tuning = Tuning()) {
        self.tuning = tuning
    }

    public func analyze(
        track: PoseTrack,
        handedness: Handedness,
        ballTrajectories: [BallTrajectory]? = nil
    ) -> SessionAnalysis {
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
            guard let swing = phases(around: peak, signals: signals) else { continue }

            // Форма движения описывает сам взмах — она считается по пику скорости,
            // независимо от того, где потом окажется контакт.
            let shape = Self.shape(of: swing, signals: signals)

            // Мяч, оборвавшийся у кисти, даёт контакт точнее пика скорости:
            // на шумном скелете пик легко приходится на проводку.
            var phases = swing
            var ballContact: BallContact?
            if let ballTrajectories {
                ballContact = BallContactMatcher.contact(
                    near: signals.times[peak], trajectories: ballTrajectories, signals: signals
                )
                if let contact = ballContact,
                   let index = Self.frameIndex(nearest: contact.time, in: signals.times) {
                    phases = phases.replacingContact(with: index)
                }
            }

            let values = Self.metrics(for: phases, signals: signals, handedness: handedness)
            let type = StrokeClassifier.classify(
                phases: phases,
                frames: track.frames,
                signals: signals,
                handedness: handedness
            )
            // Прилетевший издалека и оборвавшийся у кисти мяч — это и есть удар.
            // Эвристики по форме против такого свидетельства не аргумент.
            let doubts = ballContact != nil ? [] : doubts(about: shape)
            strokes.append(
                Stroke(
                    id: order,
                    type: type,
                    shape: shape,
                    doubts: doubts,
                    ballContact: ballContact,
                    phases: phases,
                    startTime: signals.times[phases.start],
                    contactTime: signals.times[phases.contact],
                    endTime: signals.times[phases.end],
                    values: values
                )
            )
        }

        if ballTrajectories != nil {
            strokes = Self.applyingBallVerdict(to: strokes)
        }

        let cameraView = CameraViewDetector.detect(frames: track.frames)
        let noise = NoiseEstimator.estimate(signals: signals, frameRate: track.frameRate)

        return SessionAnalysis(
            track: track,
            handedness: handedness,
            cameraView: cameraView,
            signals: signals,
            strokes: strokes,
            warnings: Self.warnings(
                track: track,
                signals: signals,
                strokeCount: strokes.filter { !$0.isDoubtful }.count,
                cameraView: cameraView,
                noise: noise
            ),
            noise: noise
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

    public static func buildSignals(track: PoseTrack, handedness: Handedness) -> AnalyzedSignals {
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

        // Размер игрока меняется медленно — сглаживаем сильно, чтобы замах
        // (шея и таз чуть расходятся) не читался как приближение к камере.
        let scaleSeries = SignalProcessing.perSegment(
            Signal(times: times, values: frames.map { frame in
                guard let neck = frame.point(.neck, minConfidence: 0.5),
                      let root = frame.point(.root, minConfidence: 0.5) else { return .nan }
                let length = Geometry.distance(neck, root)
                return length > 1 ? length : .nan
            }),
            boundaries: cuts
        ) { SignalProcessing.smooth(SignalProcessing.interpolateGaps($0, maxGapSeconds: 1.0), sigmaSeconds: 0.5) }

        func scaleAt(_ index: Int) -> Double {
            let value = scaleSeries.values[index]
            return value.isFinite && value > 1 ? value : scale
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
            speedValues[i] = (a * a + b * b).squareRoot() / scaleAt(i)
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
            torsoScaleSeries: scaleSeries,
            cutIndices: cuts
        )
    }

    /// Кадры, на которых скелет не мог оказаться там, где оказался: склейка в
    /// монтаже, потеря трекинга или перескок Vision на другого человека.
    /// Без этого разрыв даёт всплеск скорости и читается как мощнейший удар.
    static func detectCuts(frames: [PoseFrame], scale: Double, threshold: Double) -> Set<Int> {
        var cuts: Set<Int> = []
        guard frames.count > 1, scale > 0 else { return cuts }

        // Сравниваем не соседние кадры, а медианы по нескольким кадрам до
        // и после: настоящая склейка или перескок на другого человека меняют
        // положение и размер устойчиво, а дрожание трекинга — на один кадр.
        // На мелком игроке дрожание в 20 px давало сотни ложных разрывов
        // и дробило разбор на обрывки.
        let window = 4
        let necks = frames.map { $0.point(.neck) }
        let torsos = frames.map { frame -> Double? in
            guard let neck = frame.point(.neck), let root = frame.point(.root) else { return nil }
            let length = Geometry.distance(neck, root)
            return length > 1 ? length : nil
        }

        func median(_ values: [Double]) -> Double? {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        func medianPoint(_ range: Range<Int>) -> CGPoint? {
            let points = range.compactMap { necks[$0] }
            guard points.count >= 2,
                  let x = median(points.map { Double($0.x) }),
                  let y = median(points.map { Double($0.y) }) else { return nil }
            return CGPoint(x: x, y: y)
        }
        func medianTorso(_ range: Range<Int>) -> Double? {
            let values = range.compactMap { torsos[$0] }
            return values.count >= 2 ? median(values) : nil
        }

        for index in 1..<frames.count {
            let hadSkeleton = frames[index - 1].joints.count >= 8
            let hasSkeleton = frames[index].joints.count >= 8
            if hadSkeleton != hasSkeleton {
                cuts.insert(index)
                continue
            }

            let before = max(0, index - window)..<index
            let after = index..<min(frames.count, index + window)
            guard let neckBefore = medianPoint(before), let neckAfter = medianPoint(after) else { continue }

            if Geometry.distance(neckBefore, neckAfter) / scale > threshold {
                cuts.insert(index)
                continue
            }
            if let torsoBefore = medianTorso(before), let torsoAfter = medianTorso(after),
               max(torsoBefore, torsoAfter) / min(torsoBefore, torsoAfter) > 1.3 {
                cuts.insert(index)
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

    static func frameIndex(nearest time: TimeInterval, in times: [TimeInterval]) -> Int? {
        guard !times.isEmpty else { return nil }
        var lo = 0, hi = times.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] < time { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0, abs(times[lo - 1] - time) < abs(times[lo] - time) { return lo - 1 }
        return lo
    }

    /// Когда мяч на этой записи ловится, взмахи без мяча уходят на проверку,
    /// а не в статистику: на живой записи по форме движения они почти все
    /// оказались ложными — стоящий игрок с ракеткой по скелету неотличим
    /// от бьющего. Кадр контакта в списке делает проверку одним свайпом.
    /// Когда мяч не пойман ни разу (яркий фон, слишком далеко), «мяча нет»
    /// ничего не значит, и форма остаётся единственным судьёй.
    static func applyingBallVerdict(to strokes: [Stroke]) -> [Stroke] {
        let confirmed = strokes.filter { $0.ballContact != nil }.count
        guard confirmed >= 5 else { return strokes }

        return strokes.map { stroke in
            guard stroke.ballContact == nil, !stroke.doubts.contains(.noBall) else { return stroke }
            return Stroke(
                id: stroke.id, type: stroke.type, shape: stroke.shape,
                doubts: stroke.doubts + [.noBall],
                ballContact: nil, phases: stroke.phases,
                startTime: stroke.startTime, contactTime: stroke.contactTime, endTime: stroke.endTime,
                values: stroke.values
            )
        }
    }

    /// Что в форме движения не похоже на удар. Каждая проверка независима,
    /// чтобы в интерфейсе было видно, за что именно удар попал под сомнение.
    func doubts(about shape: StrokeShape) -> [StrokeDoubt] {
        var result: [StrokeDoubt] = []
        // Смещение не посчиталось — кисти в кадре не было. Ударом это
        // считать нельзя: не «не удар», а «не знаем», и в статистику не идёт.
        if !shape.forwardDisplacement.isFinite {
            return [.lostTracking]
        }
        if shape.forwardDisplacement.isFinite, shape.forwardDisplacement < tuning.minForwardDisplacement {
            result.append(.tinySwing)
        }
        if shape.forwardPath > 1e-9, shape.straightness < tuning.minStraightness {
            result.append(.wandering)
        }
        if shape.prominence.isFinite, shape.prominence < tuning.minProminence {
            result.append(.noBurst)
        }
        return result
    }

    // MARK: - Форма удара

    static func shape(of phases: StrokePhases, signals: AnalyzedSignals) -> StrokeShape {
        let scale = signals.scale(at: phases.contact)

        func point(_ index: Int) -> (x: Double, y: Double)? {
            let x = signals.wristX.values[index], y = signals.wristY.values[index]
            guard x.isFinite, y.isFinite else { return nil }
            return (x, y)
        }

        func displacement(_ from: Int, _ to: Int) -> Double {
            guard let a = point(from), let b = point(to) else { return .nan }
            return ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot() / scale
        }

        func path(_ from: Int, _ to: Int) -> Double {
            var total = 0.0
            var previous = point(from)
            for index in (from + 1)...max(from + 1, to) {
                guard let current = point(index) else { continue }
                if let p = previous {
                    total += ((current.x - p.x) * (current.x - p.x) + (current.y - p.y) * (current.y - p.y)).squareRoot()
                }
                previous = current
            }
            return total / scale
        }

        let speed = signals.wristSpeed.values
        let peak = speed[phases.contact]
        let edges = [speed[phases.start], speed[phases.end]].filter { $0.isFinite }
        let edge = edges.max() ?? 0
        let prominence = peak.isFinite && edge > 1e-9 ? peak / edge : .nan

        return StrokeShape(
            forwardDisplacement: displacement(phases.transition, phases.contact),
            forwardPath: path(phases.transition, phases.contact),
            followThrough: displacement(phases.contact, phases.end),
            prominence: prominence,
            hasBackswing: phases.hasBackswing
        )
    }

    // MARK: - Метрики удара

    static func metrics(
        for phases: StrokePhases,
        signals: AnalyzedSignals,
        handedness: Handedness
    ) -> [MetricKey: Double] {
        var values: [MetricKey: Double] = [:]
        let contact = phases.contact

        values[.peakWristSpeed] = extremum(signals.wristSpeed, from: phases.start, to: phases.end, pick: Swift.max)
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

        let contactScale = signals.scale(at: frameIndex)
        if let hipPoint, wristYValue.isFinite {
            // Ось Y растёт вниз, поэтому «выше таза» — это меньшее значение.
            values[.contactHeight] = (hipPoint.y - wristYValue) / contactScale
        } else {
            values[.contactHeight] = .nan
        }

        if let hipPoint, wristXValue.isFinite {
            // Знак скорости кисти на контакте задаёт, где для игрока «вперёд».
            let vx = SignalProcessing.derivative(signals.wristX).values[frameIndex]
            let forward: Double = vx.isFinite && vx != 0 ? (vx > 0 ? 1 : -1) : 1
            values[.contactDepth] = (wristXValue - hipPoint.x) * forward / contactScale
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
        cameraView: CameraView,
        noise: NoiseFloor = .unknown
    ) -> [AnalysisWarning] {
        var warnings: [AnalysisWarning] = []

        let drowned = MetricKey.allCases.filter { $0.isReliable(in: cameraView) && !noise.isMeasurable($0) }
        if !drowned.isEmpty {
            warnings.append(AnalysisWarning(
                text: "Шум измерения выше порога заметности у метрик: \(drowned.map(\.title).joined(separator: ", ")). На этой записи их не посчитать — игрок в кадре слишком мелкий. Ближе камера — ниже шум."
            ))
        }

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
                text: "Ракурс по ходу записи меняется — игрок ходит по корту и подходит к камере. Метрики, зависящие от ракурса, отключены: для них нужна съёмка сбоку с одной точки."
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
                text: "В \(signals.cutIndices.count) местах скелет пропадает или скачет — игрок выходит из кадра, слишком мелкий или его перекрывают; в нарезке из разных планов так выглядят склейки. Эти места из разбора выброшены."
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
