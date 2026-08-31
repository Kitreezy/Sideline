import CoreGraphics
import Foundation

/// Разбор проваленной съёмки — самая обидная потеря времени: отснял серию,
/// а ноги за кадром. Эти проверки гоняются вживую до начала записи.
public struct FramingCheck: Sendable, Identifiable {
    public enum Status: Sendable { case ok, warning, problem }

    public let id: String
    public let title: String
    public let detail: String
    public let status: Status
}

public struct FramingReport: Sendable {
    public let checks: [FramingCheck]
    public let cameraView: CameraView
    /// Ничто не мешает начать запись. Ракурс сюда не входит: снимать сзади
    /// можно осознанно, просто часть метрик тогда не посчитается.
    public let canRecord: Bool
}

public struct FramingAdvisor: Sendable {
    public struct Tuning: Sendable {
        /// Длина корпуса как доля высоты кадра. Ниже нижней границы Vision
        /// начинает терять суставы, выше верхней — игрок не влезает целиком.
        public var minTorsoShare: Double = 0.08
        public var comfortableTorsoShare: Double = 0.12
        public var maxTorsoShare: Double = 0.45
        /// Доля недавних кадров, в которых скелет должен быть виден.
        public var minVisibleShare: Double = 0.8

        public init() {}
    }

    public var tuning: Tuning

    public init(tuning: Tuning = Tuning()) {
        self.tuning = tuning
    }

    /// `recent` — последние пара секунд кадров: по одному кадру судить нельзя,
    /// игрок моргнул рукой перед камерой и вердикт запрыгал.
    public func evaluate(recent: [PoseFrame], frameSize: CGSize) -> FramingReport {
        guard !recent.isEmpty, frameSize.height > 0 else {
            return FramingReport(
                checks: [
                    FramingCheck(
                        id: "visible",
                        title: "Никого не вижу",
                        detail: "Наведи камеру на игрока.",
                        status: .problem
                    )
                ],
                cameraView: .unknown,
                canRecord: false
            )
        }

        var checks: [FramingCheck] = []

        // 1. Стабильно ли вообще виден человек.
        let visible = recent.filter { $0.joints.count >= 8 }
        let visibleShare = Double(visible.count) / Double(recent.count)
        checks.append(
            FramingCheck(
                id: "visible",
                title: visibleShare >= tuning.minVisibleShare ? "Игрок в кадре" : "Игрок теряется",
                detail: "Скелет виден в \(Int(visibleShare * 100))% кадров.",
                status: visibleShare >= tuning.minVisibleShare ? .ok : .problem
            )
        )

        guard !visible.isEmpty else {
            return FramingReport(checks: checks, cameraView: .unknown, canRecord: false)
        }

        // 2. Целиком ли он в кадре: без стоп не посчитать работу ног.
        let needed: [BodyJoint] = [.neck, .root, .leftAnkle, .rightAnkle]
        let complete = visible.filter { frame in
            needed.allSatisfy { frame.point($0, minConfidence: 0.4) != nil }
        }
        let completeShare = Double(complete.count) / Double(visible.count)
        checks.append(
            FramingCheck(
                id: "whole",
                title: completeShare >= 0.7 ? "Видно целиком" : "Ноги обрезаны",
                detail: completeShare >= 0.7
                    ? "Голова и стопы попадают в кадр."
                    : "Стопы видно только в \(Int(completeShare * 100))% кадров — наклони камеру или отойди.",
                status: completeShare >= 0.7 ? .ok : .problem
            )
        )

        // 3. Крупность. Мелкий игрок — это шумный скелет и мусорные метрики.
        let shares = visible.compactMap { frame -> Double? in
            guard let neck = frame.point(.neck, minConfidence: 0.5),
                  let root = frame.point(.root, minConfidence: 0.5) else { return nil }
            return Geometry.distance(neck, root) / Double(frameSize.height)
        }
        if let share = median(shares) {
            checks.append(sizeCheck(share: share))
        }

        // 4. Ракурс — не блокирует запись, но меняет набор метрик.
        let view = CameraViewDetector.detect(frames: visible)
        checks.append(
            FramingCheck(
                id: "view",
                title: "Ракурс: \(view.title.lowercased())",
                detail: view == .side
                    ? "То, что нужно: посчитаются все метрики."
                    : "Метрики, которым нужна глубина, посчитать не выйдет. Для полного набора поставь камеру сбоку.",
                status: view == .side ? .ok : .warning
            )
        )

        let blocking = checks.contains { $0.status == .problem }
        return FramingReport(checks: checks, cameraView: view, canRecord: !blocking)
    }

    private func sizeCheck(share: Double) -> FramingCheck {
        let percent = Int(share * 100)
        if share < tuning.minTorsoShare {
            return FramingCheck(
                id: "size",
                title: "Слишком мелко",
                detail: "Корпус занимает \(percent)% высоты кадра. Подойди ближе или приблизь — иначе скелет будет шумный.",
                status: .problem
            )
        }
        if share > tuning.maxTorsoShare {
            return FramingCheck(
                id: "size",
                title: "Слишком близко",
                detail: "Корпус занимает \(percent)% высоты кадра, игрок не поместится целиком в движении.",
                status: .problem
            )
        }
        if share < tuning.comfortableTorsoShare {
            return FramingCheck(
                id: "size",
                title: "Мелковато",
                detail: "Корпус занимает \(percent)% высоты кадра. Снимать можно, но ближе будет точнее.",
                status: .warning
            )
        }
        return FramingCheck(
            id: "size",
            title: "Крупность нормальная",
            detail: "Корпус занимает \(percent)% высоты кадра.",
            status: .ok
        )
    }

    private func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
