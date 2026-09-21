import Foundation
import StrokeKit

/// Решения пользователя «это удар / это не удар». Живут между запусками:
/// повторный разбор того же видео не должен заставлять размечать заново.
///
/// Видео опознаётся по отпечатку из длительности, размера кадра и числа
/// кадров — файл из галереи каждый раз копируется под новым именем,
/// так что путь как ключ не годится.
struct StrokeOverrideStore {
    private let defaults: UserDefaults
    private let key = "strokeOverrides"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func fingerprint(of track: PoseTrack) -> String {
        "\(Int(track.duration * 1000))-\(Int(track.displaySize.width))x\(Int(track.displaySize.height))-\(track.totalFrames)"
    }

    private static func strokeKey(_ stroke: Stroke) -> String {
        String(Int((stroke.contactTime * 1000).rounded()))
    }

    /// Применяет сохранённые решения поверх автоматических сомнений.
    func apply(to analysis: inout SessionAnalysis) {
        let saved = overrides(for: Self.fingerprint(of: analysis.track))
        guard !saved.isEmpty else { return }
        for stroke in analysis.strokes {
            if let rejected = saved[Self.strokeKey(stroke)] {
                analysis.setRejected(rejected, for: stroke)
            }
        }
    }

    func remember(rejected: Bool, for stroke: Stroke, in analysis: SessionAnalysis) {
        var all = load()
        let fingerprint = Self.fingerprint(of: analysis.track)
        var forVideo = all[fingerprint] ?? [:]
        forVideo[Self.strokeKey(stroke)] = rejected
        all[fingerprint] = forVideo
        save(all)
    }

    private func overrides(for fingerprint: String) -> [String: Bool] {
        load()[fingerprint] ?? [:]
    }

    private func load() -> [String: [String: Bool]] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: [String: Bool]].self, from: data)
        else { return [:] }
        return decoded
    }

    private func save(_ value: [String: [String: Bool]]) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }
}
