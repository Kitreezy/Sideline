import Foundation

/// Шум измерения — то, что показывает прибор, когда ничего не происходит.
///
/// Скелет от Vision дрожит, и на игроке в 4% кадра это дрожание — градусы
/// и десятые доли корпуса. Разброс метрики меньше шума ничего не говорит
/// о технике, а среднее, отличающееся от ориентира на величину шума, —
/// не отклонение. Поэтому шум замеряется по каждой записи отдельно: на тихих
/// отрезках, где игрок стоит, и показывается рядом с цифрами.
public struct NoiseFloor: Sendable, Codable {
    /// Шум в единицах метрики. Нет ключа — оценить не удалось.
    public let byMetric: [MetricKey: Double]
    /// Сколько секунд тишины нашлось. Меньше секунды — оценке верить нельзя.
    public let quietSeconds: TimeInterval

    public init(byMetric: [MetricKey: Double], quietSeconds: TimeInterval) {
        self.byMetric = byMetric
        self.quietSeconds = quietSeconds
    }

    public static let unknown = NoiseFloor(byMetric: [:], quietSeconds: 0)

    public func noise(for key: MetricKey) -> Double? {
        byMetric[key]
    }

    /// Метрика измерима, если шум меньше порога заметности: иначе любой
    /// разброс, который приложение назвало бы заметным, может быть шумом.
    public func isMeasurable(_ key: MetricKey) -> Bool {
        guard let noise = byMetric[key] else { return true }
        return noise < key.noticeableSpread
    }

    /// Порог заметности с поправкой на шум: разброс должен быть хотя бы
    /// вдвое выше шума, чтобы его можно было приписать технике.
    public func effectiveSpread(for key: MetricKey) -> Double {
        max(key.noticeableSpread, (byMetric[key] ?? 0) * 2)
    }
}

public enum NoiseEstimator {
    public struct Tuning: Sendable {
        /// Тихим считается отрезок, где сглаженная скорость кисти ниже этой
        /// доли от 20-го процентиля по записи, но не выше абсолютной планки.
        /// Сглаживание сильное: само дрожание, которое мы меряем, не должно
        /// ломать поиск тишины — оно усредняется, движение нет.
        public var quietSpeedFactor: Double = 1.5
        public var quietSpeedCeiling: Double = 2.0
        public var quietSmoothingSeconds: TimeInterval = 0.3
        /// Ходьба тоже «тихая» по кисти: исключаем по скорости таза.
        public var maxBodySpeed: Double = 0.6
        /// Шум — то, что остаётся после вычитания движения медленнее этого.
        /// Дрожание трекинга скачет от кадра к кадру, настоящее движение
        /// плавное; в тихом отрезке быстрого движения нет по определению.
        public var motionSmoothingSeconds: TimeInterval = 0.3
        /// Короче — не тишина, а пауза между движениями.
        public var minRunSeconds: TimeInterval = 0.75
        /// Больше не нужно: оценка сходится.
        public var maxTotalSeconds: TimeInterval = 6

        public init() {}
    }

