import AVFoundation
import StrokeKit
import SwiftUI

/// Видео с наложенным скелетом того кадра, который сейчас выбран.
struct SkeletonVideoView: View {
    let videoURL: URL
    let track: PoseTrack
    let frameIndex: Int

    @State private var player = AVPlayer()
    @State private var isPrepared = false

    var body: some View {
        GeometryReader { geometry in
            let rect = Self.aspectFitRect(content: track.displaySize, in: geometry.size)
            ZStack(alignment: .topLeading) {
                Color.black
                PlayerLayerView(player: player)
                if track.frames.indices.contains(frameIndex) {
                    SkeletonCanvas(
                        frame: track.frames[frameIndex],
                        displaySize: track.displaySize,
                        videoRect: rect
                    )
                }
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task {
            guard !isPrepared else { return }
            isPrepared = true
            player.replaceCurrentItem(with: AVPlayerItem(url: videoURL))
            player.isMuted = true
            await seek(to: frameIndex)
        }
        .onChange(of: frameIndex) { _, newValue in
            Task { await seek(to: newValue) }
        }
    }

    private var aspectRatio: CGFloat {
        guard track.displaySize.height > 0 else { return 9.0 / 16 }
        return track.displaySize.width / track.displaySize.height
    }

    /// Точный поиск кадра: допуски по нулям, иначе плеер прыгает на ближайший
    /// ключевой кадр и скелет перестаёт совпадать с картинкой.
    private func seek(to index: Int) async {
        guard track.frames.indices.contains(index) else { return }
        let time = CMTime(seconds: track.frames[index].time, preferredTimescale: 600)
        await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    static func aspectFitRect(content: CGSize, in container: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0 else { return .zero }
        let scale = min(container.width / content.width, container.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}

private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerContainer {
        let view = PlayerContainer()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PlayerContainer, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }

    final class PlayerContainer: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

struct SkeletonCanvas: View {
    let frame: PoseFrame
    let displaySize: CGSize
    let videoRect: CGRect

    var body: some View {
        Canvas { context, _ in
            for (a, b) in skeletonBones {
                guard let pa = frame.point(a), let pb = frame.point(b) else { continue }
                var path = Path()
                path.move(to: map(pa))
                path.addLine(to: map(pb))
                context.stroke(path, with: .color(.green.opacity(0.85)), lineWidth: 2.5)
            }

            for joint in BodyJoint.allCases {
                guard let point = frame.point(joint) else { continue }
                let screen = map(point)
                let dot = Path(ellipseIn: CGRect(
                    x: screen.x - 3.5, y: screen.y - 3.5, width: 7, height: 7
                ))
                context.fill(dot, with: .color(.white))
            }
        }
        .allowsHitTesting(false)
    }

    private func map(_ point: CGPoint) -> CGPoint {
        guard displaySize.width > 0, displaySize.height > 0 else { return .zero }
        return CGPoint(
            x: videoRect.minX + point.x / displaySize.width * videoRect.width,
            y: videoRect.minY + point.y / displaySize.height * videoRect.height
        )
    }
}
