import CoreGraphics
import Foundation

/// Первый проход двухпроходного разбора: по прореженным кадрам находит,
/// где в видео вообще что-то происходит.
///
/// Ударов в записи меньше десятой части времени, а Vision стоит одинаково
/// на каждом кадре. Разбирать всё подряд — это минуты ожидания на записи
/// в слоу-мо; разбирать только окна вокруг всплесков — секунды.
public enum StrokeWindowFinder {
    public struct Tuning: Sendable {
        /// Запас вокруг всплеска: замах и проводка должны попасть в окно
        /// целиком, иначе второй проход не увидит фаз удара.
        public var padding: TimeInterval = 0.8
        /// Порог здесь заведомо ниже боевого. Пропустить удар нельзя —
        /// его потом уже никак не вернуть, а лишнее окно стоит лишь времени.
        public var speedFloor: Double = 1.2
        public var medianFactor: Double = 2.0
        public var minSeparation: TimeInterval = 0.4

        public init() {}
    }

    /// Окна времени, которые стоит разобрать на полной частоте.
    /// Рука не задаётся намеренно: берётся более быстрая из двух, поэтому
    /// неверно выбранная бьющая рука не уронит весь разбор.
    public static func candidateWindows(
        frames: [PoseFrame],
        duration: TimeInterval,
        tuning: Tuning = Tuning()
    ) -> [ClosedRange<TimeInterval>] {
        guard frames.count > 4 else { return [] }

        let scale = StrokeAnalyzer.torsoScale(frames: frames, fallbackHeight: 1)
        guard scale > 0 else { return [] }

        let times = frames.map(\.time)
        let speed = fasterWristSpeed(frames: frames, times: times, scale: scale)

        let threshold = StrokeAnalyzer.strokeThreshold(
            speed, floor: tuning.speedFloor, medianFactor: tuning.medianFactor
        )
        let peaks = SignalProcessing.findPeaks(
            speed, minHeight: threshold, minSeparation: tuning.minSeparation
        )
        guard !peaks.isEmpty else { return [] }

        let windows = peaks.map { index -> ClosedRange<TimeInterval> in
            let time = times[index]
            let start = max(0, time - tuning.padding)
            let end = min(duration, time + tuning.padding)
            return start...max(start, end)
        }
        return merge(windows)
    }

    /// Фон движения по всей записи — то, относительно чего потом ставится
    /// порог удара. Считается здесь, потому что первый проход единственный,
    /// кто видит запись целиком.
    public static func backgroundMotion(frames: [PoseFrame]) -> BackgroundMotion? {
        guard frames.count > 4 else { return nil }
        let scale = StrokeAnalyzer.torsoScale(frames: frames, fallbackHeight: 1)
        guard scale > 0 else { return nil }

        let times = frames.map(\.time)
        let speeds = wristSpeeds(frames: frames, times: times, scale: scale)

        func median(_ values: [Double]) -> Double {
            let finite = values.filter { $0.isFinite }.sorted()
            guard !finite.isEmpty else { return 0 }
            return finite[finite.count / 2]
        }
        return BackgroundMotion(
            leftWristSpeedMedian: median(speeds.left),
            rightWristSpeedMedian: median(speeds.right)
        )
    }

    static func wristSpeeds(
        frames: [PoseFrame],
        times: [TimeInterval],
        scale: Double
    ) -> (left: [Double], right: [Double]) {
        func speed(of joint: BodyJoint) -> [Double] {
            let x = SignalProcessing.smooth(SignalProcessing.interpolateGaps(
                Signal(times: times, values: frames.map { $0.point(joint).map { Double($0.x) } ?? .nan })
            ))
            let y = SignalProcessing.smooth(SignalProcessing.interpolateGaps(
                Signal(times: times, values: frames.map { $0.point(joint).map { Double($0.y) } ?? .nan })
            ))
            let vx = SignalProcessing.derivative(x).values
            let vy = SignalProcessing.derivative(y).values
            return (0..<times.count).map { index in
                let a = vx[index], b = vy[index]
                guard a.isFinite, b.isFinite else { return Double.nan }
                return (a * a + b * b).squareRoot() / scale
            }
        }

        return (speed(of: .leftWrist), speed(of: .rightWrist))
    }

    /// Скорость более быстрой кисти в длинах корпуса за секунду.
    static func fasterWristSpeed(
        frames: [PoseFrame],
        times: [TimeInterval],
        scale: Double
    ) -> Signal {
        let (left, right) = wristSpeeds(frames: frames, times: times, scale: scale)
        let combined = (0..<times.count).map { index -> Double in
            let a = left[index], b = right[index]
            if a.isNaN { return b }
            if b.isNaN { return a }
            return Swift.max(a, b)
        }
        return SignalProcessing.smooth(Signal(times: times, values: combined), sigmaSeconds: 0.03)
    }

    static func merge(_ windows: [ClosedRange<TimeInterval>]) -> [ClosedRange<TimeInterval>] {
        guard !windows.isEmpty else { return [] }
        let sorted = windows.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<TimeInterval>] = [sorted[0]]

        for window in sorted.dropFirst() {
            let last = merged[merged.count - 1]
            if window.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...Swift.max(last.upperBound, window.upperBound)
            } else {
                merged.append(window)
            }
        }
        return merged
    }
}
