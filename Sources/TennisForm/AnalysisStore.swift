import Foundation
import PhotosUI
import StrokeKit
import SwiftUI
import UIKit

@MainActor
@Observable
final class AnalysisStore {
    /// Что сейчас происходит и сколько осталось. Стадия важнее процента:
    /// на большом файле первые десятки секунд — чтение, и без стадии
    /// это выглядит как зависание.
    struct Work: Equatable {
        enum Stage: Equatable {
            case copying
            case extracting(ExtractionProgress.Stage)
            case computing

            var title: String {
                switch self {
                case .copying: return "Копирую видео из галереи"
                case .extracting(let stage): return stage.title
                case .computing: return "Считаю удары"
                }
            }
        }

        var stage: Stage
        var fraction: Double
        var remaining: TimeInterval?
    }

    enum State: Equatable {
        case idle
        case working(Work)
        case ready(SessionAnalysis, videoURL: URL)
        case failed(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle): return true
            case (.working(let a), .working(let b)): return a == b
            case (.ready(_, let a), .ready(_, let b)): return a == b
            case (.failed(let a), .failed(let b)): return a == b
            default: return false
            }
        }
    }

    var state: State = .idle
    var handedness: Handedness = .right

    private var currentJob: Task<Void, Never>?
    private var copyObservation: NSKeyValueObservation?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private let overrides = StrokeOverrideStore()

    /// Оценка оставшегося времени по замеренной скорости текущей стадии.
    private var stageStarted: Date?
    private var stageKey: String?

    // MARK: - Загрузка из галереи

    /// Файл из галереи приходит только копией, и на гигабайтной записи
    /// это десятки секунд. Раньше они проходили при нулевом фидбэке.
    func analyze(item: PhotosPickerItem) {
        currentJob?.cancel()
        state = .working(Work(stage: .copying, fraction: 0, remaining: nil))
        beginStage("copy")

        let progress = item.loadTransferable(type: MovieFile.self) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.copyObservation = nil
                switch result {
                case .success(let movie?):
                    self.analyze(url: movie.url)
                case .success(nil):
                    self.state = .failed("Не получилось прочитать этот файл.")
                case .failure(let error):
                    self.state = .failed(error.localizedDescription)
                }
            }
        }

        copyObservation = progress.observe(\.fractionCompleted, options: [.new]) { [weak self] _, change in
            guard let fraction = change.newValue else { return }
            Task { @MainActor [weak self] in
                self?.report(.copying, fraction: fraction)
            }
        }
    }

    // MARK: - Разбор

    func analyze(url: URL) {
        currentJob?.cancel()
        state = .working(Work(stage: .extracting(.opening), fraction: 0, remaining: nil))
        keepAlive(true)

        let hand = handedness
        currentJob = Task {
            defer { keepAlive(false) }
            do {
                let track = try await TwoPassExtractor().extract(from: url) { progress in
                    Task { @MainActor [weak self] in
                        self?.report(.extracting(progress.stage), fraction: progress.fraction)
                    }
                }
                try Task.checkCancellation()

                self.state = .working(Work(stage: .computing, fraction: 1, remaining: nil))
                var analysis = StrokeAnalyzer().analyze(track: track, handedness: hand)
                try Task.checkCancellation()

                self.overrides.apply(to: &analysis)
                self.state = .ready(analysis, videoURL: url)
            } catch is CancellationError {
                // Пользователь ушёл — молча выходим.
            } catch {
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    /// Пользователь решил, удар это или нет. Статистика пересчитывается
    /// сразу, решение запоминается для этого видео.
    func setRejected(_ rejected: Bool, for stroke: Stroke) {
        guard case .ready(var analysis, let url) = state else { return }
        analysis.setRejected(rejected, for: stroke)
        overrides.remember(rejected: rejected, for: stroke, in: analysis)
        state = .ready(analysis, videoURL: url)
    }

    func reset() {
        currentJob?.cancel()
        currentJob = nil
        copyObservation = nil
        keepAlive(false)
        state = .idle
    }

    // MARK: - Прогресс и оценка времени

    private func report(_ stage: Work.Stage, fraction: Double) {
        guard case .working = state else { return }

        // Оценка считается внутри одной стадии: у чтения и у разбора
        // разная скорость, и смешивать их — врать в обе стороны.
        let key = stageIdentity(stage)
        if key != stageKey { beginStage(key) }

        var remaining: TimeInterval?
        if let started = stageStarted, fraction > 0.05 {
            let elapsed = Date().timeIntervalSince(started)
            remaining = elapsed / fraction * (1 - fraction)
        }
        state = .working(Work(stage: stage, fraction: fraction, remaining: remaining))
    }

    private func beginStage(_ key: String) {
        stageKey = key
        stageStarted = Date()
    }

    private func stageIdentity(_ stage: Work.Stage) -> String {
        switch stage {
        case .copying: return "copy"
        case .extracting(.opening): return "open"
        case .extracting(.scanning): return "scan"
        case .extracting(.analysing): return "analyse"
        case .extracting(.analysingEverything): return "full"
        case .computing: return "compute"
        }
    }

    // MARK: - Не дать системе убить разбор

    /// Экран не гаснет, а короткое сворачивание — ответить на сообщение —
    /// разбор переживает. Настоящего фона на минуты iOS не даёт: после
    /// ~30 секунд в свёрнутом виде процесс всё равно остановят.
    private func keepAlive(_ on: Bool) {
        UIApplication.shared.isIdleTimerDisabled = on
        if on {
            guard backgroundTask == .invalid else { return }
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "stroke-analysis") { [weak self] in
                self?.endBackgroundTask()
            }
        } else {
            endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
