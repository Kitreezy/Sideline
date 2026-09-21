import PhotosUI
import StrokeKit
import SwiftUI

struct RootView: View {
    @State private var store = AnalysisStore()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Sideline")
                .navigationBarTitleDisplayMode(.inline)
                // Результаты — отдельный экран: назад возвращает к списку
                // тренировок, а не заставляет разбирать видео заново.
                .navigationDestination(isPresented: Binding(
                    get: { store.isShowingResults },
                    set: { store.isShowingResults = $0 }
                )) {
                    ResultsScreen(store: store)
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .idle, .ready:
            ImportScreen(store: store)
        case .working(let work):
            WorkingScreen(work: work) { store.reset() }
        case .failed(let message):
            FailureScreen(message: message) { store.reset() }
        }
    }
}

struct ImportScreen: View {
    @Bindable var store: AnalysisStore
    @State private var pickerItem: PhotosPickerItem?
    @State private var loadError: String?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Сними серию ударов и посмотри, что у тебя гуляет от удара к удару.")
                        .font(.title3.weight(.medium))
                    Text("Видео не покидает телефон — скелет считается локально.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

                Picker("Бьющая рука", selection: $store.handedness) {
                    ForEach(Handedness.allCases, id: \.self) { hand in
                        Text(hand.title).tag(hand)
                    }
                }
                .pickerStyle(.segmented)

                PhotosPicker(selection: $pickerItem, matching: .videos) {
                    Label("Выбрать видео", systemImage: "video.badge.waveform")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)

                if let loadError {
                    Text(loadError).font(.footnote).foregroundStyle(.red)
                }
            }

            if let pending = store.pending {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Разбор не был закончен", systemImage: "exclamationmark.triangle")
                            .font(.subheadline.weight(.medium))
                        Text("Видео от \(pending.info.startedAt.formatted(date: .abbreviated, time: .shortened)) уже скопировано, осталось разобрать.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Продолжить") { store.resumePending() }
                                .buttonStyle(.borderedProminent)
                            Button("Удалить", role: .destructive) { store.discardPending() }
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            if !store.savedSessions.isEmpty {
                Section {
                    ForEach(store.savedSessions) { session in
                        Button { store.open(session) } label: {
                            SessionRow(session: session)
                        }
                        .foregroundStyle(.primary)
                    }
                    .onDelete { offsets in
                        for index in offsets { store.delete(store.savedSessions[index]) }
                    }
                } header: {
                    Text("Тренировки")
                } footer: {
                    Text("Видео занимают \(ByteCountFormatter.string(fromByteCount: store.storageBytes, countStyle: .file)). Смахни влево, чтобы удалить вместе с видео.")
                }
            }

            Section {
                NavigationLink {
                    FramingScreen()
                } label: {
                    Label("Проверить кадр перед съёмкой", systemImage: "viewfinder")
                }
                NavigationLink {
                    CameraProbeScreen()
                } label: {
                    Label("Что тянет камера этого телефона", systemImage: "gauge.with.needle")
                }
            }

            Section("Как снимать") {
                ShootingTips()
            }

            #if DEBUG
            Section {
                Button("Демо-тренировка из синтетики") { store.createDemoSession() }
                    .font(.footnote)
            } footer: {
                Text("Только в отладочной сборке: в симуляторе Vision не работает.")
            }
            #endif
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            loadError = nil
            store.analyze(item: item)
            pickerItem = nil
        }
        .onAppear { store.reloadSessions() }
    }
}

private struct SessionRow: View {
    let session: SavedSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(Format.strokeCount(session.strokeCount))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text(breakdown)
                Text("·")
                Text(String(format: "%.0f с", session.duration))
                Text("·")
                Text(session.cameraView.title.lowercased())
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var breakdown: String {
        let parts = StrokeType.allCases.compactMap { type -> String? in
            guard let count = session.typeCounts[type.rawValue], count > 0 else { return nil }
            return "\(type.title.lowercased()) \(count)"
        }
        return parts.isEmpty ? "ударов нет" : parts.joined(separator: ", ")
    }
}

private struct ShootingTips: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            tip("Камеру сбоку, примерно на высоте пояса, игрок целиком в кадре.")
            tip("Слоу-мо 120 или 240 fps. На обычных 30 fps момент контакта размазывается на треть кадра.")
            tip("15–20 ударов подряд. На пяти разброс ещё ничего не значит.")
            tip("Телефон неподвижно — на треноге или на сумке. Дрожь руки уедет в цифры.")
        }
    }

    private func tip(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill").font(.system(size: 5)).padding(.top, 6)
            Text(text).font(.subheadline)
        }
        .foregroundStyle(.secondary)
    }
}

struct WorkingScreen: View {
    let work: AnalysisStore.Work
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            ProgressView(value: work.fraction)
                .progressViewStyle(.linear)
                .animation(.easeOut(duration: 0.3), value: work.fraction)

            Text(work.stage.title)
                .font(.headline)
                .contentTransition(.numericText())

            HStack(spacing: 12) {
                Text("\(Int(work.fraction * 100))%")
                    .font(.system(.title2, design: .rounded))
                    .monospacedDigit()
                if let remaining = work.remaining, remaining > 1 {
                    Text("· осталось \(Self.format(remaining))")
                        .font(.subheadline)
                        .monospacedDigit()
                }
            }
            .foregroundStyle(.secondary)

            Text("Экран не погаснет. Не сворачивай надолго: через полминуты в фоне iOS остановит разбор.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Button("Отменить", action: onCancel)
                .buttonStyle(.bordered)
        }
        .padding(40)
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) с" }
        return "\(total / 60) мин \(total % 60) с"
    }
}

struct FailureScreen: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(message).multilineTextAlignment(.center)
            Button("Попробовать другое видео", action: onRetry)
                .buttonStyle(.borderedProminent)
        }
        .padding(40)
    }
}

/// PhotosPicker отдаёт файл во временном месте, которое живёт недолго,
/// поэтому копируем к себе до того, как начнём читать.
struct MovieFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = URL.temporaryDirectory.appending(
                path: "stroke-\(UUID().uuidString).\(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)"
            )
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return MovieFile(url: copy)
        }
    }
}
