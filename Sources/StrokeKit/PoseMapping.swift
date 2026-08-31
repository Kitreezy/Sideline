import CoreGraphics
import Foundation
import Vision

/// Перевод наблюдения Vision в наши суставы. Вынесено отдельно, чтобы живая
/// камера и разбор файла шли одним и тем же путём: если тут появится ошибка,
/// она проявится в обоих режимах сразу, а не в одном тихо разойдётся с другим.
public enum PoseMapping {
    public static func joints(
        from observation: HumanBodyPoseObservation,
        displaySize: CGSize
    ) -> [BodyJoint: JointSample] {
        var joints: [BodyJoint: JointSample] = [:]
        for (visionName, joint) in observation.allJoints() {
            guard let mapped = PoseExtractor.jointMap[visionName] else { continue }
            let point = joint.location.toImageCoordinates(displaySize, origin: .upperLeft)
            joints[mapped] = JointSample(point: point, confidence: joint.confidence)
        }
        return joints
    }
}
