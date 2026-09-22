import AVFoundation
import StrokeKit
import SwiftUI

/// Проверка кадра до начала съёмки. Самая обидная потеря — отснять серию
/// и только дома увидеть, что ноги за кадром.
struct FramingScreen: View {
    @State private var camera = LivePoseCamera()

    var body: some View {
        VStack(spacing: 0) {
            preview
            verdict
        }
        .navigationTitle("Проверка кадра")
        .navigationBarTitleDisplayMode(.inline)
        .task { await camera.start() }
        .onDisappear { camera.stop() }
    }

    private var preview: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                CameraPreview(session: camera.session)

                if let frame = camera.latestFrame, camera.frameSize.width > 0 {
                    let rect = SkeletonVideoView.aspectFitRect(
                        content: camera.frameSize, in: geometry.size
                    )
                    SkeletonCanvas(frame: frame, displaySize: camera.frameSize, videoRect: rect)
                }

                switch camera.state {
                case .starting:
                    ProgressView().tint(.white)
                case .denied:
                    message("Нет доступа к камере. Включи его в настройках телефона.")
                case .failed(let text):
                    message(text)
                default:
                    EmptyView()
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding()
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            .padding()
    }

    @ViewBuilder
    private var verdict: some View {
        if let report = camera.report {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: report.canRecord ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(report.canRecord ? .green : .orange)
                    Text(report.canRecord ? "Можно снимать" : "Кадр надо поправить")
                        .font(.headline)
                }

                ForEach(report.checks) { check in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(color(for: check.status))
                            .frame(width: 8, height: 8)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(check.title).font(.subheadline.weight(.medium))
                            Text(check.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.bar)
        }
    }

    private func color(for status: FramingCheck.Status) -> Color {
        switch status {
        case .ok: return .green
        case .warning: return .orange
        case .problem: return .red
        }
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewContainer {
        let view = PreviewContainer()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PreviewContainer, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
    }

    final class PreviewContainer: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
