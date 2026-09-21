import StrokeKit
import SwiftUI

struct ResultsScreen: View {
    let analysis: SessionAnalysis
    let videoURL: URL
    let onSetRejected: (Stroke, Bool) -> Void
    let onReset: () -> Void

    var body: some View {
        List {
            Section {
                LabeledContent("Ракурс", value: analysis.cameraView.title)
                LabeledContent("Ударов", value: Format.strokeCount(analysis.acceptedStrokes.count))
                if analysis.ballConfirmedCount > 0 {
                    LabeledContent("Подтверждено мячом", value: "\(analysis.ballConfirmedCount)")
                }
                if !analysis.rejectedStrokes.isEmpty {
                    LabeledContent("Отсеяно", value: Format.strokeCount(analysis.rejectedStrokes.count))
                }
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

            if analysis.acceptedStrokes.isEmpty {
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

                Section {
                    ForEach(analysis.acceptedStrokes) { stroke in
                        NavigationLink {
                            StrokeDetailScreen(
                                analysis: analysis, stroke: stroke, videoURL: videoURL,
                                onSetRejected: onSetRejected
                            )
                        } label: {
                            StrokeRow(stroke: stroke, videoURL: videoURL)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Не удар", role: .destructive) { onSetRejected(stroke, true) }
                        }
                    }
                } header: {
                    Text("Удары")
                } footer: {
                    if analysis.ballConfirmedCount >= 5 {
                        Text("Зелёный мяч — контакт измерен по мячу. Всё, что мяч не подтвердил, ждёт в разделе «на проверку».")
                    } else if analysis.ballConfirmedCount > 0 {
                        Text("Зелёный мяч — контакт измерен по мячу. Оранжевый знак — удар найден по движению кисти, мяч у ракетки не пойман: посмотри кадр и, если это не удар, смахни влево.")
                    } else {
                        Text("Мяч у ракетки не пойман ни разу — удары найдены по движению кисти. Посмотри кадры и смахни влево то, что не удар.")
                    }
                }
            }

            if !analysis.rejectedStrokes.isEmpty {
                Section {
                    ForEach(analysis.rejectedStrokes) { stroke in
                        NavigationLink {
                            StrokeDetailScreen(
                                analysis: analysis, stroke: stroke, videoURL: videoURL,
                                onSetRejected: onSetRejected
                            )
                        } label: {
                            RejectedRow(stroke: stroke, videoURL: videoURL)
                        }
                        .swipeActions(edge: .leading) {
                            Button("Это удар") { onSetRejected(stroke, false) }
                                .tint(.green)
                        }
                    }
                } header: {
                    Text(analysis.ballConfirmedCount >= 5
                         ? "На проверку — \(analysis.rejectedStrokes.count)"
                         : "Похоже, не удары — \(analysis.rejectedStrokes.count)")
                } footer: {
                    Text(analysis.ballConfirmedCount >= 5
                         ? "Мяч на этой записи ловится, а у этих взмахов не пойман: чаще всего это не удары, но не всегда. В статистику они не идут. Посмотри кадр — если удар, смахни вправо."
                         : "Всплески скорости кисти без формы удара: сплит-степ, перехват ракетки, подбор мяча. В статистику не идут. Если это всё-таки удар — смахни вправо или открой и верни.")
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
        let insights = InsightEngine.insights(for: analysis, type: type)
        let strength = InsightEngine.strength(for: analysis, type: type)

        Section {
            if strokes.count < InsightEngine.minStrokes {
                Text("Нужно хотя бы \(InsightEngine.minStrokes) ударов, чтобы делать выводы. Сейчас \(strokes.count).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if insights.isEmpty {
                Label("Ничего заметного: разброс небольшой, ориентиры в норме.", systemImage: "checkmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            } else {
                ForEach(insights) { insight in
                    InsightRow(insight: insight)
                }
            }
            if let strength {
                InsightRow(insight: strength)
            }
        } header: {
            Text("\(type.title) — \(Format.strokeCount(strokes.count)) · над чем работать")
        } footer: {
            if type == .unknown {
                Text("Удары, у которых не удалось определить тип: разворот корпуса в кадре неоднозначный.")
            } else if strokes.count >= InsightEngine.minStrokes {
                Text("Ориентиры — из тренерской практики, не измеренная норма. Разброс и «лучшие против худших» — сравнение только с тобой же.")
            }
        }

        if strokes.count >= 2 {
            Section("\(type.title) — все метрики по разбросу") {
                ForEach(analysis.ranked(of: type)) { summary in
                    InstabilityRow(summary: summary, type: type)
                }
            }
        }
    }
}

private struct InsightRow: View {
    let insight: Insight

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(insight.title)
                    .font(.subheadline.weight(.semibold))
            }
            Text(insight.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let cue = insight.cue {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "figure.tennis")
                        .font(.caption)
                    Text(cue)
                        .font(.caption)
                }
                .foregroundStyle(.primary)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.vertical, 4)
    }

    private var icon: String {
        switch insight.kind {
        case .spread: return "waveform.path.ecg"
        case .shortfall: return "arrow.down.right.circle"
        case .bestVsWorst: return "arrow.left.arrow.right.circle"
        case .strength: return "checkmark.circle.fill"
        }
    }

    private var color: Color {
        insight.kind == .strength ? .green : .orange
    }
}

private struct InstabilityRow: View {
    let summary: MetricSummary
    let type: StrokeType

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
                if let band = summary.key.guidance(for: type).band {
                    Text("· ориентир \(Format.value(band.lowerBound, key: summary.key))–\(Format.value(band.upperBound, key: summary.key))")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct RejectedRow: View {
    let stroke: Stroke
    let videoURL: URL

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ContactThumbnail(videoURL: videoURL, time: stroke.contactTime)
                .opacity(0.6)
            VStack(alignment: .leading, spacing: 2) {
                Text(Format.time(stroke.contactTime)).font(.subheadline)
                Text(stroke.doubts.isEmpty
                     ? "Отмечен как не удар вручную"
                     : stroke.doubts.map(\.title).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct StrokeRow: View {
    let stroke: Stroke
    let videoURL: URL

    var body: some View {
        HStack(spacing: 10) {
            ContactThumbnail(videoURL: videoURL, time: stroke.contactTime)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(stroke.type.title)
                        .font(.subheadline.weight(.medium))
                    Text(Format.time(stroke.contactTime))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if stroke.ballContact != nil {
                        Image(systemName: "tennisball.fill").foregroundStyle(.green)
                    } else {
                        Image(systemName: "questionmark.circle").foregroundStyle(.orange)
                    }
                }
                Text("скорость \(Format.valueWithUnit(stroke.value(.peakWristSpeed), key: .peakWristSpeed)) · локоть \(Format.valueWithUnit(stroke.value(.elbowAtContact), key: .elbowAtContact))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
