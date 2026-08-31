import CoreGraphics
import Foundation

public enum Geometry {
    /// Угол в вершине `vertex`, образованный лучами на `a` и `b`. В градусах, 0...180.
    public static func angle(_ a: CGPoint, vertex: CGPoint, _ b: CGPoint) -> Double {
        let v1 = CGPoint(x: a.x - vertex.x, y: a.y - vertex.y)
        let v2 = CGPoint(x: b.x - vertex.x, y: b.y - vertex.y)
        let dot = Double(v1.x * v2.x + v1.y * v2.y)
        let mag = Double(hypot(v1.x, v1.y) * hypot(v2.x, v2.y))
        guard mag > 1e-9 else { return .nan }
        return acos(min(1, max(-1, dot / mag))) * 180 / .pi
    }

    /// Наклон отрезка `from`→`to` относительно горизонтали, в градусах −90...90.
    /// Для линии плеч при съёмке сбоку это прокси разворота корпуса:
    /// 0° — плечи развёрнуты к камере, ±90° — боком.
    public static func lineAngle(from: CGPoint, to: CGPoint) -> Double {
        let dx = Double(to.x - from.x)
        let dy = Double(to.y - from.y)
        guard abs(dx) > 1e-9 || abs(dy) > 1e-9 else { return .nan }
        var deg = atan2(dy, dx) * 180 / .pi
        // Линия плеч не имеет направления: 170° и −10° это одно и то же.
        if deg > 90 { deg -= 180 }
        if deg < -90 { deg += 180 }
        return deg
    }

    public static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        Double(hypot(b.x - a.x, b.y - a.y))
    }

    public static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
}
