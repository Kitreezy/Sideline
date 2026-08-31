import CoreGraphics
import Foundation

public enum StrokeType: String, Sendable, Codable, CaseIterable {
    case forehand
    case backhand
    case serve
    case unknown

    public var title: String {
        switch self {
        case .forehand: return "Форхенд"
        case .backhand: return "Бэкхенд"
        case .serve: return "Подача и сверху"
        case .unknown: return "Не разобрал"
        }
    }
}

public enum StrokeClassifier {
    /// Насколько уверенно плечо должно опережать второе, чтобы это считалось
    /// разворотом, а не шумом трекинга. В длинах корпуса.
    /// Откалибровано по записи тренировки: настоящие форхенды дают от -0.07
    /// до -0.89, бэкхенды от +0.45 до +0.83, а неразличимые случаи висят
    /// около нуля. Порог 0.12 отсекал половину настоящих форхендов.
    static let leadThreshold = 0.05

    /// На сколько длин корпуса кисть должна быть выше шеи, чтобы это была
    /// подача или смэш, а не высокий форхенд.
    static let overheadThreshold = 0.5

    /// Форхенд и бэкхенд почти не отличаются траекторией кисти: в обоих случаях
    /// ракетка уходит назад и идёт вперёд. Отличается разворот корпуса —
    /// на форхенде вперёд смотрит небьющее плечо, на бэкхенде бьющее.
    /// Это работает и при съёмке сбоку, где линия плеч как раз развёрнута
    /// вдоль оси удара и потому хорошо видна.
    public static func classify(
        phases: StrokePhases,
        frames: [PoseFrame],
        signals: AnalyzedSignals,
        handedness: Handedness
    ) -> StrokeType {
        guard frames.indices.contains(phases.contact) else { return .unknown }

        // Удар над головой: кисть не просто выше шеи, а выше с запасом.
        // Без запаса сюда попадает любой высокий форхенд и любая проводка,
        // на которой ракетка ушла над плечом.
        if let margin = overheadMargin(
            phases: phases, frames: frames, signals: signals, handedness: handedness
        ), margin > overheadThreshold {
            return .serve
        }

        guard let lead = shoulderLead(
            phases: phases, frames: frames, signals: signals, handedness: handedness
        ) else { return .unknown }

        if lead < -leadThreshold { return .forehand }
        if lead > leadThreshold { return .backhand }
        return .unknown
    }

    /// Насколько бьющее плечо опережает небьющее вдоль оси удара, в длинах
    /// корпуса. Отрицательное значение — вперёд смотрит небьющее плечо (форхенд),
    /// положительное — бьющее (бэкхенд).
    public static func shoulderLead(
        phases: StrokePhases,
        frames: [PoseFrame],
        signals: AnalyzedSignals,
        handedness: Handedness
    ) -> Double? {
        guard let forward = forwardDirection(signals: signals, at: phases.contact) else {
            return nil
        }

        // Усредняем по разгону: один кадр слишком шумный.
        var total = 0.0
        var counted = 0
        for index in phases.transition...phases.contact {
            guard frames.indices.contains(index) else { continue }
            let frame = frames[index]
            guard let dominant = frame.point(handedness.shoulder),
                  let other = frame.point(handedness == .right ? .leftShoulder : .rightShoulder)
            else { continue }

            let axis = CGPoint(x: dominant.x - other.x, y: dominant.y - other.y)
            let projection = Double(axis.x) * forward.dx + Double(axis.y) * forward.dy
            total += projection / signals.torsoScale
            counted += 1
        }

        guard counted > 0 else { return nil }
        return total / Double(counted)
    }

    /// Насколько кисть выше шеи в момент контакта, в длинах корпуса.
    public static func overheadMargin(
        phases: StrokePhases,
        frames: [PoseFrame],
        signals: AnalyzedSignals,
        handedness: Handedness
    ) -> Double? {
        guard frames.indices.contains(phases.contact) else { return nil }
        let frame = frames[phases.contact]
        guard let wrist = frame.point(handedness.wrist),
              let neck = frame.point(.neck),
              signals.torsoScale > 0
        else { return nil }
        return Double(neck.y - wrist.y) / signals.torsoScale
    }

    /// Куда летит ракетка в момент контакта — это и есть «вперёд» для игрока.
    static func forwardDirection(
        signals: AnalyzedSignals,
        at index: Int
    ) -> (dx: Double, dy: Double)? {
        let vx = SignalProcessing.derivative(signals.wristX).values
        let vy = SignalProcessing.derivative(signals.wristY).values
        guard vx.indices.contains(index) else { return nil }
        let x = vx[index], y = vy[index]
        guard x.isFinite, y.isFinite else { return nil }
        let magnitude = (x * x + y * y).squareRoot()
        guard magnitude > 1e-6 else { return nil }
        return (x / magnitude, y / magnitude)
    }
}
