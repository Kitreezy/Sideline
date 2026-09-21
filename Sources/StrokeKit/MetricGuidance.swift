import Foundation

/// Что тренеры говорят про эту метрику. Не измеренная норма — ориентир
/// из практики, и в интерфейсе он так и подписывается. Но направление
/// («контакт впереди — хорошо») не спорно ни у одного тренера.
public struct MetricGuidance: Sendable {
    public enum Direction: Sendable {
        /// Больше — лучше, до разумного предела.
        case higherIsBetter
        /// Меньше — лучше, до разумного предела.
        case lowerIsBetter
        /// Самого по себе «правильного» значения нет, важен только разброс.
        case stableOnly
    }

    public let direction: Direction
    /// Ориентир из тренерской практики. Пусто — ориентира нет, есть
    /// только направление или только разброс.
    public let band: ClosedRange<Double>?
    /// Что нестабильность этой метрики делает с игрой.
    public let spreadConsequence: String
    /// Что происходит, когда среднее не дотягивает до ориентира.
    public let shortfallConsequence: String?
    /// Что с этим делать на корте.
    public let cue: String

    public init(
        direction: Direction,
        band: ClosedRange<Double>?,
        spreadConsequence: String,
        shortfallConsequence: String?,
        cue: String
    ) {
        self.direction = direction
        self.band = band
        self.spreadConsequence = spreadConsequence
        self.shortfallConsequence = shortfallConsequence
        self.cue = cue
    }
}

public extension MetricKey {
    /// Ориентиры зависят от типа удара: у форхенда и бэкхенда разная
    /// структура руки, а у подачи вообще другая геометрия.
    func guidance(for type: StrokeType) -> MetricGuidance {
        switch self {
        case .peakWristSpeed:
            return MetricGuidance(
                direction: .stableOnly,
                band: nil,
                spreadConsequence: "Разгон каждый раз разный: где-то бьёшь, где-то подставляешь. Мяч летит то глубоко, то в середину корта.",
                shortfallConsequence: nil,
                cue: "Одинаковый замах на каждый мяч — ракетка назад к моменту отскока, а не когда мяч уже рядом."
            )

        case .elbowAtContact:
            let band: ClosedRange<Double>? = switch type {
            case .forehand: 110...165   // и согнутая, и почти прямая рука — обе школы
            case .backhand: nil         // одноручный прямой, двуручный согнутый — не зная хвата, не судить
            case .serve: 150...180
            case .unknown: nil
            }
            return MetricGuidance(
                direction: .stableOnly,
                band: band,
                spreadConsequence: "Угол ракетки в момент удара каждый раз разный — отсюда нестабильная глубина и направление.",
                shortfallConsequence: nil,
                cue: "Выбери одну структуру руки на контакте — согнутая или прямая — и держи её на каждом ударе."
            )

        case .shoulderRotationRange:
            return MetricGuidance(
                direction: .higherIsBetter,
                band: type == .serve ? nil : 60...110,
                spreadConsequence: "То бьёшь корпусом, то одной рукой — скорость и глубина гуляют вместе с этим.",
                shortfallConsequence: "Мало разворота — удар идёт одной рукой. Теряешь скорость и грузишь плечо.",
                cue: "Замах начинай с разворота плеч, а не с отвода руки: небьющая рука показывает на мяч."
            )

        case .maxSeparation:
            return MetricGuidance(
                direction: .higherIsBetter,
                band: type == .serve ? nil : 20...50,
                spreadConsequence: "Энергия корпуса то копится, то нет — удар выходит рваным.",
                shortfallConsequence: "Плечи и таз идут вместе, энергия не копится — вся скорость только из руки.",
                cue: "Разверни плечи дальше, чем таз, и задержи на мгновение перед разгоном."
            )

        case .contactHeight:
            return MetricGuidance(
                direction: .stableOnly,
                band: type == .serve ? nil : 0.4...1.0,   // от пояса до плеча
                spreadConsequence: "Берёшь мяч на разной высоте — значит, ноги не подстраивают позицию, и рука каждый раз тянется по-новому.",
                shortfallConsequence: nil,
                cue: "Подстраивай ногами позицию под мяч, а не руку под высоту. Цель — контакт на уровне пояса-груди."
            )

        case .contactDepth:
            return MetricGuidance(
                direction: .higherIsBetter,
                band: 0.3...0.7,
                spreadConsequence: "То встречаешь мяч перед собой, то опаздываешь — направление гуляет, часть мячей в сетку.",
                shortfallConsequence: "Контакт на уровне бедра или позади — опаздываешь. Мяч в сетку или аут, вес тела в удар не идёт.",
                cue: "Встречай мяч раньше: разгон начинай, пока мяч ещё летит к тебе. Цель — контакт перед передней ногой."
            )

        case .minKneeAngle:
            return MetricGuidance(
                direction: .lowerIsBetter,
                band: 110...150,
                spreadConsequence: "То приседаешь, то бьёшь на прямых ногах — удар то с опорой, то без.",
                shortfallConsequence: "Прямые ноги — удар без опоры, одной рукой. Ноги в ударе не участвуют.",
                cue: "Присядь до замаха, а не во время. Из приседа поднимайся в удар."
            )

        case .backswingDuration:
            return MetricGuidance(
                direction: .stableOnly,
                band: nil,
                spreadConsequence: "Тайминг замаха гуляет: на одних мячах торопишься, на других опаздываешь.",
                shortfallConsequence: nil,
                cue: "Ранняя подготовка: ракетка назад к моменту, когда мяч отскочил."
            )

        case .forwardSwingDuration:
            return MetricGuidance(
                direction: .stableOnly,
                band: nil,
                spreadConsequence: "Разгон то затянутый, то рваный — контакт получается в разной точке.",
                shortfallConsequence: nil,
                cue: "Один ритм на все мячи: замах — пауза — разгон. Считай про себя."
            )
        }
    }
}
