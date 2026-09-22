import AVFoundation
import CoreGraphics
import Foundation
import StrokeKit
import Vision

/// Живой поток с камеры, разобранный тем же кодом, что и записанное видео.
/// Частота тут намеренно невысокая: для проверки кадра хватает нескольких
/// кадров в секунду, а греть телефон до начала съёмки незачем.
@MainActor
@Observable
final class LivePoseCamera {
    enum State: Equatable {
        case idle
        case starting
        case running
        case denied
        case failed(String)
    }

    var state: State = .idle
    var latestFrame: PoseFrame?
    var frameSize: CGSize = .zero
    var report: FramingReport?

    /// Слой предпросмотра берёт сессию отсюда.
    let session = AVCaptureSession()

    private let advisor = FramingAdvisor()
    private var tracker = PlayerTracker()
    private var recent: [PoseFrame] = []
    private var receiver: PoseStreamReceiver?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private let sessionQueue = DispatchQueue(label: "framing.session")

    /// Сколько кадров держим для вердикта — примерно две секунды.
    private let historyLimit = 24

    func start() async {
        guard state != .running, state != .starting else { return }
        state = .starting

        guard await AVCaptureDevice.requestAccess(for: .video) else {
            state = .denied
            return
        }
        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .back
        ) else {
            state = .failed("Не нашёл заднюю камеру.")
            return
        }

        let receiver = PoseStreamReceiver { [weak self] joints, size, time in
            Task { @MainActor [weak self] in
                self?.ingest(joints: joints, size: size, time: time)
            }
        }
        self.receiver = receiver

        do {
            session.beginConfiguration()
            session.sessionPreset = .high

            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                state = .failed("Камера занята другим приложением.")
                return
            }
            session.addInput(input)

            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(receiver, queue: DispatchQueue(label: "framing.frames"))
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                state = .failed("Камера не отдаёт кадры для разбора.")
                return
            }
            session.addOutput(output)
            session.commitConfiguration()

            // Разворот кадра под то, как телефон сейчас держат или закреплён.
            // Тогда Vision получает картинку «как надо», и координаты скелета
            // совпадают с тем, что видно на экране.
            let coordinator = AVCaptureDevice.RotationCoordinator(
                device: device, previewLayer: nil
            )
            rotationCoordinator = coordinator
            applyRotation(coordinator.videoRotationAngleForHorizonLevelCapture, to: output)
            let outputBox = UncheckedSendable(output)
            rotationObservation = coordinator.observe(
                \.videoRotationAngleForHorizonLevelCapture, options: [.new]
            ) { [weak self] _, change in
                guard let angle = change.newValue else { return }
                Task { @MainActor [weak self] in
                    self?.applyRotation(angle, to: outputBox.value)
                }
            }
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        let box = UncheckedSendable(session)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                box.value.startRunning()
                continuation.resume()
            }
        }
        state = .running
    }

    func stop() {
        rotationObservation?.invalidate()
        rotationObservation = nil
        let box = UncheckedSendable(session)
        sessionQueue.async { box.value.stopRunning() }
        state = .idle
    }

    private func applyRotation(_ angle: CGFloat, to output: AVCaptureVideoDataOutput) {
        guard let connection = output.connection(with: .video),
              connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    private func ingest(joints: [[BodyJoint: JointSample]], size: CGSize, time: TimeInterval) {
        frameSize = size

        let candidates = joints.map { PoseCandidate(joints: $0) }
        let chosen = tracker.select(from: candidates, at: time)
        let frame = PoseFrame(
            time: time,
            joints: chosen.map { candidates[$0].joints } ?? [:]
        )

        latestFrame = frame
        recent.append(frame)
        if recent.count > historyLimit { recent.removeFirst(recent.count - historyLimit) }

        report = advisor.evaluate(recent: recent, frameSize: size)
    }
}

struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Гоняет Vision по кадрам с камеры, но не больше одного за раз: очередь
/// кадров растёт быстрее, чем разгребается, и вердикт начинает отставать.
private final class PoseStreamReceiver: NSObject,
    AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {

    private let lock = NSLock()
    private var busy = false
    private let onFrame: @Sendable ([[BodyJoint: JointSample]], CGSize, TimeInterval) -> Void

    init(onFrame: @escaping @Sendable ([[BodyJoint: JointSample]], CGSize, TimeInterval) -> Void) {
        self.onFrame = onFrame
    }

    private func claim() -> Bool {
        lock.withLock {
            guard !busy else { return false }
            busy = true
            return true
        }
    }

    private func release() {
        lock.withLock { busy = false }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard claim(), let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let size = CGSize(
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer)
        )
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let boxed = UncheckedSendable(buffer)
        let handler = onFrame

        Task.detached { [weak self] in
            defer { self?.release() }
            var request = DetectHumanBodyPoseRequest()
            request.detectsHands = false
            // Кадр уже развёрнут соединением, поэтому Vision отдаём как есть.
            guard let observations = try? await request.perform(on: boxed.value, orientation: .up)
            else { return }
            handler(
                observations.map { PoseMapping.joints(from: $0, displaySize: size) },
                size,
                time.isFinite ? time : Date().timeIntervalSinceReferenceDate
            )
        }
    }
}
