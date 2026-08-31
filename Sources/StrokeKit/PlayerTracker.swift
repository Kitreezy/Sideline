import CoreGraphics
import Foundation

/// Один распознанный человек в одном кадре, без привязки к Vision —
/// чтобы выбор игрока можно было проверять тестами.
public struct PoseCandidate: Sendable {
    public let joints: [BodyJoint: JointSample]

    public init(joints: [BodyJoint: JointSample]) {
        self.joints = joints
    }

    private func point(_ joint: BodyJoint) -> CGPoint? {
        guard let sample = joints[joint], sample.confidence >= 0.3 else { return nil }
        return sample.point
    }

    /// Центр человека. Таз надёжнее шеи: он меньше дёргается при замахе.
    public var center: CGPoint? {
        if let root = point(.root) { return root }
        if let left = point(.leftHip), let right = point(.rightHip) {
            return Geometry.midpoint(left, right)
        }
        return point(.neck)
    }

    /// Размер человека в пикселях — он же мера расстояния до камеры.
    public var torso: Double? {
        if let neck = point(.neck), let root = point(.root) {
            let length = Geometry.distance(neck, root)
            if length > 1 { return length }
        }
        if let left = point(.leftShoulder), let right = point(.rightShoulder) {
            let width = Geometry.distance(left, right) * 1.8
            if width > 1 { return width }
        }
        return nil
    }
}

/// Ведёт одного игрока через кадры.
///
/// Раньше в каждом кадре независимо брался самый крупный человек в кадре.
/// Из-за этого Vision изредка перескакивал на соперника за сеткой, и кисть
/// «телепортировалась» — а телепорт по скорости бьёт любой настоящий удар.
/// Теперь выбирается тот, кто ближе всего к игроку из предыдущего кадра.
public struct PlayerTracker: Sendable {
    public struct Tuning: Sendable {
        /// Сколько длин корпуса в секунду игрок может пробежать. Всё, что быстрее,
        /// стоит дорого и проиграет более близкому кандидату.
        public var maxSpeed: Double = 8
        /// Нижняя граница «бюджета» перемещения, чтобы на быстрых кадрах
        /// он не схлопывался в ноль.
        public var minBudget: Double = 0.15
        /// Насколько наказывать за резкую смену размера человека.
        public var sizeWeight: Double = 1.5
        /// Если игрока не было дольше этого времени, привязка сбрасывается.
        public var resetAfter: TimeInterval = 0.3

        public init() {}
    }

    public var tuning: Tuning

    private var lastCenter: CGPoint?
    private var lastTorso: Double?
    private var lastTime: TimeInterval?

    public init(tuning: Tuning = Tuning()) {
        self.tuning = tuning
    }

    /// Индекс кандидата, который считается нашим игроком.
    public mutating func select(from candidates: [PoseCandidate], at time: TimeInterval) -> Int? {
        guard !candidates.isEmpty else { return nil }

        let elapsed = lastTime.map { time - $0 } ?? .infinity
        defer { lastTime = time }

        guard let previousCenter = lastCenter,
              let previousTorso = lastTorso,
              elapsed <= tuning.resetAfter, elapsed >= 0
        else {
            return remember(largest(in: candidates), in: candidates)
        }

        let budget = max(tuning.minBudget, tuning.maxSpeed * elapsed)
        var best: (index: Int, cost: Double)?

        for (index, candidate) in candidates.enumerated() {
            guard let center = candidate.center, let torso = candidate.torso else { continue }
            let moved = Geometry.distance(center, previousCenter) / previousTorso
            let resized = abs(log(torso / previousTorso))
            let cost = moved / budget + tuning.sizeWeight * resized
            if best == nil || cost < best!.cost {
                best = (index, cost)
            }
        }

        return remember(best?.index ?? largest(in: candidates), in: candidates)
    }

    /// Первый кадр и кадры после потери: опереться не на что, берём самого
    /// крупного — на любительской съёмке игрок ближе к камере, чем прохожие.
    private func largest(in candidates: [PoseCandidate]) -> Int? {
        var best: (index: Int, torso: Double)?
        for (index, candidate) in candidates.enumerated() {
            guard let torso = candidate.torso else { continue }
            if best == nil || torso > best!.torso { best = (index, torso) }
        }
        return best?.index ?? (candidates.isEmpty ? nil : 0)
    }

    private mutating func remember(_ index: Int?, in candidates: [PoseCandidate]) -> Int? {
        guard let index, candidates.indices.contains(index) else {
            lastCenter = nil
            lastTorso = nil
            return nil
        }
        lastCenter = candidates[index].center
        lastTorso = candidates[index].torso
        return index
    }
}
