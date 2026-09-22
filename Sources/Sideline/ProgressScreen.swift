import Charts
import StrokeKit
import SwiftUI

/// Что менялось от тренировки к тренировке. Главный вопрос экрана —
/// не «какое число больше», а «отличима ли разница от случайной»:
/// разброс, посчитанный по восьми ударам, сам гуляет на четверть,
/// и без этой оговорки прогресс находился бы после каждой записи.
struct ProgressScreen: View {
    let store: AnalysisStore
    @State private var chosenType: StrokeType?

    var body: some View {
        let sessions = store.progressSessions
        let types = ProgressEngine.types(in: sessions)
        let type = chosenType.flatMap { types.contains($0) ? $0 : nil } ?? types.first

        List {
            if let rebuild = store.digestRebuild {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Считаю сводки прежних тренировок: \(rebuild.done) из \(rebuild.total)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let type {
                overview(sessions: sessions, type: type, types: types)
                let trends = ProgressEngine.trends(in: sessions, type: type)
                ForEach(trends) { trend in
                    Section {
                        TrendCard(trend: trend)
                    } header: {
                        Text(trend.key.title)
                    }
                }
                if trends.isEmpty {
                    Section {
                        Text("Ни одна метрика не набралась в двух тренировках сразу. Обычно дело в ракурсе: часть метрик меряется только при съёмке сбоку.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section {
                    ContentUnavailableView(
                        "Сравнивать пока не с чем",
                        systemImage: "chart.line.uptrend.xyaxis",
                        description: Text(emptyReason(sessions: sessions))
                    )
                }
            }
        }
        .navigationTitle("Прогресс")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.rebuildDigests() }
    }

    private func emptyReason(sessions: [ProgressSession]) -> String {
        if sessions.count < 2 {
            return "Нужны хотя бы две тренировки с одинаковым типом ударов. Сейчас их \(sessions.count)."
        }
        return "Ни один тип удара не набрал \(ProgressEngine.minStrokes) ударов хотя бы в двух тренировках. На меньшем числе ни среднее, ни разброс ничего не значат."
    }

    @ViewBuilder
    private func overview(sessions: [ProgressSession], type: StrokeType, types: [StrokeType]) -> some View {
        let counted = sessions
            .compactMap { $0.digest.type(type) }
            .filter { $0.strokeCount >= ProgressEngine.minStrokes }
        let views = Set(sessions.compactMap { session -> CameraView? in
            guard let digest = session.digest.type(type),
                  digest.strokeCount >= ProgressEngine.minStrokes else { return nil }
            return session.digest.cameraView
        })

        Section {
            if types.count > 1 {
                Picker("Тип удара", selection: Binding(
                    get: { type },
                    set: { chosenType = $0 }
                )) {
                    ForEach(types, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            LabeledContent("Тренировок в ряду", value: "\(counted.count)")
            LabeledContent(
                "Ударов всего",
                value: Format.strokeCount(counted.reduce(0) { $0 + $1.strokeCount })
            )
        } footer: {
            if views.count > 1 {
                Text("Ракурс между этими тренировками менялся: \(views.map { $0.title.lowercased() }.sorted().joined(separator: ", ")). Метрики, которые ракурс не даёт померить, в ряд не попали, но остальные сравнивай с оглядкой.")
            } else {
                Text("В ряд идут только тренировки, где этого удара набралось хотя бы \(ProgressEngine.minStrokes).")
            }
        }
    }
}

/// Одна метрика: график по тренировкам и выводы под ним.
private struct TrendCard: View {
    let trend: MetricTrend

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TrendChart(trend: trend)

            VerdictRow(change: trend.spread)
            VerdictRow(change: trend.mean)
            if let overall = trend.overall, overall.isCertain {
                VerdictRow(change: overall, prefix: "С первой тренировки")
            }

            Text(trend.key.hint)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }
}

private struct VerdictRow: View {
    let change: ProgressChange
    var prefix: String = ""

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.caption)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                if !prefix.isEmpty {
                    Text(prefix)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(change.sentence)
                    .font(.caption)
                    .foregroundStyle(change.isCertain ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var icon: String {
        switch change.verdict {
        case .improved: return "arrow.down.right.circle.fill"
        case .worsened: return "arrow.up.right.circle.fill"
        case .changed: return "arrow.left.arrow.right.circle"
        case .inconclusive: return "equal.circle"
        }
    }

    private var color: Color {
        switch change.verdict {
        case .improved: return .green
        case .worsened: return .orange
        case .changed: return .blue
        case .inconclusive: return .secondary
        }
    }
}

/// Точка — среднее, полоса вокруг неё — разброс внутри той тренировки.
/// Разброс здесь важнее среднего, поэтому он нарисован, а не подписан.
private struct TrendChart: View {
    let trend: MetricTrend

    private struct Item: Identifiable {
        let id: Int
        let label: String
        /// Время съёмки. Показывается, только когда одной даты мало:
        /// две тренировки в один день — это обычный день на корте.
        let time: String?
        /// Ось X вещественная: с целыми не задать поля по краям,
        /// и крайние точки обрезаются наполовину.
        var position: Double { Double(id) }
        let mean: Double
        let low: Double
        let high: Double
    }

    private var items: [Item] {
        let days = trend.points.map { Calendar.current.startOfDay(for: $0.date) }
        let sameDay = Set(days).count < days.count
        return trend.points.enumerated().map { index, point in
            Item(
                id: index,
                label: point.date.formatted(.dateTime.day().month(.twoDigits)),
                time: sameDay ? point.date.formatted(.dateTime.hour().minute()) : nil,
                mean: point.mean,
                low: point.mean - point.spread,
                high: point.mean + point.spread
            )
        }
    }

    /// Диапазон по данным, а не от нуля: ось от нуля до 200 ради углов
    /// около 130 прижимает весь ряд к одной линии.
    private var verticalRange: ClosedRange<Double> {
        let low = items.map(\.low).min() ?? 0
        let high = items.map(\.high).max() ?? 1
        let padding = max((high - low) * 0.12, max(abs(high), 1) * 0.05)
        return (low - padding)...(high + padding)
    }

    var body: some View {
        Chart(items) { item in
            RuleMark(
                x: .value("Тренировка", item.position),
                yStart: .value("Разброс", item.low),
                yEnd: .value("Разброс", item.high)
            )
            .foregroundStyle(.blue.opacity(0.25))
            .lineStyle(StrokeStyle(lineWidth: 10, lineCap: .round))

            LineMark(x: .value("Тренировка", item.position), y: .value("Среднее", item.mean))
                .foregroundStyle(.blue)

            PointMark(x: .value("Тренировка", item.position), y: .value("Среднее", item.mean))
                .foregroundStyle(.blue)
        }
        .chartXAxis {
            AxisMarks(values: items.map(\.position)) { value in
                AxisValueLabel {
                    if let position = value.as(Double.self),
                       items.indices.contains(Int(position.rounded())) {
                        let item = items[Int(position.rounded())]
                        VStack(spacing: 0) {
                            Text(item.label)
                            if let time = item.time { Text(time) }
                        }
                        .font(.caption2)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(trend.key.format(number)).font(.caption2)
                    }
                }
            }
        }
        .chartXScale(domain: -0.35...(Double(items.count) - 0.65))
        .chartYScale(domain: verticalRange)
        .frame(height: 130)
    }
}
