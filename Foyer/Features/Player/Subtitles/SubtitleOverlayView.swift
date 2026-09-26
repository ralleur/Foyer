import SwiftUI
import Combine
import PlaybackDecision

/// Renders active text cues. Polls the engine clock at 10 Hz while playing so timing
/// is tight without burdening the coordinator's observation graph.
struct NativeSubtitleOverlay: View {
    let engine: NativePlaybackEngine

    var body: some View {
        SubtitleCueView(timelineProvider: { engine.subtitleTimelineProvider?() },
                        timeProvider: { engine.currentTime - engine.subtitleDelay },
                        isPlaying: { engine.isPlaying },
                        scale: engine.subtitleScale,
                        bottomInset: engine.transportBarVisible ? 230 : 90)
    }
}

struct SubtitleCueView: View {
    let timelineProvider: () -> SubtitleTimeline?
    let timeProvider: () -> TimeInterval
    let isPlaying: () -> Bool
    var scale: Double = 1
    var bottomInset: CGFloat = 90

    @State private var cues: [SubtitleCue] = []
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

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