    public static func estimate(
        signals: AnalyzedSignals,
        frameRate: Double,
        tuning: Tuning = Tuning()
    ) -> NoiseFloor {
        let runs = quietRuns(signals: signals, tuning: tuning)
        let seconds = runs.reduce(0.0) { $0 + signals.times[$1.upperBound - 1] - signals.times[$1.lowerBound] }
        guard seconds >= 1 else { return .unknown }

        // Внутри каждого отрезка вычитаем сильно сглаженную версию ряда —
        // медленное движение (игрок переминается, опускает руку) уходит,
        // остаётся покадровое дрожание. Это и есть шум того ряда, из которого
        // считаются метрики. По отрезкам берётся медиана: один отрезок,
        // в который всё же попало движение, не должен тянуть оценку вверх.
        func pooledSD(_ values: (Int) -> Double) -> Double? {
            var perRun: [Double] = []
            for run in runs {
                let times = run.map { signals.times[$0] }
                let raw = Signal(times: times, values: run.map(values))
                let motion = SignalProcessing.smooth(
                    SignalProcessing.interpolateGaps(raw), sigmaSeconds: tuning.motionSmoothingSeconds
                )
                var residuals: [Double] = []
                for (v, m) in zip(raw.values, motion.values) where v.isFinite && m.isFinite {
                    residuals.append(v - m)
                }
                guard residuals.count >= 10 else { continue }
                let variance = residuals.reduce(0) { $0 + $1 * $1 } / Double(residuals.count - 1)
                perRun.append(variance.squareRoot())
            }
            guard !perRun.isEmpty else { return nil }
            let sorted = perRun.sorted()
            return sorted[sorted.count / 2]
        }

        var noise: [MetricKey: Double] = [:]
        if let elbow = pooledSD({ signals.elbowAngle.values[$0] }) { noise[.elbowAtContact] = elbow }
        if let knee = pooledSD({ signals.kneeAngle.values[$0] }) { noise[.minKneeAngle] = knee }
        if let shoulder = pooledSD({ signals.shoulderAngle.values[$0] }) {
            // Амплитуда — это размах по окну удара; размах шумного ряда — около 3σ.
            noise[.shoulderRotationRange] = shoulder * 3
            if let hip = pooledSD({ signals.hipAngle.values[$0] }) {
                noise[.maxSeparation] = (shoulder * shoulder + hip * hip).squareRoot() * 2
            }
        }
        if let height = pooledSD({ i in
            let hip = signals.hipY.values[i], wrist = signals.wristY.values[i]
            return (hip - wrist) / signals.scale(at: i)
        }) { noise[.contactHeight] = height }
        if let depth = pooledSD({ i in
            let hip = signals.hipX.values[i], wrist = signals.wristX.values[i]
            return (wrist - hip) / signals.scale(at: i)
        }) { noise[.contactDepth] = depth }

        // Скорость: пока игрок стоит, скорость кисти — чистый шум.
        let quietSpeeds = runs.flatMap { $0.map { signals.wristSpeed.values[$0] } }.filter { $0.isFinite }.sorted()
        if !quietSpeeds.isEmpty { noise[.peakWristSpeed] = quietSpeeds[quietSpeeds.count / 2] }

        // Тайминги упираются в кадр: пик локализуется с точностью ±2 кадра.
        if frameRate > 0 {
            noise[.backswingDuration] = 2 / frameRate
            noise[.forwardSwingDuration] = 2 / frameRate
        }

        return NoiseFloor(byMetric: noise, quietSeconds: seconds)
    }

    /// Отрезки, где игрок стоит: скелет виден, кисть почти не движется,
    /// разрывов внутри нет. Самые длинные первыми.
    public static func quietRuns(signals: AnalyzedSignals, tuning: Tuning = Tuning()) -> [Range<Int>] {
        let speed = SignalProcessing.perSegment(signals.wristSpeed, boundaries: signals.cutIndices) {
            SignalProcessing.smooth($0, sigmaSeconds: tuning.quietSmoothingSeconds)
        }.values
        let finite = speed.filter { $0.isFinite }.sorted()
        guard finite.count > 20 else { return [] }
        let p20 = finite[finite.count / 5]
        let threshold = min(p20 * tuning.quietSpeedFactor, tuning.quietSpeedCeiling)

        // Скорость таза — чтобы не принять ходьбу за тишину.
        let bodyX = SignalProcessing.perSegment(signals.hipX, boundaries: signals.cutIndices, SignalProcessing.derivative).values
        let bodyY = SignalProcessing.perSegment(signals.hipY, boundaries: signals.cutIndices, SignalProcessing.derivative).values

        var runs: [Range<Int>] = []
        var start: Int?
        for i in speed.indices {
            let bodySpeed = (bodyX[i].isFinite && bodyY[i].isFinite)
                ? (bodyX[i] * bodyX[i] + bodyY[i] * bodyY[i]).squareRoot() / signals.scale(at: i)
                : Double.infinity
            let quiet = speed[i].isFinite && speed[i] <= threshold
                && bodySpeed <= tuning.maxBodySpeed
                && signals.elbowAngle.values[i].isFinite
                && !signals.cutIndices.contains(i)
            if quiet {
                if start == nil { start = i }
            } else if let s = start {
                runs.append(s..<i)
                start = nil
            }
        }
        if let s = start { runs.append(s..<speed.count) }

        let long = runs.filter { signals.times[$0.upperBound - 1] - signals.times[$0.lowerBound] >= tuning.minRunSeconds }
        guard !long.isEmpty else { return [] }

        // Из тихих берём самые тихие: медленная ходьба тоже проходит порог,
        // а нам нужен игрок, который стоит. Отрезки ранжируются по средней
        // скорости, и остаются те, что не хуже самого тихого в полтора раза.
        func meanSpeed(_ run: Range<Int>) -> Double {
            let values = run.map { speed[$0] }.filter { $0.isFinite }
            return values.isEmpty ? .infinity : values.reduce(0, +) / Double(values.count)
        }
        let ranked = long.map { ($0, meanSpeed($0)) }.sorted { $0.1 < $1.1 }
        let stillest = ranked[0].1
        let limit = max(stillest * 1.5, stillest + 0.05)

        var picked: [Range<Int>] = []
        var total = 0.0
        for (run, mean) in ranked where mean <= limit {
            guard total < tuning.maxTotalSeconds else { break }
            picked.append(run)
            total += signals.times[run.upperBound - 1] - signals.times[run.lowerBound]
        }
        return picked
    }
}
