import SwiftUI

private struct ImagePipelineKey: EnvironmentKey {
    static let defaultValue = ImagePipeline()
}

extension EnvironmentValues {
    var imagePipeline: ImagePipeline {
        get { self[ImagePipelineKey.self] }
        set { self[ImagePipelineKey.self] = newValue }
    }
}

/// Cached, downsampled remote image with a quiet placeholder and fade-in.
struct RemoteImage<Placeholder: View>: View {
    let url: URL?
    let targetSize: CGSize
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder

    @Environment(\.imagePipeline) private var pipeline
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(reduceMotion ? .identity : .opacity.animation(.easeOut(duration: 0.2)))
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            if let cached = pipeline.cachedImage(for: url, targetSize: targetSize) {
                image = cached
                return
            }
            image = nil
            failed = false
            do {
                let loaded = try await pipeline.image(for: url, targetSize: targetSize)
                guard !Task.isCancelled else { return }
                image = loaded
            } catch {
                failed = true
            }
        }
    }
}

extension RemoteImage where Placeholder == ImagePlaceholder {
    init(url: URL?, targetSize: CGSize, contentMode: ContentMode = .fill, systemImage: String = "film") {
        self.init(url: url, targetSize: targetSize, contentMode: contentMode) {
            ImagePlaceholder(systemImage: systemImage)
        }
    }
}

struct ImagePlaceholder: View {
    var systemImage: String = "film"

    var body: some View {
        ZStack {
            Rectangle().fill(Color.foyerSurface)
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.foyerSecondaryText.opacity(0.5))
        }
    }
}
