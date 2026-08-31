import CoreGraphics
import Foundation

/// Суставы, которые нас интересуют для разбора удара.
/// Vision отдаёт больше точек (глаза, уши), но для техники они бесполезны.
public enum BodyJoint: String, CaseIterable, Sendable, Codable {
    case neck
    case root            // центр таза, Vision зовёт его .root
    case leftShoulder, rightShoulder
    case leftElbow, rightElbow
    case leftWrist, rightWrist
    case leftHip, rightHip
    case leftKnee, rightKnee
    case leftAnkle, rightAnkle
}

/// Положение одного сустава в одном кадре.
/// `point` — в пикселях видео, начало координат в левом верхнем углу.
public struct JointSample: Sendable, Codable {
    public let point: CGPoint
    public let confidence: Float

    public init(point: CGPoint, confidence: Float) {
        self.point = point
        self.confidence = confidence
    }
}

/// Скелет в один момент времени.
public struct PoseFrame: Sendable, Codable {
    public let time: TimeInterval
    public let joints: [BodyJoint: JointSample]

    public init(time: TimeInterval, joints: [BodyJoint: JointSample]) {
        self.time = time
        self.joints = joints
    }

    /// Точка сустава, если Vision в ней достаточно уверен.
    public func point(_ joint: BodyJoint, minConfidence: Float = 0.3) -> CGPoint? {
        guard let sample = joints[joint], sample.confidence >= minConfidence else { return nil }
        return sample.point
    }
}

public enum Handedness: String, Sendable, Codable, CaseIterable {
    case right
    case left

    public var title: String { self == .right ? "Правая" : "Левая" }

    public var wrist: BodyJoint { self == .right ? .rightWrist : .leftWrist }
    public var elbow: BodyJoint { self == .right ? .rightElbow : .leftElbow }
    public var shoulder: BodyJoint { self == .right ? .rightShoulder : .leftShoulder }
    public var hip: BodyJoint { self == .right ? .rightHip : .leftHip }
    public var knee: BodyJoint { self == .right ? .rightKnee : .leftKnee }
}

/// Пары суставов для отрисовки скелета поверх видео.
public let skeletonBones: [(BodyJoint, BodyJoint)] = [
    (.neck, .leftShoulder), (.neck, .rightShoulder),
    (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
    (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
    (.neck, .root),
    (.root, .leftHip), (.root, .rightHip),
    (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
    (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
]
