import AVFoundation
import Foundation


@main
struct Runner {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count > 1 else {
            print("usage: analyze <video> [right|left]")
            exit(1)
        }
        let url = URL(fileURLWithPath: args[1])
                        let hand: Handedness = args.count > 2 && args[2] == "left" ? .left : .right
        let fullScan = args.contains("--full")

        let start = Date()
        let track = try await extractTrack(url: url, fullScan: fullScan) { progress in
            let line = "\r\(progress.stage.title): \(Int(progress.fraction * 100))%          "
            FileHandle.standardError.write(line.data(using: .utf8)!)
        }
        FileHandle.standardError.write("\n".data(using: .utf8)!)

        print("=== ВИДЕО ===")
        print("режим:       \(fullScan ? "полный проход" : "два прохода")")
        print("кадр:        \(Int(track.displaySize.width))x\(Int(track.displaySize.height))")
        print("длительность: \(String(format: "%.1f", track.duration)) с")
        print("fps:          \(String(format: "%.1f", track.frameRate))")
        print("кадров всего: \(track.totalFrames)")
        print("разобрано:    \(track.frames.count) (\(track.totalFrames > 0 ? track.frames.count * 100 / track.totalFrames : 100)%)")
        print("разбор занял: \(String(format: "%.0f", Date().timeIntervalSince(start))) с")

        let withSkeleton = track.frames.filter { $0.joints.count >= 8 }.count
        let ratio = Double(withSkeleton) / Double(max(track.frames.count, 1))
        print("скелет виден: \(String(format: "%.0f", ratio * 100))% кадров")

        // ДИАГНОСТИКА: телепортируется ли скелет между людьми в кадре
        var jumps = 0
        var biggest = 0.0
        var prevNeck: CGPoint?
        var prevTime = 0.0
        let scale = StrokeAnalyzer.torsoScale(frames: track.frames, fallbackHeight: track.displaySize.height)
        for frame in track.frames {
            guard let neck = frame.point(.neck) else { prevNeck = nil; continue }
            if let prev = prevNeck, frame.time - prevTime < 0.1 {
                let moved = Geometry.distance(prev, neck) / scale
                if moved > 0.5 { jumps += 1 }
                biggest = max(biggest, moved)
            }
            prevNeck = neck
            prevTime = frame.time
        }
        print("\n=== УСТОЙЧИВОСТЬ ТРЕКИНГА ===")
        print("длина корпуса: \(String(format: "%.0f", scale)) px")
        print("прыжков шеи >0.5 корпуса за кадр: \(jumps)")
        print("самый большой прыжок: \(String(format: "%.2f", biggest)) корпуса за кадр")

        var analysis = StrokeAnalyzer().analyze(track: track, handedness: hand)

        // Мяч: только по окнам вокруг найденных ударов.
        var trajectories: [BallTrajectory] = []
        if !args.contains("--no-ball") {
            let tracker = BallTracker()
            let windows = tracker.windows(around: analysis.strokes.map(\.contactTime), duration: track.duration)
            let ballStart = Date()
            trajectories = try await tracker.trajectories(in: url, windows: windows)
            print("мяч: \(trajectories.count) траекторий в \(windows.count) окнах за \(String(format: "%.0f", Date().timeIntervalSince(ballStart))) с")
            analysis = StrokeAnalyzer().analyze(track: track, handedness: hand, ballTrajectories: trajectories)
            print("ударов подтверждено мячом: \(analysis.ballConfirmedCount) из \(analysis.strokes.count)")

            // --debug-ball <время>: кандидаты вокруг одного удара
            if let flag = args.firstIndex(of: "--debug-ball"), args.count > flag + 1, let t = Double(args[flag + 1]) {
                print("\n=== КАНДИДАТЫ МЯЧА около \(t) с ===")
                let candidates = BallContactMatcher.candidates(near: t, trajectories: trajectories, signals: analysis.signals)
                for c in candidates {
                    let tr = c.trajectory
                    print(String(format: "  %6.2f→%6.2f  старт (%.0f,%.0f) → конец (%.0f,%.0f)  кисть (%.0f,%.0f)  прилёт %.2f  издалека %.2f  точек %d",
                        tr.start, tr.end, tr.first!.x, tr.first!.y, tr.last!.x, tr.last!.y, c.wrist.x, c.wrist.y, c.arrival, c.approach, tr.points.count))
                }
            }
        }

