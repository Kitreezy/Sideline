import Foundation
import StrokeKit

enum Format {
    static func value(_ value: Double, key: MetricKey) -> String {
        key.format(value)
    }

    static func valueWithUnit(_ value: Double, key: MetricKey) -> String {
        key.formatWithUnit(value)
    }

    static func time(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "—" }
        return String(format: "%.2f с", seconds)
    }

    /// «удар», «удара», «ударов» — иначе интерфейс читается как машинный перевод.
    static func strokeCount(_ count: Int) -> String {
        let tail = count % 100
        if (11...14).contains(tail) { return "\(count) ударов" }
        switch count % 10 {
        case 1: return "\(count) удар"
        case 2...4: return "\(count) удара"
        default: return "\(count) ударов"
        }
    }
}
