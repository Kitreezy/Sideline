import AVFoundation
import SwiftUI

/// Кадр в момент контакта. Один взгляд на него отвечает на вопрос
/// «удар это или нет» быстрее любой метрики — поэтому он в каждой строке.
struct ContactThumbnail: View {
    let videoURL: URL
    let time: TimeInterval
    /// Область вокруг игрока в пикселях видео. Без неё — весь кадр.
    var crop: CGRect? = nil

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
        .task(id: time) { image = await Self.frame(in: videoURL, at: time, crop: crop) }
    }

    private static func frame(in url: URL, at time: TimeInterval, crop: CGRect?) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Для кадрирования нужен кадр покрупнее: из 240 px игрока не вырезать.
        generator.maximumSize = crop == nil ? CGSize(width: 240, height: 240) : CGSize(width: 1080, height: 1080)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
        guard let full = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image else {
            return nil
        }
        guard let crop, let track = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform)
        else { return full }

        // Область задана в пикселях повёрнутого видео; сгенерированный кадр
        // может быть уменьшен — пересчитываем.
        let rotated = abs(transform.b) == 1
        let displayWidth = rotated ? natural.height : natural.width
        let scale = CGFloat(full.width) / displayWidth
        let scaled = CGRect(
            x: crop.minX * scale, y: crop.minY * scale,
            width: crop.width * scale, height: crop.height * scale
        ).integral
        return full.cropping(to: scaled) ?? full
    }
}
