import AVFoundation
import SwiftUI

/// Кадр в момент контакта. Один взгляд на него отвечает на вопрос
/// «удар это или нет» быстрее любой метрики — поэтому он в каждой строке.
struct ContactThumbnail: View {
    let videoURL: URL
    let time: TimeInterval

    @State private var image: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: 56, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: time) { image = await Self.frame(in: videoURL, at: time) }
    }

    private static func frame(in url: URL, at time: TimeInterval) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
        return try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
    }
}
