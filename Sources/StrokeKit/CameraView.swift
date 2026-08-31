import CoreGraphics
import Foundation

/// Откуда снято. От этого зависит, какие метрики вообще имеют смысл:
/// в 2D не видно глубину, поэтому «контакт впереди корпуса» при съёмке
/// сзади меряет то, чего в кадре нет.
public enum CameraView: String, Sendable, Codable {
    case side       // сбоку — то, подо что приложение и рассчитано
    case behind     // из-за спины игрока
    case facing     // игрок лицом к камере
    case mixed      // ракурс меняется: смонтированный ролик
    case unknown    // не хватило кадров, чтобы решить

    public var title: String {
        switch self {
        case .side: return "Сбоку"
        case .behind: return "Из-за спины"
        case .facing: return "Спереди"
        case .mixed: return "Ракурс меняется"
        case .unknown: return "Ракурс не определён"
        }
    }
}

public enum CameraViewDetector {
    /// Ширина плеч относительно длины корпуса. Анфас плечи видно целиком,
    /// в профиль они складываются в точку — это и есть признак.
    static let frontalShoulderRatio = 0.5

    /// Доля кадров, которую должен набрать ракурс, чтобы считаться основным.
    static let majorityShare = 0.6

    public static func detect(frames: [PoseFrame]) -> CameraView {
        var votes: [CameraView: Int] = [:]
        var counted = 0

        for frame in frames {
            guard let neck = frame.point(.neck, minConfidence: 0.5),
                  let root = frame.point(.root, minConfidence: 0.5),
                  let left = frame.point(.leftShoulder, minConfidence: 0.5),
                  let right = frame.point(.rightShoulder, minConfidence: 0.5)
            else { continue }

            let torso = Geometry.distance(neck, root)
            guard torso > 1 else { continue }
            let ratio = Geometry.distance(left, right) / torso

            counted += 1
            if ratio < frontalShoulderRatio {
                votes[.side, default: 0] += 1
            } else if left.x < right.x {
                // Анатомически левое плечо в левой части кадра — игрок отвернулся.
                votes[.behind, default: 0] += 1
            } else {
                votes[.facing, default: 0] += 1
            }
        }

        guard counted >= 20 else { return .unknown }
        guard let (view, count) = votes.max(by: { $0.value < $1.value }) else { return .unknown }
        return Double(count) / Double(counted) >= majorityShare ? view : .mixed
    }
}

public extension MetricKey {
    /// Работает ли метрика в этом ракурсе. Лучше не показать цифру,
    /// чем показать ту, которая меряет не то, что написано.
    func isReliable(in view: CameraView) -> Bool {
        switch self {
        case .contactDepth:
            // «Впереди корпуса» — это глубина. Она видна только сбоку.
            return view == .side
        case .shoulderRotationRange, .maxSeparation:
            // Разворот вокруг вертикальной оси в анфас и со спины меняет
            // ширину плеч, а не наклон их линии — то есть наша метрика его не ловит.
            return view == .side
        default:
            return true
        }
    }

    /// Почему метрика выключена — это должно быть видно в интерфейсе.
    func unreliabilityReason(in view: CameraView) -> String? {
        guard !isReliable(in: view) else { return nil }
        switch self {
        case .contactDepth:
            return "Меряет глубину, а её в кадре нет: нужна камера сбоку."
        case .shoulderRotationRange, .maxSeparation:
            return "Разворот корпуса в этом ракурсе не виден как наклон линии плеч. Нужна камера сбоку."
        default:
            return nil
        }
    }
}
