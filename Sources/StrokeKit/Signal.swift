import Foundation

/// Временной ряд с равномерным (по факту — почти равномерным) шагом кадров.
/// `values` может содержать .nan там, где Vision не увидел сустав.
public struct Signal: Sendable {
    public var times: [TimeInterval]
    public var values: [Double]

    public init(times: [TimeInterval], values: [Double]) {
        precondition(times.count == values.count, "times и values должны быть одной длины")
        self.times = times
        self.values = values
    }

    public var count: Int { values.count }
    public var isEmpty: Bool { values.isEmpty }
}

public enum SignalProcessing {
    /// Линейно заполняет короткие провалы (.nan). Длинные дыры оставляет как есть —
    /// лучше показать «не знаю», чем выдумать положение руки.
    public static func interpolateGaps(_ signal: Signal, maxGapSeconds: TimeInterval = 0.2) -> Signal {
        var values = signal.values
        let times = signal.times
        var index = 0

        while index < values.count {
            guard values[index].isNaN else { index += 1; continue }

            let gapStart = index
            var gapEnd = index
            while gapEnd < values.count, values[gapEnd].isNaN { gapEnd += 1 }

            // Края ряда экстраполировать не будем.
            if gapStart > 0, gapEnd < values.count {
                let before = gapStart - 1
                let after = gapEnd
                if times[after] - times[before] <= maxGapSeconds {
                    let span = times[after] - times[before]
                    for i in gapStart..<gapEnd {
                        let t = (times[i] - times[before]) / span
                        values[i] = values[before] + (values[after] - values[before]) * t
                    }
                }
            }
            index = gapEnd
        }
        return Signal(times: times, values: values)
    }

    /// Сглаживание гауссовым ядром. `sigmaSeconds` подбирается под то,
    /// что мы считаем шумом трекинга, а не движением.
    public static func smooth(_ signal: Signal, sigmaSeconds: TimeInterval = 0.033) -> Signal {
        guard signal.count > 2 else { return signal }
        let dt = medianStep(signal.times)
        guard dt > 0 else { return signal }

        let sigmaFrames = max(0.5, sigmaSeconds / dt)
        let radius = max(1, Int((sigmaFrames * 3).rounded()))
        var kernel = [Double]()
        for offset in -radius...radius {
            let x = Double(offset) / sigmaFrames
            kernel.append(exp(-0.5 * x * x))
        }

        var output = [Double](repeating: .nan, count: signal.count)
        for i in 0..<signal.count {
            var sum = 0.0
            var weight = 0.0
            for (k, offset) in (-radius...radius).enumerated() {
                let j = i + offset
                guard j >= 0, j < signal.count else { continue }
                let v = signal.values[j]
                guard !v.isNaN else { continue }
                sum += v * kernel[k]
                weight += kernel[k]
            }
            output[i] = weight > 0 ? sum / weight : .nan
        }
        return Signal(times: signal.times, values: output)
    }

    /// Производная центральной разностью. На краях — односторонняя.
    public static func derivative(_ signal: Signal) -> Signal {
        guard signal.count > 1 else {
            return Signal(times: signal.times, values: [Double](repeating: .nan, count: signal.count))
        }
        var output = [Double](repeating: .nan, count: signal.count)
        for i in 0..<signal.count {
            let lo = max(0, i - 1)
            let hi = min(signal.count - 1, i + 1)
            let dt = signal.times[hi] - signal.times[lo]
            guard dt > 0 else { continue }
            let a = signal.values[lo], b = signal.values[hi]
            guard !a.isNaN, !b.isNaN else { continue }
            output[i] = (b - a) / dt
        }
        return Signal(times: signal.times, values: output)
    }


    /// Разбивает ряд на куски по границам склейки. Граница `i` означает разрыв
    /// между кадрами i-1 и i: сглаживать и дифференцировать через него нельзя.
    public static func segments(count: Int, boundaries: Set<Int>) -> [Range<Int>] {
        guard count > 0 else { return [] }
        var result: [Range<Int>] = []
        var start = 0
        for index in 1..<count where boundaries.contains(index) {
            result.append(start..<index)
            start = index
        }
        result.append(start..<count)
        return result.filter { !$0.isEmpty }
    }

    /// Применяет обработку к каждому куску отдельно, чтобы разрыв не протёк
    /// через ядро сглаживания в соседний кусок.
    public static func perSegment(
        _ signal: Signal,
        boundaries: Set<Int>,
        _ transform: (Signal) -> Signal
    ) -> Signal {
        guard !boundaries.isEmpty else { return transform(signal) }
        var values = signal.values
        for range in segments(count: signal.count, boundaries: boundaries) {
            let piece = Signal(
                times: Array(signal.times[range]),
                values: Array(signal.values[range])
            )
            let processed = transform(piece)
            for (offset, index) in range.enumerated() {
                values[index] = processed.values[offset]
            }
        }
        return Signal(times: signal.times, values: values)
    }

    public static func medianStep(_ times: [TimeInterval]) -> TimeInterval {
        guard times.count > 1 else { return 0 }
        var steps = [TimeInterval]()
        for i in 1..<times.count { steps.append(times[i] - times[i - 1]) }
        steps.sort()
        return steps[steps.count / 2]
    }

    /// Локальные максимумы выше порога, разнесённые минимум на `minSeparation`.
    /// Из близких пиков остаётся самый высокий.
    public static func findPeaks(
        _ signal: Signal,
        minHeight: Double,
        minSeparation: TimeInterval
    ) -> [Int] {
        var candidates = [Int]()
        for i in 1..<max(1, signal.count - 1) {
            let v = signal.values[i]
            guard !v.isNaN, v >= minHeight else { continue }
            let prev = signal.values[i - 1]
            let next = signal.values[i + 1]
            guard !prev.isNaN, !next.isNaN else { continue }
            if v >= prev, v >= next { candidates.append(i) }
        }

        // Жадно: берём самые высокие, глушим соседей.
        let ordered = candidates.sorted { signal.values[$0] > signal.values[$1] }
        var accepted = [Int]()
        for candidate in ordered {
            let tooClose = accepted.contains { abs(signal.times[$0] - signal.times[candidate]) < minSeparation }
            if !tooClose { accepted.append(candidate) }
        }
        return accepted.sorted()
    }
}
