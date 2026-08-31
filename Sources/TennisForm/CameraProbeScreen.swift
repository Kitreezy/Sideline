import SwiftUI

struct CameraProbeScreen: View {
    @State private var probe = CameraProbe()

    var body: some View {
        List {
            Section {
                Text("Проверяет, потянет ли этот телефон запись на высокой частоте кадров одновременно с живым разбором позы. Займёт около 15 секунд: камера включится дважды.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                switch probe.state {
                case .idle:
                    Button("Запустить проверку") { probe.run() }
                case .running(let stage):
                    HStack {
                        ProgressView()
                        Text(stage).font(.subheadline)
                    }
                case .done:
                    Button("Прогнать ещё раз") { probe.run() }
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            if !probe.lines.isEmpty {
                Section("Что намерено") {
                    ForEach(probe.lines) { line in
                        HStack(alignment: .top) {
                            Image(systemName: icon(for: line.verdict))
                                .foregroundStyle(color(for: line.verdict))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.title).font(.subheadline)
                                Text(line.value)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Что тянет камера")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func icon(for verdict: CameraProbe.Line.Verdict) -> String {
        switch verdict {
        case .good: return "checkmark.circle.fill"
        case .bad: return "xmark.circle.fill"
        case .neutral: return "info.circle"
        }
    }

    private func color(for verdict: CameraProbe.Line.Verdict) -> Color {
        switch verdict {
        case .good: return .green
        case .bad: return .red
        case .neutral: return .secondary
        }
    }
}