        print("\n=== ШУМ ИЗМЕРЕНИЯ (тишины \(String(format: "%.1f", analysis.noise.quietSeconds)) с) ===")
        for run in NoiseEstimator.quietRuns(signals: analysis.signals) {
            let t0 = analysis.signals.times[run.lowerBound], t1 = analysis.signals.times[run.upperBound - 1]
            print(String(format: "  тихий отрезок %6.2f–%6.2f с (%.1f с)", t0, t1, t1 - t0))
        }
        for key in MetricKey.allCases {
            guard let level = analysis.noise.noise(for: key) else { continue }
            let verdict = analysis.noise.isMeasurable(key) ? "" : "  <-- не измеримо"
            print("  \(key.title): ±\(String(format: "%.\(key.fractionDigits)f", level)) \(key.unit), порог ±\(String(format: "%.\(key.fractionDigits)f", key.noticeableSpread))\(verdict)")
        }

        print("\n=== РАКУРС ===")
        print(analysis.cameraView.title)
        let disabled = analysis.disabledMetrics
        if !disabled.isEmpty {
            print("отключены метрики: \(disabled.map(\.title).joined(separator: ", "))")
        }

        print("\n=== ПРЕДУПРЕЖДЕНИЯ ===")
        for warning in analysis.warnings { print("• \(warning.text)") }

        print("\n=== УДАРЫ: \(analysis.strokes.count) ===")
        for stroke in analysis.strokes {
            let speed = String(format: "%.2f", stroke.value(.peakWristSpeed))
            let type = stroke.type.title.padding(toLength: 16, withPad: " ", startingAt: 0)
            let shape = stroke.shape
            let shapeText = String(
                format: "сдвиг %.2f  путь %.2f  прям %.2f  провод %.2f  выступ %.1f",
                shape.forwardDisplacement, shape.forwardPath, shape.straightness,
                shape.followThrough, shape.prominence
            )
            let ball = stroke.ballContact.map { String(format: "мяч %.2f", $0.time) } ?? "мяч  --- "
            let height = String(format: "выс %+.2f", stroke.value(.contactHeight))
            let verdict = stroke.isDoubtful ? "✗ " + stroke.doubts.map(\.rawValue).joined(separator: ",") : "✓"
            print("#\(stroke.id + 1)\t\(String(format: "%6.2f", stroke.contactTime)) с\t\(ball)\t\(type)\tскор \(speed)\t\(height)\t\(shapeText)\t\(verdict)")
        }

        print("\n=== РАЗБРОС ПО ТИПАМ УДАРА ===")
        for type in analysis.presentTypes {
            let count = analysis.strokes(of: type).count
            print("\n-- \(type.title): \(count) --")
            guard count >= 2 else {
                print("   мало ударов для разброса")
                continue
            }
            for summary in analysis.ranked(of: type) {
                let mean = String(format: "%.2f", summary.mean)
                let sd = String(format: "%.2f", summary.standardDeviation)
                let flag = summary.instability > 1 ? "  <-- гуляет" : ""
                print("   \(summary.key.title): \(mean) \(summary.key.unit), ±\(sd)\(flag)")
            }
        }

