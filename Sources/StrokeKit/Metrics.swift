import Foundation

/// Что именно мы измеряем в каждом ударе.
public enum MetricKey: String, CaseIterable, Sendable, Codable {
    case peakWristSpeed
    case elbowAtContact
    case shoulderRotationRange
    case maxSeparation
    case contactHeight
    case contactDepth
    case minKneeAngle
    case backswingDuration
    case forwardSwingDuration

    public var title: String {
        switch self {
        case .peakWristSpeed: return "Пиковая скорость кисти"
        case .elbowAtContact: return "Угол локтя на контакте"
        case .shoulderRotationRange: return "Амплитуда разворота плеч"
        case .maxSeparation: return "Разделение плечи/таз"
        case .contactHeight: return "Высота контакта"
        case .contactDepth: return "Контакт впереди корпуса"
        case .minKneeAngle: return "Минимальный угол колена"
        case .backswingDuration: return "Длительность замаха"
        case .forwardSwingDuration: return "Длительность разгона"
        }
    }

    public var unit: String {
        switch self {
        case .peakWristSpeed: return "корп/с"
        case .elbowAtContact, .shoulderRotationRange, .maxSeparation, .minKneeAngle: return "°"
        case .contactHeight, .contactDepth: return "корп"
        case .backswingDuration, .forwardSwingDuration: return "с"
        }
    }

    /// Что эта цифра значит на корте.
    public var hint: String {
        switch self {
        case .peakWristSpeed:
            return "Скорость кисти в момент контакта, в длинах корпуса за секунду. Нормирована на рост, так что не зависит от того, как далеко стоит камера."
        case .elbowAtContact:
            return "180° — рука выпрямлена в струну, 90° — согнута под прямым углом. Само по себе «правильного» значения нет, важен разброс: стабильный локоть = стабильная точка удара."
        case .shoulderRotationRange:
            return "На сколько градусов линия плеч успевает провернуться за удар. Мало градусов — бьёшь одной рукой, без корпуса."
        case .maxSeparation:
            return "Насколько плечи опережают таз (X-factor). Это то, что копит энергию до разгона."
        case .contactHeight:
            return "Высота кисти над линией таза в момент контакта, в длинах корпуса."
        case .contactDepth:
            return "Насколько кисть впереди бедра на контакте. Больше нуля — встречаешь мяч перед собой, около нуля или меньше — опаздываешь."
        case .minKneeAngle:
            return "Самый согнутый угол колена за удар. 180° — стоишь на прямых ногах."
        case .backswingDuration:
            return "От начала движения до точки, где замах остановился и начался разгон."
        case .forwardSwingDuration:
            return "От конца замаха до контакта. Разброс здесь — это разброс тайминга."
        }
    }

    /// Разброс какого размера уже стоит показывать как проблему.
    /// Это не «норма техники», а порог заметности: ниже него шум трекинга.
    public var noticeableSpread: Double {
        switch self {
        case .peakWristSpeed: return 0.8
        case .elbowAtContact: return 12
        case .shoulderRotationRange: return 15
        case .maxSeparation: return 12
        case .contactHeight: return 0.12
        case .contactDepth: return 0.12
        case .minKneeAngle: return 12
        case .backswingDuration: return 0.08
        case .forwardSwingDuration: return 0.05
        }
    }

    public var fractionDigits: Int {
        switch self {
        case .backswingDuration, .forwardSwingDuration: return 2
        case .contactHeight, .contactDepth, .peakWristSpeed: return 2
        default: return 0
        }
    }
}

/// Сводка по одной метрике на всей серии ударов.
public struct MetricSummary: Sendable, Identifiable {
    public let key: MetricKey
    public let values: [Double]
    public let mean: Double
    public let standardDeviation: Double
    /// Сколько ударов дали значение. Замах измеряется не у каждого удара,
    /// и разброс по одному значению — ноль, а не стабильность.
    public let finiteCount: Int

    public var id: MetricKey { key }

    /// Достаточно ли значений, чтобы разброс что-то значил.
    public func isWellSampled(of total: Int) -> Bool {
        finiteCount >= 3 && finiteCount * 2 >= total
    }

    /// Разброс относительно порога заметности. >1 — стоит обратить внимание.
    public var instability: Double {
        guard key.noticeableSpread > 0 else { return 0 }
        return standardDeviation / key.noticeableSpread
    }

    /// Разброс значений. NaN здесь обычное дело: длительность замаха не
    /// считается, когда замаха не видно. Сравнения с NaN всегда ложны,
    /// поэтому min() и max() по такому массиву могут вернуть границы
    /// в обратном порядке — и построение диапазона роняет процесс.
    public var range: ClosedRange<Double>? {
        let finite = values.filter { $0.isFinite }
        guard let lo = finite.min(), let hi = finite.max(), lo <= hi else { return nil }
        return lo...hi
    }

    public init(key: MetricKey, values: [Double]) {
        self.key = key
        let clean = values.filter { $0.isFinite }
        self.values = values
        self.finiteCount = clean.count
        guard !clean.isEmpty else {
            self.mean = .nan
            self.standardDeviation = .nan
            return
        }
        let mean = clean.reduce(0, +) / Double(clean.count)
        self.mean = mean
        if clean.count < 2 {
            self.standardDeviation = 0
        } else {
            let variance = clean.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(clean.count - 1)
            self.standardDeviation = variance.squareRoot()
        }
    }
}
