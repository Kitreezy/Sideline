import Charts
import StrokeKit
import SwiftUI

struct StrokeDetailScreen: View {
    let analysis: SessionAnalysis
    let stroke: Stroke
    let videoURL: URL
    let onSetRejected: (Stroke, Bool) -> Void

    @State private var frameIndex: Int?

    private var currentIndex: Int { frameIndex ?? stroke.phases.contact }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SkeletonVideoView(
                    videoURL: videoURL,
                    track: analysis.track,
                    frameIndex: currentIndex
                )

                scrubber
                phaseBadge
                verdict
                metricsGrid
                charts
            }
            .padding()
        }
        .navigationTitle("\(stroke.type.title) #\(stroke.id + 1)")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Перемотка по кадрам

    private var scrubber: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    frameIndex = max(stroke.phases.start, currentIndex - 1)
                } label: {
                    Image(systemName: "backward.frame.fill")
                }
                Slider(
                    value: Binding(
                        get: { Double(currentIndex) },
                        set: { frameIndex = Int($0.rounded()) }
                    ),
                    in: Double(stroke.phases.start)...Double(stroke.phases.end),
                    step: 1
                )
                Button {
                    frameIndex = min(stroke.phases.end, currentIndex + 1)
                } label: {
                    Image(systemName: "forward.frame.fill")
                }
            }
            .buttonStyle(.bordered)

            HStack {
                Text(Format.time(analysis.signals.times[currentIndex]))
                    .font(.caption.monospacedDigit())
                Spacer()
                Button("К контакту") { frameIndex = stroke.phases.contact }
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
    }

    private var phaseBadge: some View {
        let phase: (String, Color) = {
            switch currentIndex {
            case ..<stroke.phases.transition: return ("Замах", .blue)
            case stroke.phases.transition..<stroke.phases.contact: return ("Разгон", .purple)
            case stroke.phases.contact: return ("Контакт", .orange)
            default: return ("Проводка", .teal)
            }
        }()

        return HStack(spacing: 8) {
            Circle().fill(phase.1).frame(width: 8, height: 8)
            Text(phase.0).font(.subheadline.weight(.medium))
            if currentIndex == stroke.phases.contact {
                Text("оценка по максимуму скорости кисти")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Удар или нет

    private var verdict: some View {
        let rejected = analysis.isRejected(stroke)
        return VStack(alignment: .leading, spacing: 8) {
            if !stroke.doubts.isEmpty {
                Label {
                    Text(stroke.doubts.map(\.title).joined(separator: " · "))
                        .font(.caption)
                } icon: {
                    Image(systemName: "questionmark.circle")
                }
                .foregroundStyle(.secondary)
            }
            Button {
                onSetRejected(stroke, !rejected)
            } label: {
                Label(
                    rejected ? "Это удар, вернуть в статистику" : "Это не удар",
                    systemImage: rejected ? "arrow.uturn.backward" : "xmark.circle"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(rejected ? .green : .secondary)
        }
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Цифры удара

    private var metricsGrid: some View {
        // Среднее берётся по ударам того же типа: сравнивать форхенд
        // со средним по бэкхендам бессмысленно.
        let summaries = analysis.summaries(of: stroke.type)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Цифры этого удара").font(.headline)
                Spacer()
                Text(stroke.type.title)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
            ForEach(MetricKey.allCases, id: \.self) { key in
                MetricRow(
                    key: key,
                    value: stroke.value(key),
                    sessionMean: summaries.first { $0.key == key }?.mean ?? .nan,
                    band: key.guidance(for: stroke.type).band,
                    disabledReason: key.unreliabilityReason(in: analysis.cameraView)
                )
            }
        }
    }

    // MARK: - Графики

    private var charts: some View {
        VStack(alignment: .leading, spacing: 20) {
            chart(
                title: "Скорость кисти",
                unit: MetricKey.peakWristSpeed.unit,
                signal: analysis.signals.wristSpeed,
                color: .purple
            )
            chart(
                title: "Угол локтя",
                unit: "°",
                signal: analysis.signals.elbowAngle,
                color: .blue
            )
        }
    }

    private func chart(title: String, unit: String, signal: Signal, color: Color) -> some View {
        let points = (stroke.phases.start...stroke.phases.end).compactMap { index -> (Double, Double)? in
            let value = signal.values[index]
            guard value.isFinite else { return nil }
            return (signal.times[index], value)
        }

        return VStack(alignment: .leading, spacing: 6) {
            Text("\(title), \(unit)").font(.headline)
            Chart {
                ForEach(points, id: \.0) { time, value in
                    LineMark(x: .value("Время", time), y: .value(title, value))
                        .foregroundStyle(color)
                        .interpolationMethod(.monotone)
                }
                RuleMark(x: .value("Контакт", stroke.contactTime))
                    .foregroundStyle(.orange)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("контакт").font(.caption2).foregroundStyle(.orange)
                    }
                RuleMark(x: .value("Конец замаха", analysis.signals.times[stroke.phases.transition]))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            .frame(height: 160)
            .chartXAxisLabel("с")
        }
    }
}

private struct MetricRow: View {
    let key: MetricKey
    let value: Double
    let sessionMean: Double
    let band: ClosedRange<Double>?
    let disabledReason: String?

    @State private var showsHint = false

    private var delta: Double { value - sessionMean }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(key.title).font(.subheadline)
                Button {
                    showsHint.toggle()
                } label: {
                    Image(systemName: "questionmark.circle").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                if disabledReason != nil {
                    Text("не в этом ракурсе")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text(Format.valueWithUnit(value, key: key))
                        .font(.subheadline.monospacedDigit().weight(.medium))
                }

                if disabledReason == nil, delta.isFinite, abs(delta) > 0 {
                    Text(String(format: "%@%.\(key.fractionDigits)f", delta > 0 ? "+" : "−", abs(delta)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                }
            }
            if let disabledReason {
                Text(disabledReason)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 40)
            }
            if showsHint {
                Text(key.hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 40)
                if let band {
                    Text("Ориентир из тренерской практики: \(Format.value(band.lowerBound, key: key))–\(Format.value(band.upperBound, key: key)) \(key.unit).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
