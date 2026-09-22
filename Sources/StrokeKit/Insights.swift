import Foundation

/// Один вывод для игрока: что заметно, почему это важно и что делать.
public struct Insight: Sendable, Identifiable {
    public enum Kind: Sendable {
        /// Метрика гуляет от удара к удару.
        case spread
        /// Среднее не дотягивает до ориентира.
        case shortfall
        /// Лучшие удары серии отличаются от слабых именно этим.
        case bestVsWorst
        /// То, что уже хорошо — чтобы не только ругать.
        case strength
    }

    public let kind: Kind
    public let key: MetricKey
    public let title: String
    public let detail: String
    public let cue: String?
    /// Чем больше, тем важнее. Единица — «уже заметно».
    public let score: Double

    public var id: String { "\(kind)-\(key.rawValue)" }
}

public enum InsightEngine {
    /// Ниже этого числа ударов любой вывод — гадание.
    public static let minStrokes = 5
    /// Для сравнения лучших с худшими нужно хотя бы по три в каждой группе.
    public static let minStrokesForComparison = 6

    /// «Над чем работать» — не больше `limit` пунктов, от важного к менее важному.
    public static func insights(
        for analysis: SessionAnalysis,
        type: StrokeType,
        limit: Int = 3
    ) -> [Insight] {
        let strokes = analysis.strokes(of: type)
        guard strokes.count >= minStrokes else { return [] }

        var candidates: [Insight] = []
        let summaries = analysis.summaries(of: type)
            .filter { analysis.isMeasurable($0.key) }
            .filter { $0.mean.isFinite && $0.standardDeviation.isFinite }
            .filter { $0.isWellSampled(of: strokes.count) }

        for summary in summaries {
            let guidance = summary.key.guidance(for: type)
            let noise = analysis.noise
            if let insight = spreadInsight(summary, guidance: guidance, noise: noise) { candidates.append(insight) }
            if let insight = shortfallInsight(summary, guidance: guidance, noise: noise) { candidates.append(insight) }
        }
        if let insight = bestVsWorstInsight(strokes: strokes, type: type, analysis: analysis) {
            candidates.append(insight)
        }

        // Одна метрика — один вывод, самый весомый: иначе «локоть гуляет»
        // и «локоть отличается у лучших» съедят оба места из трёх.
        var bestPerKey: [MetricKey: Insight] = [:]
        for insight in candidates where (bestPerKey[insight.key]?.score ?? 0) < insight.score {
            bestPerKey[insight.key] = insight
        }
        return bestPerKey.values.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }

    /// Самая стабильная метрика серии — чтобы было видно, на что опереться.
    public static func strength(for analysis: SessionAnalysis, type: StrokeType) -> Insight? {
        let total = analysis.strokes(of: type).count
        guard total >= minStrokes else { return nil }
        // Стабильность на уровне шума — не достижение, а предел прибора:
        // хвалить можно только за разброс, который прибор вообще способен увидеть.
        let candidate = analysis.summaries(of: type)
            .filter { analysis.isMeasurable($0.key) }
            .filter { $0.mean.isFinite && $0.standardDeviation.isFinite }
            .filter { $0.isWellSampled(of: total) }
            .filter { analysis.instability(of: $0) < 0.5 }
            .min { analysis.instability(of: $0) < analysis.instability(of: $1) }
        guard let candidate else { return nil }
        return Insight(
            kind: .strength,
            key: candidate.key,
            title: "\(candidate.key.title) — стабильно",
            detail: "Разброс всего ±\(format(candidate.standardDeviation, candidate.key)) \(candidate.key.unit). Это уже получается одинаково от удара к удару.",
            cue: nil,
            score: 1 - candidate.instability
        )
    }

    // MARK: - Виды выводов

