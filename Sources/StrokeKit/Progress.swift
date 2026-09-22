import Foundation

/// Тренировка в ряду прогресса — только то, что нужно для сравнения.
public struct ProgressSession: Sendable, Identifiable {
    public let id: UUID
    public let date: Date
    public let digest: SessionDigest

    public init(id: UUID, date: Date, digest: SessionDigest) {
        self.id = id
        self.date = date
        self.digest = digest
    }
}

/// Одна метрика в одной тренировке — точка на графике.
public struct ProgressPoint: Sendable, Identifiable {
    public let sessionID: UUID
    public let date: Date
    public let cameraView: CameraView
    public let digest: MetricDigest
    /// Шум измерения на той записи — разные съёмки меряют с разной точностью.
    public let noise: Double?

    public var id: UUID { sessionID }
    public var mean: Double { digest.mean }
    public var spread: Double { digest.spread }
    public var count: Int { digest.count }
}

public enum ProgressVerdict: String, Sendable, Equatable {
    /// Изменение больше случайной разницы и в ту сторону, которая лучше.
    case improved
    case worsened
    /// Изменение заметное, но «лучше» у этой метрики не определено.
    case changed
    /// Разница не отличима от случайной.
    case inconclusive
}

/// Разница между двумя тренировками по одной величине.
public struct ProgressChange: Sendable {
    public enum Quantity: Sendable, Equatable {
        /// Разброс внутри тренировки — то, ради чего всё и считается.
        case spread
        /// Среднее значение метрики.
        case mean
    }

    public let key: MetricKey
    public let quantity: Quantity
    public let verdict: ProgressVerdict
    public let from: Double
    public let to: Double
    public let fromCount: Int
    public let toCount: Int
    /// Порог: разницу меньше этой величины отличить от случайной нельзя.
    public let uncertainty: Double

    public var delta: Double { to - from }
    /// Во сколько раз разница превышает порог. Меньше единицы — вывода нет.
    public var ratio: Double {
        guard uncertainty > 0, uncertainty.isFinite else { return 0 }
        return abs(delta) / uncertainty
    }

    public var isCertain: Bool { verdict != .inconclusive }

    /// Готовая фраза: числа, вывод и — когда вывода нет — почему.
    public var sentence: String {
        let a = key.format(from), b = key.formatWithUnit(to)
        switch (quantity, verdict) {
        case (.spread, .inconclusive):
            return "Было ±\(a), стало ±\(b). На \(fromCount) и \(toCount) ударах различить можно только разницу больше ±\(key.formatWithUnit(uncertainty)): разброс, посчитанный по горстке ударов, и сам по себе гуляет."
        case (.spread, .improved):
            return "Разброс упал: ±\(a) → ±\(b). Это больше случайной разницы — от удара к удару стало ровнее."
        case (.spread, _):
            return "Разброс вырос: ±\(a) → ±\(b). Это больше случайной разницы — удары разъехались сильнее прежнего."
        case (.mean, .inconclusive):
            return "В среднем было \(a), стало \(b). Разница меньше \(key.formatWithUnit(uncertainty)) — на таком числе ударов и при таком шуме съёмки это неотличимо от случайности."
        case (.mean, .improved):
            return "В среднем \(a) → \(b) — в нужную сторону."
        case (.mean, .worsened):
            return "В среднем \(a) → \(b) — в обратную сторону."
        case (.mean, .changed):
            return "В среднем \(a) → \(b). Само по себе ни лучше, ни хуже — у этой метрики важен разброс."
        }
    }
}

/// Одна метрика по всем тренировкам: ряд точек и выводы по краям ряда.
public struct MetricTrend: Sendable, Identifiable {
    public let key: MetricKey
    public let type: StrokeType
    /// От старой тренировки к свежей.
    public let points: [ProgressPoint]
    /// Последняя тренировка против предыдущей.
    public let spread: ProgressChange
    public let mean: ProgressChange
    /// Последняя против самой первой. Есть только начиная с трёх тренировок:
    /// на двух это та же пара, что и выше.
    public let overall: ProgressChange?

    public var id: MetricKey { key }

    /// Насколько эту метрику стоит показать первой.
    public var score: Double {
        let certain = [spread, mean, overall].compactMap { $0 }.filter(\.isCertain)
        // Ничего достоверного — сортируем по тому, что ближе всего к порогу.
        guard !certain.isEmpty else {
            return ([spread, mean].map(\.ratio).max() ?? 0) / 100
        }
        return certain.map(\.ratio).max() ?? 0
    }
}

public enum ProgressEngine {
    /// Тренировка с меньшим числом ударов в ряд не идёт: и среднее,
    /// и разброс по ним — гадание, и это уже сказано в разборе.
    public static let minStrokes = InsightEngine.minStrokes
    /// Метрика должна быть набрана хотя бы тремя ударами в каждой тренировке.
    public static let minValues = 3
    /// Во сколько раз разница должна превышать случайную погрешность,
    /// чтобы её можно было назвать изменением. Два — это примерно 95%.
    public static let certainty = 2.0

