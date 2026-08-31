import Foundation
import StrokeKit
import SwiftUI

@MainActor
@Observable
final class AnalysisStore {
    enum State {
        case idle
        case working(stage: String, progress: Double)
        case ready(SessionAnalysis, videoURL: URL)
        case failed(String)
    }

    var state: State = .idle
    var handedness: Handedness = .right

    private var currentJob: Task<Void, Never>?

    func analyze(url: URL) {
        currentJob?.cancel()
        state = .working(stage: "Читаю видео", progress: 0)

        let hand = handedness
        // Task наследует изоляцию MainActor, а сам extract помечен nonisolated async,
        // поэтому тяжёлая работа всё равно уходит с главного потока.
        currentJob = Task {
            do {
                // Двухпроходный разбор: на записи в слоу-мо полный проход
                // по всем кадрам занимает минуты, а удары занимают доли времени.
                let track = try await TwoPassExtractor().extract(from: url) { progress in
                    Task { @MainActor in
                        self.state = .working(stage: "Ищу скелет в кадрах", progress: progress)
                    }
                }
                try Task.checkCancellation()

                self.state = .working(stage: "Считаю удары", progress: 1)
                let analysis = StrokeAnalyzer().analyze(track: track, handedness: hand)
                try Task.checkCancellation()

                self.state = .ready(analysis, videoURL: url)
            } catch is CancellationError {
                // Пользователь ушёл — молча выходим.
            } catch {
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    func reset() {
        currentJob?.cancel()
        currentJob = nil
        state = .idle
    }
}