    static func spreadInsight(_ summary: MetricSummary, guidance: MetricGuidance, noise: NoiseFloor) -> Insight? {
        let key = summary.key
        let threshold = noise.effectiveSpread(for: key)
        guard threshold > 0 else { return nil }
        let score = summary.standardDeviation / threshold
        guard score > 1 else { return nil }
        let noiseNote = noise.noise(for: key).map { " Шум измерения здесь ±\(format($0, key))." } ?? ""
        return Insight(
            kind: .spread,
            key: key,
            title: "\(key.title) — большой разброс",
            detail: "±\(format(summary.standardDeviation, key)) \(key.unit) от удара к удару, заметным считается уже ±\(format(threshold, key)).\(noiseNote) \(guidance.spreadConsequence)",
            cue: guidance.cue,
            score: score
        )
    }

    static func shortfallInsight(_ summary: MetricSummary, guidance: MetricGuidance, noise: NoiseFloor) -> Insight? {
        guard let band = guidance.band, summary.key.noticeableSpread > 0 else { return nil }
        let key = summary.key
        let mean = summary.mean

        let gap: Double
        let wording: String
        switch guidance.direction {
        case .higherIsBetter where mean < band.lowerBound:
            gap = band.lowerBound - mean
            wording = "ниже ориентира"
        case .lowerIsBetter where mean > band.upperBound:
            gap = mean - band.upperBound
            wording = "выше ориентира"
        case .stableOnly where !band.contains(mean):
            // Ориентир есть, но направление не задано: отмечаем мягче.
            gap = (mean < band.lowerBound ? band.lowerBound - mean : mean - band.upperBound) * 0.6
            wording = mean < band.lowerBound ? "ниже ориентира" : "выше ориентира"
        default:
            return nil
        }

        // Отклонение от ориентира меньше двух шумов — не отклонение.
        let score = gap / noise.effectiveSpread(for: key)
        guard score > 0.75 else { return nil }

        var detail = "В среднем \(format(mean, key)) \(key.unit), ориентир \(format(band.lowerBound, key))–\(format(band.upperBound, key))."
        if let consequence = guidance.shortfallConsequence { detail += " \(consequence)" }
        return Insight(
            kind: .shortfall,
            key: key,
            title: "\(key.title) — \(wording)",
            detail: detail,
            cue: guidance.cue,
            score: score
        )
    }

    /// Делим серию по скорости кисти на лучшую и худшую трети и ищем
    /// метрику, которая между ними расходится сильнее всего. Сравнение
    /// только с самим игроком — ни одной чужой нормы.
    static func bestVsWorstInsight(
        strokes: [Stroke],
        type: StrokeType,
        analysis: SessionAnalysis
    ) -> Insight? {
        guard strokes.count >= minStrokesForComparison else { return nil }
        let ordered = strokes
            .filter { $0.value(.peakWristSpeed).isFinite }
            .sorted { $0.value(.peakWristSpeed) > $1.value(.peakWristSpeed) }
        let third = ordered.count / 3
        guard third >= 3 else { return nil }
        let best = ordered.prefix(third)
        let worst = ordered.suffix(third)

        func mean(_ group: ArraySlice<Stroke>, _ key: MetricKey) -> Double? {
            let values = group.map { $0.value(key) }.filter { $0.isFinite }
            guard values.count >= 2 else { return nil }
            return values.reduce(0, +) / Double(values.count)
        }

        var top: (key: MetricKey, best: Double, worst: Double, score: Double)?
        for key in MetricKey.allCases where key != .peakWristSpeed && analysis.isMeasurable(key) {
            guard let a = mean(best, key), let b = mean(worst, key) else { continue }
            let threshold = analysis.noise.effectiveSpread(for: key)
            guard threshold > 0 else { continue }
            let score = abs(a - b) / threshold
            if score > (top?.score ?? 0) { top = (key, a, b, score) }
        }

        guard let top, top.score >= 1 else { return nil }
        let guidance = top.key.guidance(for: type)
        return Insight(
            kind: .bestVsWorst,
            key: top.key,
            title: "Лучшие удары отличаются: \(top.key.title.lowercased())",
            detail: "На самых быстрых ударах серии — \(format(top.best, top.key)) \(top.key.unit), на самых слабых — \(format(top.worst, top.key)). Это твоя собственная разница, без чужих норм.",
            cue: guidance.cue,
            score: top.score
        )
    }

    private static func format(_ value: Double, _ key: MetricKey) -> String {
        key.format(value)
    }
}
