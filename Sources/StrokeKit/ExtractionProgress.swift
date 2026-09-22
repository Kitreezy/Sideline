import Foundation

/// Что именно сейчас делает разбор. «43%» без стадии не отвечает на вопрос
/// «оно вообще работает?» — особенно на большом файле, где первые десятки
/// секунд уходят на чтение.
public struct ExtractionProgress: Sendable, Equatable {
    public enum Stage: Sendable, Equatable {
        /// Открываем файл, читаем метаданные.
        case opening
        /// Первый проход по прореженным кадрам: ищем, где есть удары.
        case scanning
        /// Второй проход по окнам на полной частоте.
        case analysing(window: Int, of: Int)
        /// Разбор всех кадров подряд — короткое видео или обычная частота.
        case analysingEverything

        public var title: String {
            switch self {
            case .opening: return "Открываю видео"
            case .scanning: return "Ищу, где удары"
            case .analysing(let window, let total): return "Разбираю удар \(window) из \(total)"
            case .analysingEverything: return "Разбираю кадры"
            }
        }
    }

    public let stage: Stage
    /// Доля всей работы, 0...1 — по ней считается оставшееся время.
    public let fraction: Double

    public init(stage: Stage, fraction: Double) {
        self.stage = stage
        self.fraction = min(1, max(0, fraction))
    }
}
