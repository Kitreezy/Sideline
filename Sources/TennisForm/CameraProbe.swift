import AVFoundation
import Foundation
import Vision

/// Проверка, которую нельзя сделать ни в симуляторе, ни на маке: потянет ли
/// конкретный телефон запись на высокой частоте кадров одновременно с живым
/// разбором позы. От ответа зависит, возможен ли гибридный режим —
/// точный файл плюс живой слой поверх него.
@MainActor
@Observable
final class CameraProbe {
    struct Line: Identifiable {
        let id = UUID()
        let title: String
        let value: String
        let verdict: Verdict

        enum Verdict { case good, bad, neutral }
    }

    enum State: Equatable {
        case idle
        case running(String)
        case done
        case failed(String)
    }

    var state: State = .idle
    var lines: [Line] = []

    private var task: Task<Void, Never>?

    func run() {
        task?.cancel()
        lines = []
        state = .running("Спрашиваю доступ к камере")

        task = Task {
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                state = .failed("Без доступа к камере проверить нечего.")
                return
            }
            guard let device = AVCaptureDevice.default(
                .builtInWideAngleCamera, for: .video, position: .back
            ) else {
                state = .failed("Не нашёл заднюю камеру.")
                return
            }

            listFormats(device)

            guard let fast = bestHighSpeedFormat(device) else {
                state = .failed("У камеры нет форматов с высокой частотой кадров.")
                return
            }

            let fps = fast.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
            let dimensions = CMVideoFormatDescriptionGetDimensions(fast.formatDescription)
            add("Выбран формат",
                "\(dimensions.width)x\(dimensions.height) @ \(Int(fps)) fps",
                .neutral)

            state = .running("Тест 1: только живой поток")
            let liveOnly = await measure(
                device: device, format: fast, fps: fps, alsoRecordToFile: false
            )
            report(liveOnly, prefix: "Только поток")

            state = .running("Тест 2: запись плюс живой поток")
            let both = await measure(
                device: device, format: fast, fps: fps, alsoRecordToFile: true
            )
            report(both, prefix: "Запись + поток")

            conclude(liveOnly: liveOnly, both: both, requestedFps: fps)
            state = .done
        }
    }

    // MARK: - Форматы

    private func listFormats(_ device: AVCaptureDevice) {
        let high = device.formats.compactMap { format -> (Int32, Int32, Double)? in
            guard let maxRate = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max(),
                  maxRate >= 100 else { return nil }
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return (size.width, size.height, maxRate)
        }

        let best = Dictionary(grouping: high) { "\($0.0)x\($0.1)" }
            .mapValues { $0.map(\.2).max() ?? 0 }
            .sorted { $0.value > $1.value }

        if best.isEmpty {
            add("Форматы 100+ fps", "нет", .bad)
        } else {
            for (size, rate) in best.prefix(4) {
                add("Формат", "\(size) до \(Int(rate)) fps", .good)
            }
        }
    }

    private func bestHighSpeedFormat(_ device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        device.formats
            .filter { format in
                let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return size.width >= 1280
            }
            .max { lhs, rhs in
                let l = lhs.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
                let r = rhs.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
                return l < r
            }
    }

    // MARK: - Замер

    struct Measurement {
        var configured = false
        var configurationError: String?
        var deliveredFrames = 0
        var droppedFrames = 0
        var visionFrames = 0
        var visionMilliseconds = 0.0
        var seconds = 0.0

        var deliveredFps: Double { seconds > 0 ? Double(deliveredFrames) / seconds : 0 }
        var visionAverage: Double {
            visionFrames > 0 ? visionMilliseconds / Double(visionFrames) : 0
        }
    }

    private func measure(
        device: AVCaptureDevice,
        format: AVCaptureDevice.Format,
        fps: Double,
        alsoRecordToFile: Bool
    ) async -> Measurement {
        var result = Measurement()
        let session = AVCaptureSession()
        let collector = FrameCollector()

        do {
            session.beginConfiguration()
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                result.configurationError = "камера занята"
                session.commitConfiguration()
                return result
            }
            session.addInput(input)

            let dataOutput = AVCaptureVideoDataOutput()
            dataOutput.alwaysDiscardsLateVideoFrames = true
            dataOutput.setSampleBufferDelegate(collector, queue: DispatchQueue(label: "probe.frames"))
            guard session.canAddOutput(dataOutput) else {
                result.configurationError = "не принимает видеопоток"
                session.commitConfiguration()
                return result
            }
            session.addOutput(dataOutput)

            if alsoRecordToFile {
                let movieOutput = AVCaptureMovieFileOutput()
                guard session.canAddOutput(movieOutput) else {
                    // Вот тот самый исход, ради которого всё затевалось.
                    result.configurationError = "нельзя писать файл и одновременно читать поток"
                    session.commitConfiguration()
                    return result
                }
                session.addOutput(movieOutput)
            }

            // Частота задаётся на устройстве, а не на сессии.
            try device.lockForConfiguration()
            device.activeFormat = format
            let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()

            session.commitConfiguration()
            result.configured = true
        } catch {
            result.configurationError = error.localizedDescription
            return result
        }

        let started = Date()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                session.startRunning()
                Thread.sleep(forTimeInterval: 6)
                session.stopRunning()
                continuation.resume()
            }
        }

        let snapshot = collector.snapshot()
        result.seconds = Date().timeIntervalSince(started) - 0.2
        result.deliveredFrames = snapshot.delivered
        result.droppedFrames = snapshot.dropped
        result.visionFrames = snapshot.visionCount
        result.visionMilliseconds = snapshot.visionMilliseconds
        return result
    }

    // MARK: - Вывод

    private func report(_ measurement: Measurement, prefix: String) {
        guard measurement.configured else {
            add("\(prefix)", measurement.configurationError ?? "не настроилось", .bad)
            return
        }
        add("\(prefix): кадров в секунду",
            String(format: "%.0f", measurement.deliveredFps),
            measurement.deliveredFps >= 25 ? .good : .bad)
        add("\(prefix): потеряно кадров",
            "\(measurement.droppedFrames)",
            measurement.droppedFrames > measurement.deliveredFrames ? .bad : .neutral)
        if measurement.visionFrames > 0 {
            add("\(prefix): Vision на кадр",
                String(format: "%.1f мс", measurement.visionAverage),
                measurement.visionAverage < 25 ? .good : .bad)
        }
    }

    private func conclude(liveOnly: Measurement, both: Measurement, requestedFps: Double) {
        if both.configured {
            add("Гибридный режим",
                "возможен: файл и живой разбор уживаются",
                .good)
        } else {
            add("Гибридный режим",
                "не выходит — придётся выбирать между высокой частотой и живым слоем",
                .bad)
        }

        let visionMs = liveOnly.visionAverage
        if visionMs > 0 {
            let ceiling = 1000 / visionMs
            add("Потолок живого разбора",
                String(format: "%.0f кадров/с", ceiling),
                ceiling >= 30 ? .good : .bad)
        }
    }

    private func add(_ title: String, _ value: String, _ verdict: Line.Verdict) {
        lines.append(Line(title: title, value: value, verdict: verdict))
    }
}

private struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Считает кадры и заодно меряет, сколько времени занимает поза на устройстве.
private final class FrameCollector: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var delivered = 0
    private var dropped = 0
    private var visionCount = 0
    private var visionMilliseconds = 0.0
    private var busy = false

    struct Snapshot {
        let delivered: Int
        let dropped: Int
        let visionCount: Int
        let visionMilliseconds: Double
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                delivered: delivered,
                dropped: dropped,
                visionCount: visionCount,
                visionMilliseconds: visionMilliseconds
            )
        }
    }

    /// Отдельный синхронный метод: захват замка нельзя делать прямо
    /// в асинхронном контексте.
    private func noteVision(_ elapsed: Double) {
        lock.withLock {
            visionCount += 1
            visionMilliseconds += elapsed
            busy = false
        }
    }

    private func claimSlot() -> Bool {
        lock.withLock {
            delivered += 1
            guard !busy else { return false }
            busy = true
            return true
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let shouldAnalyse = claimSlot()
        guard shouldAnalyse, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Поза считается не на каждом кадре: в живом режиме так и будет,
        // иначе очередь кадров растёт быстрее, чем разгребается.
        // CVPixelBuffer не Sendable, а передать его в задачу надо: буфер
        // принадлежит нам до возврата из колбэка, гонки тут нет.
        let boxed = UncheckedBox(buffer)
        Task.detached { [weak self] in
            var request = DetectHumanBodyPoseRequest()
            request.detectsHands = false
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try? await request.perform(on: boxed.value, orientation: .right)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000

            self?.noteVision(elapsed)
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        lock.withLock { dropped += 1 }
    }
}
