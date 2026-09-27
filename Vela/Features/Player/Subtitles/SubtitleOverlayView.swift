import SwiftUI
import Combine
import PlaybackDecision

/// Renders active text cues. Polls the engine clock at 10 Hz while playing so timing
/// is tight without burdening the coordinator's observation graph.
struct NativeSubtitleOverlay: View {
    let engine: NativePlaybackEngine

    var body: some View {
        ZStack {
            BitmapSubtitleView(sourceProvider: { engine.bitmapSubtitle },
                               timeProvider: { engine.currentTime - engine.subtitleDelay })
            SubtitleCueView(timelineProvider: { engine.subtitleTimelineProvider?() },
                            timeProvider: { engine.currentTime - engine.subtitleDelay },
                            isPlaying: { engine.isPlaying },
                            scale: engine.subtitleScale,
                            bottomInset: engine.transportBarVisible ? 230 : 90)
        }
    }
}

struct SubtitleCueView: View {
    let timelineProvider: () -> SubtitleTimeline?
    let timeProvider: () -> TimeInterval
    let isPlaying: () -> Bool
    var scale: Double = 1
    var bottomInset: CGFloat = 90

    @State private var cues: [SubtitleCue] = []
    let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            let bottom = cues.filter { !$0.isTop }
            let top = cues.filter { $0.isTop }
            if !top.isEmpty {
                VStack { cueText(top); Spacer() }
                    .padding(.top, 80)
            }
            if !bottom.isEmpty {
                VStack { Spacer(); cueText(bottom) }
                    .padding(.bottom, bottomInset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .onReceive(timer) { _ in refresh() }
        .onAppear(perform: refresh)
        .animation(.linear(duration: 0.08), value: cues)
    }

    private func refresh() {
        guard let timeline = timelineProvider() else {
            if !cues.isEmpty { cues = [] }
            return
        }
        let active = timeline.activeCues(at: timeProvider())
        if active != cues { cues = active }
    }

    private func cueText(_ cues: [SubtitleCue]) -> some View {
        Text(attributed(cues))
            .font(.system(size: 44 * scale, weight: .medium))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineSpacing(6)
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.45)))
            .shadow(color: .black.opacity(0.9), radius: 3, x: 0, y: 1)
            .frame(maxWidth: 1500)
            .accessibilityLabel(cues.map(\.text).joined(separator: " "))
    }

    /// Supports the `<i>` markers kept by the parser.
    private func attributed(_ cues: [SubtitleCue]) -> AttributedString {
        var result = AttributedString()
        for (index, cue) in cues.enumerated() {
            if index > 0 { result += AttributedString("\n") }
            var remaining = Substring(cue.text)
            var italic = false
            while let range = remaining.range(of: #"</?i>"#, options: .regularExpression) {
                let chunk = String(remaining[remaining.startIndex..<range.lowerBound])
                if !chunk.isEmpty {
                    var piece = AttributedString(chunk)
                    if italic { piece.font = .system(size: 44 * scale, weight: .medium).italic() }
                    result += piece
                }
                italic = remaining[range] == "<i>"
                remaining = remaining[range.upperBound...]
            }
            if !remaining.isEmpty {
                var piece = AttributedString(String(remaining))
                if italic { piece.font = .system(size: 44 * scale, weight: .medium).italic() }
                result += piece
            }
        }
        return result
    }
}

/// Draws decoded bitmap subtitles (PGS/VobSub) over the system player. The subtitle canvas (usually the
/// video frame size) is fitted into the overlay like the video itself, so positions match the picture.
struct BitmapSubtitleView: View {
    let sourceProvider: () -> EmbeddedSubtitleSource?
    let timeProvider: () -> TimeInterval

    @State private var frame: BitmapSubtitleFrame?
    let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if let frame, frame.canvasWidth > 0, frame.canvasHeight > 0 {
                    let rect = fitted(canvas: CGSize(width: frame.canvasWidth, height: frame.canvasHeight), into: geometry.size)
                    let scale = rect.width / CGFloat(frame.canvasWidth)
                    ForEach(Array(frame.images.enumerated()), id: \.offset) { _, image in
                        Image(decorative: image.image, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                            .offset(x: rect.minX + CGFloat(image.x) * scale, y: rect.minY + CGFloat(image.y) * scale)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
        .onReceive(timer) { _ in
            let next = sourceProvider()?.frame(at: timeProvider())
            if next?.start != frame?.start || (next == nil) != (frame == nil) { frame = next }
        }
    }

    private func fitted(canvas: CGSize, into size: CGSize) -> CGRect {
        let scale = min(size.width / canvas.width, size.height / canvas.height)
        let width = canvas.width * scale, height = canvas.height * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }
}
