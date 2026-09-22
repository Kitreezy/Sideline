import Foundation

/// Одна метрика одного типа удара в одной тренировке.
public struct MetricDigest: Codable, Sendable, Equatable {
    public let mean: Double
    /// Разброс внутри тренировки — стандартное отклонение.
    public let spread: Double
    /// Сколько ударов дали значение.
    public let count: Int

    public init(mean: Double, spread: Double, count: Int) {
        self.mean = mean
        self.spread = spread
        self.count = count
    }

    /// Случайная погрешность среднего. Среднее по восьми ударам не знает
    /// себя точнее, чем на sd/√8, — и сравнивать два таких средних
    /// без этой поправки значит видеть прогресс там, где его нет.
    public var meanError: Double {
        count > 0 ? spread / Double(count).squareRoot() : .infinity
    }

    /// Случайная погрешность самой оценки разброса: sd/√(2(n−1)).
    /// На восьми ударах это 27% — то есть ±18° и ±13° по восьми ударам
    /// неотличимы, хотя на экране выглядят как заметное улучшение.
    public var spreadError: Double {
        count > 1 ? spread / (2 * Double(count - 1)).squareRoot() : .infinity
    }
}

/// Сводка по одному типу удара.
public struct TypeDigest: Codable, Sendable, Equatable {
    public let strokeCount: Int
    /// Ключ — `MetricKey.rawValue`: словарь с enum-ключом уезжает в JSON
    /// массивом, а этот файл иногда читают глазами.
    let metricsByKey: [String: MetricDigest]

    public init(strokeCount: Int, metrics: [MetricKey: MetricDigest]) {
        self.strokeCount = strokeCount
        self.metricsByKey = Dictionary(uniqueKeysWithValues: metrics.map { ($0.key.rawValue, $0.value) })
    }

    public func metric(_ key: MetricKey) -> MetricDigest? {
        metricsByKey[key.rawValue]
    }

    public var measuredKeys: [MetricKey] {
        MetricKey.allCases.filter { metricsByKey[$0.rawValue] != nil }
    }
}

/// Что осталось от тренировки, когда разбор закрыли: средние, разбросы
/// и шум измерения. Считается за миллисекунды из готового разбора и лежит
/// рядом с ним, чтобы прогресс между тренировками строился без чтения
/// дорожек скелета — на телефоне каждая из них разбирается секунды.
public struct SessionDigest: Codable, Sendable, Equatable {
    /// Поднимать, когда меняются правила счёта метрик: сводка, посчитанная
    /// старыми правилами, рядом с новой — это два разных прибора на одном
    /// графике. Несовпадение версии означает «пересчитать из дорожки».
    public static let currentVersion = 1

    public let version: Int
    public let cameraView: CameraView
    public let quietSeconds: TimeInterval
    let noiseByKey: [String: Double]
    let typesByKey: [String: TypeDigest]

    public init(
        version: Int = SessionDigest.currentVersion,
        cameraView: CameraView,
        quietSeconds: TimeInterval,
        noise: [MetricKey: Double],
        types: [StrokeType: TypeDigest]
    ) {
        self.version = version
        self.cameraView = cameraView
        self.quietSeconds = quietSeconds
        self.noiseByKey = Dictionary(uniqueKeysWithValues: noise.map { ($0.key.rawValue, $0.value) })
        self.typesByKey = Dictionary(uniqueKeysWithValues: types.map { ($0.key.rawValue, $0.value) })
    }

    /// Сводка по готовому разбору. Метрика попадает сюда, только если она
    /// на этой записи измерима и набрана достаточным числом ударов: класть
    /// в ряд прогресса число, которое мы сами отказались показывать
    /// в разборе, — это показать его с чёрного хода.
    public init(_ analysis: SessionAnalysis) {
        var types: [StrokeType: TypeDigest] = [:]
        for type in analysis.presentTypes {
            let total = analysis.strokes(of: type).count
            var metrics: [MetricKey: MetricDigest] = [:]
            for summary in analysis.summaries(of: type)
            where analysis.isMeasurable(summary.key)
                && summary.mean.isFinite
                && summary.standardDeviation.isFinite
                && summary.isWellSampled(of: total) {
                metrics[summary.key] = MetricDigest(
                    mean: summary.mean,
                    spread: summary.standardDeviation,
                    count: summary.finiteCount
                )
            }
            types[type] = TypeDigest(strokeCount: total, metrics: metrics)
        }

        self.init(
            cameraView: analysis.cameraView,
            quietSeconds: analysis.noise.quietSeconds,
            noise: analysis.noise.byMetric.filter { $0.value.isFinite },
            types: types
        )
    }

    public func type(_ type: StrokeType) -> TypeDigest? {
        typesByKey[type.rawValue]
    }

    public func noise(for key: MetricKey) -> Double? {
        noiseByKey[key.rawValue]
    }

    public var presentTypes: [StrokeType] {
        StrokeType.allCases.filter { typesByKey[$0.rawValue] != nil }
    }

    public var strokeCount: Int {
        typesByKey.values.reduce(0) { $0 + $1.strokeCount }
    }

    public var isCurrent: Bool { version == Self.currentVersion }
}
