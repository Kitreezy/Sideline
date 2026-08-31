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
            if Int(progress * 100) % 10 == 0 {
                FileHandle.standardError.write("\rпрогресс \(Int(progress * 100))%".data(using: .utf8)!)
            }
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

        let analysis = StrokeAnalyzer().analyze(track: track, handedness: hand)

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
            let elbow = String(format: "%.0f", stroke.value(.elbowAtContact))
            let type = stroke.type.title.padding(toLength: 16, withPad: " ", startingAt: 0)
            let lead = StrokeClassifier.shoulderLead(
                phases: stroke.phases, frames: track.frames,
                signals: analysis.signals, handedness: hand
            )
            let leadText = lead.map { String(format: "%+.2f", $0) } ?? "  -  "
            let overhead = StrokeClassifier.overheadMargin(
                phases: stroke.phases, frames: track.frames,
                signals: analysis.signals, handedness: hand
            )
            let overheadText = overhead.map { String(format: "%+.2f", $0) } ?? "  -  "
            let backswing = stroke.value(.backswingDuration)
            let backswingText = backswing.isFinite ? String(format: "%.2f", backswing) : "нет"
            print("#\(stroke.id + 1)\tконтакт \(String(format: "%6.2f", stroke.contactTime)) с\t\(type)\tплечо \(leadText)\tверх \(overheadText)\tзамах \(backswingText)\tскорость \(speed)\tлокоть \(elbow)°")
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
        onProgress: @escaping @Sendable (Double) -> Void
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
