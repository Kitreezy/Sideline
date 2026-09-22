import CoreGraphics
import Foundation
import StrokeKit

/// Где в кадре игрок в момент удара — по скелету. Нужно, чтобы кадрировать
/// миниатюры и приближать видео: на съёмке с задней линии игрок занимает
/// 4% высоты кадра, и без приближения на него не посмотреть.
enum PlayerRegion {
    /// Прямоугольник в пикселях видео. Пусто — скелета в этот момент нет.
    static func rect(for stroke: Stroke, in analysis: SessionAnalysis) -> CGRect? {
        let frames = analysis.track.frames
        guard frames.indices.contains(stroke.phases.contact) else { return nil }
        let frame = frames[stroke.phases.contact]
        guard let neck = frame.point(.neck), let root = frame.point(.root) else { return nil }

        let torso = analysis.signals.scale(at: stroke.phases.contact)
        let center = CGPoint(x: (neck.x + root.x) / 2, y: (neck.y + root.y) / 2)
        // Рука с ракеткой уходит на полтора корпуса в сторону, ноги — на два вниз.
        let width = torso * 4
        let height = torso * 5
        let raw = CGRect(x: center.x - width / 2, y: center.y - height * 0.45, width: width, height: height)
        return raw.intersection(CGRect(origin: .zero, size: analysis.track.displaySize))
    }

    /// Стоит ли приближать по умолчанию: корпус меньше 12% высоты кадра.
    static func isPlayerSmall(in analysis: SessionAnalysis) -> Bool {
        analysis.track.displaySize.height > 0
            && analysis.signals.torsoScale / Double(analysis.track.displaySize.height) < 0.12
    }
}
