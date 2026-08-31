import PhotosUI
import StrokeKit
import SwiftUI

struct RootView: View {
    @State private var store = AnalysisStore()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Разбор удара")
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .idle:
            ImportScreen(store: store)
        case .working(let stage, let progress):
            WorkingScreen(stage: stage, progress: progress) { store.reset() }
        case .ready(let analysis, let url):
            ResultsScreen(analysis: analysis, videoURL: url) { store.reset() }
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
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Сними серию ударов и посмотри, что у тебя гуляет от удара к удару.")
                        .font(.title3.weight(.medium))
                    Text("Видео не покидает телефон — скелет считается локально.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Бьющая рука").font(.headline)
                    Picker("Бьющая рука", selection: $store.handedness) {
                        ForEach(Handedness.allCases, id: \.self) { hand in
                            Text(hand.title).tag(hand)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                PhotosPicker(selection: $pickerItem, matching: .videos) {
                    Label("Выбрать видео", systemImage: "video.badge.waveform")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)

                if let loadError {
                    Text(loadError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                ShootingTips()

                NavigationLink {
                    FramingScreen()
                } label: {
                    Label("Проверить кадр перед съёмкой", systemImage: "viewfinder")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)

                NavigationLink {
                    CameraProbeScreen()
                } label: {
                    Label("Что тянет камера этого телефона", systemImage: "gauge.with.needle")
                        .font(.footnote)
                }
            }
            .padding()
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                do {
                    guard let movie = try await item.loadTransferable(type: MovieFile.self) else {
                        loadError = "Не получилось прочитать этот файл."
                        return
                    }
                    loadError = nil
                    store.analyze(url: movie.url)
                } catch {
                    loadError = error.localizedDescription
                }
            }
        }
    }
}

private struct ShootingTips: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Как снимать").font(.headline)
            tip("Камеру сбоку, примерно на высоте пояса, игрок целиком в кадре.")
            tip("Слоу-мо 120 или 240 fps. На обычных 30 fps момент контакта размазывается на треть кадра.")
            tip("15–20 ударов подряд. На пяти разброс ещё ничего не значит.")
            tip("Телефон неподвижно — на треноге или на сумке. Дрожь руки уедет в цифры.")
        }
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
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
    let stage: String
    let progress: Double
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
            Text(stage).font(.headline)
            Text("\(Int(progress * 100))%")
                .font(.system(.title2, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button("Отменить", action: onCancel)
                .buttonStyle(.bordered)
        }
        .padding(40)
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