    /// Типы ударов, по которым есть что сравнивать: минимум две тренировки
    /// с достаточным числом ударов. Самый частый — первым.
    public static func types(in sessions: [ProgressSession]) -> [StrokeType] {
        var counts: [StrokeType: Int] = [:]
        var sessionsWithType: [StrokeType: Int] = [:]
        for session in sessions {
            for type in session.digest.presentTypes where type != .unknown {
                guard let digest = session.digest.type(type), digest.strokeCount >= minStrokes else { continue }
                counts[type, default: 0] += digest.strokeCount
                sessionsWithType[type, default: 0] += 1
            }
        }
        return sessionsWithType
            .filter { $0.value >= 2 }
            .keys
            .sorted { (counts[$0] ?? 0) > (counts[$1] ?? 0) }
    }

    /// Ряды по всем метрикам этого типа удара, от самого весомого вывода
    /// к самому слабому.
    public static func trends(in sessions: [ProgressSession], type: StrokeType) -> [MetricTrend] {
        let ordered = sessions.sorted { $0.date < $1.date }
        return MetricKey.allCases.compactMap { key -> MetricTrend? in
            let points = ordered.compactMap { session -> ProgressPoint? in
                guard let typeDigest = session.digest.type(type),
                      typeDigest.strokeCount >= minStrokes,
                      let metric = typeDigest.metric(key),
                      metric.count >= minValues
                else { return nil }
                return ProgressPoint(
                    sessionID: session.id,
                    date: session.date,
                    cameraView: session.digest.cameraView,
                    digest: metric,
                    noise: session.digest.noise(for: key)
                )
            }
            guard points.count >= 2 else { return nil }

            let previous = points[points.count - 2], latest = points[points.count - 1]
            return MetricTrend(
                key: key,
                type: type,
                points: points,
                spread: spreadChange(key: key, from: previous, to: latest),
                mean: meanChange(key: key, type: type, from: previous, to: latest),
                overall: points.count >= 3
                    ? spreadChange(key: key, from: points[0], to: latest)
                    : nil
            )
        }
        .sorted { $0.score > $1.score }
    }

    // MARK: - Сравнение двух тренировок

    /// Разброс: меньше — всегда лучше, направление обсуждать не с чем.
    /// Спорна здесь только достоверность: оценка разброса по горстке ударов
    /// сама гуляет, и без этой поправки приложение объявляло бы прогресс
    /// после каждой второй тренировки.
    static func spreadChange(key: MetricKey, from: ProgressPoint, to: ProgressPoint) -> ProgressChange {
        let random = certainty * hypot(from.digest.spreadError, to.digest.spreadError)
        // Разницу в разбросе тоньше собственного дрожания прибор не различает,
        // сколько ударов ни набери.
        let threshold = max(random, max(from.noise ?? 0, to.noise ?? 0))
        let delta = to.spread - from.spread
        let verdict: ProgressVerdict = abs(delta) < threshold
            ? .inconclusive
            : (delta < 0 ? .improved : .worsened)
        return ProgressChange(
            key: key, quantity: .spread, verdict: verdict,
            from: from.spread, to: to.spread,
            fromCount: from.count, toCount: to.count,
            uncertainty: threshold
        )
    }

    /// Среднее: порог — случайная погрешность среднего, но не меньше шума
    /// измерения. Сдвинуть камеру на метр дешевле, чем изменить технику,
    /// и в цифрах это выглядит одинаково.
    static func meanChange(key: MetricKey, type: StrokeType, from: ProgressPoint, to: ProgressPoint) -> ProgressChange {
        let random = certainty * hypot(from.digest.meanError, to.digest.meanError)
        let noise = max(from.noise ?? 0, to.noise ?? 0)
        let threshold = max(random, noise)
        let delta = to.mean - from.mean

        var verdict: ProgressVerdict = .inconclusive
        if abs(delta) >= threshold {
            let guidance = key.guidance(for: type)
            switch guidance.direction {
            case .stableOnly:
                verdict = .changed
            case .higherIsBetter:
                // «Больше — лучше, до разумного предела»: выше ориентира
                // рост уже ничего не улучшает.
                verdict = beyondBand(guidance, from: from.mean, to: to.mean, higher: true)
                    ? .changed
                    : (delta > 0 ? .improved : .worsened)
            case .lowerIsBetter:
                verdict = beyondBand(guidance, from: from.mean, to: to.mean, higher: false)
                    ? .changed
                    : (delta < 0 ? .improved : .worsened)
            }
        }

        return ProgressChange(
            key: key, quantity: .mean, verdict: verdict,
            from: from.mean, to: to.mean,
            fromCount: from.count, toCount: to.count,
            uncertainty: threshold
        )
    }

    /// Оба значения уже по ту сторону ориентира — дальше двигаться некуда.
    private static func beyondBand(
        _ guidance: MetricGuidance, from: Double, to: Double, higher: Bool
    ) -> Bool {
        guard let band = guidance.band else { return false }
        return higher
            ? (from >= band.upperBound && to >= band.upperBound)
            : (from <= band.lowerBound && to <= band.lowerBound)
    }
}
