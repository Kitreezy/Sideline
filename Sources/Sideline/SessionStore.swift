import Foundation
import StrokeKit

/// Сохранённая тренировка. Хранится дорогое — дорожка скелета и видео;
/// удары и метрики пересчитываются при открытии за миллисекунды. Поэтому
/// после улучшения анализатора старые сессии разбираются по-новому
/// без повторного прогона Vision.
struct SavedSession: Codable, Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let handedness: Handedness
    let duration: TimeInterval
    let cameraView: CameraView
    let strokeCount: Int
    /// Сколько ударов какого типа — для строки в списке, без загрузки дорожки.
    let typeCounts: [String: Int]
    let videoFileName: String
    var videoBytes: Int64
    /// Средние, разбросы и шум — всё, что нужно ряду прогресса. Лежит здесь,
    /// чтобы построить график по десятку тренировок, не читая ни одной
    /// дорожки скелета: каждая из них разбирается секунды.
    var digest: SessionDigest?
}

/// Разбор, который начали, но не закончили: приложение убили в фоне
/// или оно упало. Видео уже лежит у нас, повторять копирование не нужно.
struct PendingAnalysis: Codable, Equatable {
    let startedAt: Date
    let handedness: Handedness
    let videoFileName: String
}

enum SessionStoreError: LocalizedError {
    case missingTrack

    var errorDescription: String? {
        switch self {
        case .missingTrack: return "Файл разбора повреждён или удалён."
        }
    }
}

@MainActor
final class SessionStore {
    private nonisolated let root: URL
    private let fileManager = FileManager.default

    init(root: URL? = nil) {
        let base = root ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Sideline", directoryHint: .isDirectory)
        self.root = base
        try? fileManager.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
    }

    private nonisolated var sessionsDirectory: URL { root.appending(path: "Sessions", directoryHint: .isDirectory) }
    private var pendingDirectory: URL { root.appending(path: "Pending", directoryHint: .isDirectory) }
    private nonisolated func directory(for id: UUID) -> URL {
        sessionsDirectory.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    // MARK: - Список

    func list() -> [SavedSession] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: sessionsDirectory, includingPropertiesForKeys: nil
        ) else { return [] }