        // --export <папка>: сессия в формате приложения, чтобы подложить
        // её в контейнер симулятора и смотреть интерфейс на живых данных.
        if let flag = args.firstIndex(of: "--export"), args.count > flag + 1 {
            let dir = URL(fileURLWithPath: args[flag + 1])
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(track).write(to: dir.appending(path: "track.plist"))
            try encoder.encode(trajectories).write(to: dir.appending(path: "ball.plist"))
            var typeCounts: [String: Int] = [:]
            for stroke in analysis.acceptedStrokes { typeCounts[stroke.type.rawValue, default: 0] += 1 }
            let videoName = "video.\(url.pathExtension.lowercased())"
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            let meta: [String: Any] = [
                "id": UUID().uuidString,
                "createdAt": Date().timeIntervalSinceReferenceDate,
                "handedness": hand.rawValue,
                "duration": track.duration,
                "cameraView": analysis.cameraView.rawValue,
                "strokeCount": analysis.acceptedStrokes.count,
                "typeCounts": typeCounts,
                "videoFileName": videoName,
                "videoBytes": bytes,
            ]
            try JSONSerialization.data(withJSONObject: meta).write(to: dir.appending(path: "meta.json"))
            print("\nэкспорт: \(dir.path) (видео скопируй как \(videoName))")
        }

        // --noise <from> <to>: разброс метрик на отрезке, где игрок стоит.
        // Это шум измерения — то, что нельзя приписывать технике.
        if let flag = args.firstIndex(of: "--noise"), args.count > flag + 2,
           let from = Double(args[flag + 1]), let to = Double(args[flag + 2]) {
            let sig = analysis.signals
            let indices = sig.times.indices.filter { sig.times[$0] >= from && sig.times[$0] <= to }
            func sd(_ values: [Double]) -> Double {
                let finite = values.filter { $0.isFinite }
                guard finite.count > 2 else { return .nan }
                let mean = finite.reduce(0, +) / Double(finite.count)
                return (finite.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(finite.count - 1)).squareRoot()
            }
            let scale = indices.map { sig.scale(at: $0) }.reduce(0, +) / Double(max(1, indices.count))
            print("\n=== ШУМ на \(from)–\(to) с (игрок стоит), кадров \(indices.count), корпус \(String(format: "%.0f", scale)) px ===")
            print(String(format: "угол локтя:        ±%.1f°", sd(indices.map { sig.elbowAngle.values[$0] })))
            print(String(format: "угол колена:       ±%.1f°", sd(indices.map { sig.kneeAngle.values[$0] })))
            print(String(format: "наклон плеч:       ±%.1f°", sd(indices.map { sig.shoulderAngle.values[$0] })))
            print(String(format: "кисть по X:        ±%.2f корп", sd(indices.map { sig.wristX.values[$0] }) / scale))
            print(String(format: "кисть по Y:        ±%.2f корп", sd(indices.map { sig.wristY.values[$0] }) / scale))
            print(String(format: "скорость кисти:    медиана %.2f корп/с", {
                let v = indices.map { sig.wristSpeed.values[$0] }.filter { $0.isFinite }.sorted()
                return v.isEmpty ? Double.nan : v[v.count / 2]
            }()))
        }

        // Гистограмма скорости кисти по всему видео — видно, есть ли вообще всплески.
        let speeds = analysis.signals.wristSpeed.values.filter { $0.isFinite }
        if !speeds.isEmpty {
            let sorted = speeds.sorted()
            func percentile(_ p: Double) -> String {
                String(format: "%.2f", sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))])
            }
            print("\n=== СКОРОСТЬ КИСТИ по всему видео (корп/с) ===")
            print("медиана \(percentile(0.5))  p90 \(percentile(0.9))  p99 \(percentile(0.99))  max \(String(format: "%.2f", sorted.last!))")
            print("(порог удара сейчас 2.00)")
        }

    }

    static func extractTrack(
        url: URL,
        fullScan: Bool,
        onProgress: @escaping @Sendable (ExtractionProgress) -> Void
    ) async throws -> PoseTrack {
        if fullScan {
            return try await PoseExtractor().extract(from: url, onProgress: onProgress)
        }
        var extractor = TwoPassExtractor()
        // --force прогоняет два прохода даже там, где эвристика их отключает:
        // нужно, чтобы сравнивать режимы на одном и том же файле.
        extractor.tuning.force = CommandLine.arguments.contains("--force")
        return try await extractor.extract(from: url, onProgress: onProgress)
    }
}
