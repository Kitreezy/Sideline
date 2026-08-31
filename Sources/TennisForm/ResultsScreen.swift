import StrokeKit
import SwiftUI

struct ResultsScreen: View {
    let analysis: SessionAnalysis
    let videoURL: URL
    let onReset: () -> Void

    var body: some View {
        List {
            Section {
                LabeledContent("Ракурс", value: analysis.cameraView.title)
                LabeledContent("Найдено", value: Format.strokeCount(analysis.strokes.count))
            }

            if !analysis.warnings.isEmpty {
                Section("Как это читать") {
                    ForEach(analysis.warnings) { warning in
                        Label {
                            Text(warning.text).font(.footnote)
                        } icon: {
                            Image(systemName: "info.circle").foregroundStyle(.orange)
                        }
                    }
                }
            }

            if analysis.strokes.isEmpty {
                Section {
                    ContentUnavailableView(
                        "Ударов не нашлось",
                        systemImage: "figure.tennis",
                        description: Text("Кисть нигде не разгоняется достаточно, чтобы это было похоже на удар. Проверь, что игрок целиком в кадре и что выбрана правильная бьющая рука.")
                    )
                }
            } else {
                ForEach(analysis.presentTypes, id: \.self) { type in
                    typeSection(type)
                }

                if !analysis.disabledMetrics.isEmpty {
                    Section {
                        ForEach(analysis.disabledMetrics, id: \.self) { key in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(key.title).font(.subheadline)
                                if let reason = key.unreliabilityReason(in: analysis.cameraView) {
                                    Text(reason).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("Не считалось в этом ракурсе")
                    } footer: {
                        Text("Эти метрики требуют съёмки сбоку. Показать их сейчас значило бы показать число, которое меряет не то, что написано.")
                    }
                }

                Section("Все удары") {
                    ForEach(analysis.strokes) { stroke in
                        NavigationLink {
                            StrokeDetailScreen(
                                analysis: analysis, stroke: stroke, videoURL: videoURL
                            )
                        } label: {
                            StrokeRow(stroke: stroke)
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Новое видео", action: onReset)
            }
        }
    }

    @ViewBuilder
    private func typeSection(_ type: StrokeType) -> some View {
        let strokes = analysis.strokes(of: type)
        Section {
            if strokes.count < 2 {
                Text("Один удар — сравнивать не с чем.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(analysis.ranked(of: type).prefix(4)) { summary in
                    InstabilityRow(summary: summary)
                }
            }
        } header: {
            Text("\(type.title) — \(Format.strokeCount(strokes.count))")
        } footer: {
            if type == .unknown {
                Text("Удары, у которых не удалось определить тип: разворот корпуса в кадре неоднозначный.")
            } else if strokes.count >= 2 {
                Text("Сравнение идёт только с тобой же, внутри одного типа удара.")
            }
        }
    }
}

private struct InstabilityRow: View {
    let summary: MetricSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(summary.key.title).font(.subheadline.weight(.medium))
                Spacer()
                Text("±\(Format.value(summary.standardDeviation, key: summary.key)) \(summary.key.unit)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geometry in
                let fill = min(1, max(0.02, summary.instability / 3))
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(summary.instability > 1 ? Color.orange : Color.green)
                        .frame(width: geometry.size.width * fill)
                }
            }
            .frame(height: 6)

            HStack(spacing: 4) {
                Text("в среднем \(Format.valueWithUnit(summary.mean, key: summary.key))")
                if let range = summary.range, range.lowerBound.isFinite {
                    Text("· от \(Format.value(range.lowerBound, key: summary.key)) до \(Format.value(range.upperBound, key: summary.key))")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct StrokeRow: View {
    let stroke: Stroke

    var body: some View {
        HStack {
            Text("#\(stroke.id + 1)")
                .font(.headline.monospacedDigit())
                .frame(width: 36, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(stroke.type.title)
                        .font(.subheadline.weight(.medium))
                    Text(Format.time(stroke.contactTime))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("скорость \(Format.valueWithUnit(stroke.value(.peakWristSpeed), key: .peakWristSpeed)) · локоть \(Format.valueWithUnit(stroke.value(.elbowAtContact), key: .elbowAtContact))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
