import CoreGraphics
import XCTest
@testable import StrokeKit

final class GeometryTests: XCTestCase {
    func testRightAngle() {
        let angle = Geometry.angle(
            CGPoint(x: 0, y: 10), vertex: CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)
        )
        XCTAssertEqual(angle, 90, accuracy: 0.001)
    }

    func testStraightArmIs180() {
        let angle = Geometry.angle(
            CGPoint(x: -10, y: 0), vertex: .zero, CGPoint(x: 10, y: 0)
        )
        XCTAssertEqual(angle, 180, accuracy: 0.001)
    }

    func testLineAngleIsUndirected() {
        // Линия плеч не имеет направления: развернув точки, получаем тот же наклон.
        let forward = Geometry.lineAngle(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 10, y: 10))
        let backward = Geometry.lineAngle(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 0, y: 0))
        XCTAssertEqual(forward, backward, accuracy: 0.001)
        XCTAssertEqual(forward, 45, accuracy: 0.001)
    }

    func testLineAngleStaysInRange() {
        let angle = Geometry.lineAngle(from: CGPoint(x: 10, y: 0), to: CGPoint(x: 0, y: 1))
        XCTAssertLessThanOrEqual(angle, 90)
        XCTAssertGreaterThanOrEqual(angle, -90)
    }
}