        return entries
            .compactMap { dir -> SavedSession? in
                guard let data = try? Data(contentsOf: dir.appending(path: "meta.json")) else { return nil }
                return try? JSONDecoder().decode(SavedSession.self, from: data)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func totalBytes() -> Int64 {
        list().reduce(0) { $0 + $1.videoBytes }
    }

    /// Тренировки без сводки или со сводкой от прежней версии анализатора.
    /// Их надо пересчитать, иначе на одном графике окажутся два прибора.
    func needingDigest() -> [SavedSession] {
        list().filter { $0.digest?.isCurrent != true }
    }

    // MARK: - Сохранение и загрузка

    /// Забирает видео к себе (move, не copy: оно уже наша временная копия)
    /// и кладёт рядом дорожку. Возвращает новый адрес видео — старый
    /// после этого недействителен.
    func save(
        track: PoseTrack,
        ballTrajectories: [BallTrajectory],
        analysis: SessionAnalysis,
        handedness: Handedness,
        videoURL: URL
    ) throws -> (session: SavedSession, videoURL: URL) {
        let id = UUID()
        let dir = directory(for: id)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let videoName = "video.\(videoURL.pathExtension.isEmpty ? "mov" : videoURL.pathExtension)"
        let videoDestination = dir.appending(path: videoName)
        try fileManager.moveItem(at: videoURL, to: videoDestination)

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(track).write(to: dir.appending(path: "track.plist"), options: .atomic)
        try encoder.encode(ballTrajectories).write(to: dir.appending(path: "ball.plist"), options: .atomic)

        var typeCounts: [String: Int] = [:]
        for stroke in analysis.acceptedStrokes { typeCounts[stroke.type.rawValue, default: 0] += 1 }

        let session = SavedSession(
            id: id,
            createdAt: Date(),
            handedness: handedness,
            duration: track.duration,
            cameraView: analysis.cameraView,
            strokeCount: analysis.acceptedStrokes.count,
            typeCounts: typeCounts,
            videoFileName: videoName,
            videoBytes: fileSize(videoDestination),
            digest: SessionDigest(analysis)
        )
        try JSONEncoder().encode(session).write(to: dir.appending(path: "meta.json"), options: .atomic)
        return (session, videoDestination)
    }

    /// Читает дорожку и разбирает её заново. Дорогая часть — чтение:
    /// на длинной записи это секунды, поэтому вызывать только с фонового
    /// потока. Vision при этом не запускается, и старые тренировки
    /// получают все улучшения анализатора.
    nonisolated func analysis(
        of session: SavedSession
    ) throws -> (analysis: SessionAnalysis, videoURL: URL) {
        let dir = directory(for: session.id)
        guard let data = try? Data(contentsOf: dir.appending(path: "track.plist")) else {
            throw SessionStoreError.missingTrack
        }
        let track = try PropertyListDecoder().decode(PoseTrack.self, from: data)
        // Старые сессии без мяча открываются как раньше — без него.
        let ball = (try? Data(contentsOf: dir.appending(path: "ball.plist")))
            .flatMap { try? PropertyListDecoder().decode([BallTrajectory].self, from: $0) }
        let analysis = StrokeAnalyzer().analyze(
            track: track, handedness: session.handedness, ballTrajectories: ball
        )
        return (analysis, dir.appending(path: session.videoFileName))
    }

    /// Обновляет сводку тренировки: число ударов в списке — после того,
    /// как пользователь повыкидывал не-удары, — и средние с разбросами,
    /// из которых потом строится прогресс.
    @discardableResult
    func refresh(_ session: SavedSession, from analysis: SessionAnalysis) -> SavedSession {
        var typeCounts: [String: Int] = [:]
        for stroke in analysis.acceptedStrokes { typeCounts[stroke.type.rawValue, default: 0] += 1 }
        let updated = SavedSession(
            id: session.id, createdAt: session.createdAt, handedness: session.handedness,
            duration: session.duration, cameraView: session.cameraView,
            strokeCount: analysis.acceptedStrokes.count, typeCounts: typeCounts,
            videoFileName: session.videoFileName, videoBytes: session.videoBytes,
            digest: SessionDigest(analysis)
        )
        try? JSONEncoder().encode(updated)
            .write(to: directory(for: session.id).appending(path: "meta.json"), options: .atomic)
        return updated
    }

    func delete(_ session: SavedSession) {
        try? fileManager.removeItem(at: directory(for: session.id))
    }

    // MARK: - Незаконченный разбор

    /// Видео перекладывается к нам до начала разбора: если приложение убьют,
    /// самая долгая часть — копирование из галереи — не пропадёт.
    func beginPending(videoURL: URL, handedness: Handedness) throws -> URL {
        clearPending()
        let name = "video.\(videoURL.pathExtension.isEmpty ? "mov" : videoURL.pathExtension)"
        let destination = pendingDirectory.appending(path: name)
        try fileManager.moveItem(at: videoURL, to: destination)
        let pending = PendingAnalysis(startedAt: Date(), handedness: handedness, videoFileName: name)
        try JSONEncoder().encode(pending).write(to: pendingDirectory.appending(path: "pending.json"), options: .atomic)
        return destination
    }

    func pending() -> (info: PendingAnalysis, videoURL: URL)? {
        guard let data = try? Data(contentsOf: pendingDirectory.appending(path: "pending.json")),
              let info = try? JSONDecoder().decode(PendingAnalysis.self, from: data)
        else { return nil }
        let video = pendingDirectory.appending(path: info.videoFileName)
        guard fileManager.fileExists(atPath: video.path) else {
            clearPending()
            return nil
        }
        return (info, video)
    }

    func clearPending() {
        try? fileManager.removeItem(at: pendingDirectory)
        try? fileManager.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
    }

    private func fileSize(_ url: URL) -> Int64 {
        (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }
}
