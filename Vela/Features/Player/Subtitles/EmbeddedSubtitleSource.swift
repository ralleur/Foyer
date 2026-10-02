import Foundation
import CoreGraphics
import VelaFoundation
import PlaybackDecision
import Libavformat
import Libavcodec
import Libavutil

/// One decoded bitmap placed on the subtitle canvas (PGS/VobSub coordinates, usually the video frame size).
struct BitmapSubtitleImage {
    let image: CGImage
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

/// What is on screen from `start` until `end` (or until the next frame when `end` is nil).
/// An empty `images` list clears the screen.
struct BitmapSubtitleFrame {
    let start: TimeInterval
    var end: TimeInterval?
    let images: [BitmapSubtitleImage]
    let canvasWidth: Int
    let canvasHeight: Int
}

/// Demuxes one embedded subtitle track from the original file with FFmpeg and decodes it ahead of the playback
/// clock so the native engine can draw it over AVPlayer: bitmap tracks (PGS, VobSub, DVB) as frames, text tracks
/// (SubRip, ASS, WebVTT) as cues. The file is read over HTTP with Range requests; every stream is read but only
/// the subtitle packets are decoded, so this costs about the file's bitrate on the network while playing (mostly
/// served from the server's cache, since its remux just read the same range). Seeks re-create the demuxer.
///
/// For text tracks this replaces Jellyfin's subtitle download, which first extracts every subtitle track by reading
/// the whole file: an hour for a 50 GB remux on a slow USB disk, starving the video stream meanwhile.
final class EmbeddedSubtitleSource: @unchecked Sendable {
    let url: URL
    let streamIndex: Int
    let language: String?

    /// How far ahead of the playhead the decoder runs before it waits. Kept short: the server reads the same
    /// file for its remux, and a long burst from a second reader can starve it on a slow disk.
    static let readAhead: TimeInterval = 40
    /// Frames older than this behind the playhead are dropped.
    static let keepBehind: TimeInterval = 20
    private static let averrorEOF: Int32 = -541_478_725 // FFERRTAG('E','O','F',' ')
    private static let noPTS = Int64.min // AV_NOPTS_VALUE
    private static let networkReady: Void = { avformat_network_init() }()

    private let condition = NSCondition()
    private var frames: [BitmapSubtitleFrame] = []
    private var decodedThrough: TimeInterval = 0
    private var playhead: TimeInterval = 0
    private var pendingSeek: TimeInterval?
    private var stopped = false
    private var started = false
    private var canvas = (width: 0, height: 0)
    private var failureText: String?
    private var decoded = 0
    private var cues: [SubtitleCue] = []
    private var cueKeys: Set<String> = []
    private var cueVersion = 0

    init(url: URL, streamIndex: Int, language: String?) {
        self.url = url
        self.streamIndex = streamIndex
        self.language = language
    }

    deinit { stop() }

    // MARK: Control (any thread)

    func start(at time: TimeInterval) {
        condition.lock()
        guard !started else { condition.unlock(); return }
        started = true
        playhead = time
        decodedThrough = time
        pendingSeek = time
        condition.unlock()
        let thread = Thread { [self] in self.run() }
        thread.name = "vela.embedded-subtitles"
        thread.qualityOfService = .utility
        thread.start()
    }

    func update(playhead time: TimeInterval) {
        condition.lock()
        playhead = time
        condition.broadcast()
        condition.unlock()
    }

    func seek(to time: TimeInterval) {
        condition.lock()
        pendingSeek = time
        playhead = time
        condition.broadcast()
        condition.unlock()
    }

    func stop() {
        condition.lock()
        stopped = true
        condition.broadcast()
        condition.unlock()
    }

    var isStopped: Bool {
        condition.lock(); defer { condition.unlock() }
        return stopped
    }

    var failure: String? {
        condition.lock(); defer { condition.unlock() }
        return failureText
    }

    var decodedFrameCount: Int {
        condition.lock(); defer { condition.unlock() }
        return decoded
    }

    /// Changes whenever text cues were added; compare to rebuild the timeline only when needed.
    var textCueVersion: Int {
        condition.lock(); defer { condition.unlock() }
        return cueVersion
    }

    /// All text cues decoded so far (kept across seeks; a film has a few thousand at most).
    var textTimeline: SubtitleTimeline {
        condition.lock(); defer { condition.unlock() }
        return SubtitleTimeline(cues: cues)
    }

    /// The frame to show at `time`, or nil when nothing is on screen (or not decoded yet).
    func frame(at time: TimeInterval) -> BitmapSubtitleFrame? {
        condition.lock(); defer { condition.unlock() }
        var low = 0, high = frames.count - 1, found = -1
        while low <= high {
            let mid = (low + high) / 2
            if frames[mid].start <= time { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        guard found >= 0 else { return nil }
        let frame = frames[found]
        if frame.images.isEmpty { return nil }
        if let end = frame.end, time >= end { return nil }
        return frame
    }

    // MARK: Decoder thread

    private static let interrupt: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { opaque in
        guard let opaque else { return 0 }
        return Unmanaged<EmbeddedSubtitleSource>.fromOpaque(opaque).takeUnretainedValue().isStopped ? 1 : 0
    }

    private func fail(_ message: String) {
        condition.lock()
        failureText = message
        condition.unlock()
        Log.warning(.subtitle, "Embedded subtitles #\(streamIndex): \(message)")
    }

    private func errorText(_ code: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        av_strerror(code, &buffer, buffer.count)
        return String(cString: buffer)
    }

    private enum SessionEnd { case stopped, reopen }

    private func run() {
        _ = Self.networkReady
        var attempts = 0
        while !isStopped {
            attempts += 1
            switch session() {
            case .stopped:
                return
            case .reopen:
                if attempts > 50 { fail("too many reopen attempts"); return }
                Log.debug(.subtitle, "Embedded subtitles #\(streamIndex): reopening the file")
            }
        }
    }

    /// One open/decode session. Returns `.reopen` when the demuxer should be re-created (every seek does that:
    /// reliable for all containers and protocols, and a fresh HTTP request from the right offset is cheap).
    private func session() -> SessionEnd {
        guard var format = avformat_alloc_context() else { fail("cannot allocate a format context"); return .stopped }
        format.pointee.interrupt_callback.callback = Self.interrupt
        format.pointee.interrupt_callback.opaque = Unmanaged.passUnretained(self).toOpaque()
        var options: OpaquePointer?
        av_dict_set(&options, "reconnect", "1", 0)
        av_dict_set(&options, "reconnect_streamed", "1", 0)
        av_dict_set(&options, "reconnect_on_network_error", "1", 0)
        av_dict_set(&options, "rw_timeout", "20000000", 0)
        av_dict_set(&options, "user_agent", "Vela", 0)
        // The container header already describes the tracks; do not probe frames of a 4K file over the network.
        av_dict_set(&options, "probesize", "2000000", 0)
        av_dict_set(&options, "analyzeduration", "500000", 0)
        var formatOptional: UnsafeMutablePointer<AVFormatContext>? = format
        var rc = avformat_open_input(&formatOptional, url.absoluteString, nil, &options)
        av_dict_free(&options)
        guard rc >= 0, let opened = formatOptional else { fail("open failed: \(errorText(rc))"); return .stopped }
        format = opened
        defer { avformat_close_input(&formatOptional) }

        let streamCount = Int(format.pointee.nb_streams)
        let headerKnowsCodec = streamIndex < streamCount
            && (format.pointee.streams[streamIndex]?.pointee.codecpar?.pointee.codec_id ?? AV_CODEC_ID_NONE) != AV_CODEC_ID_NONE
        if !headerKnowsCodec {
            rc = avformat_find_stream_info(format, nil)
            guard rc >= 0 else { fail("stream info failed: \(errorText(rc))"); return .stopped }
        }
        guard streamIndex < streamCount, let stream = format.pointee.streams[streamIndex], let parameters = stream.pointee.codecpar else {
            fail("stream #\(streamIndex) not found (\(streamCount) streams)"); return .stopped
        }
        guard parameters.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE, let codec = avcodec_find_decoder(parameters.pointee.codec_id) else {
            fail("no subtitle decoder for stream #\(streamIndex)"); return .stopped
        }
        let isText = (Int(avcodec_descriptor_get(parameters.pointee.codec_id)?.pointee.props ?? 0) & (1 << 17)) != 0 // AV_CODEC_PROP_TEXT_SUB
        guard let context = avcodec_alloc_context3(codec) else { fail("cannot allocate a decoder"); return .stopped }
        var contextOptional: UnsafeMutablePointer<AVCodecContext>? = context
        defer { avcodec_free_context(&contextOptional) }
        avcodec_parameters_to_context(context, parameters)
        context.pointee.pkt_timebase = stream.pointee.time_base
        rc = avcodec_open2(context, codec, nil)
        guard rc >= 0 else { fail("decoder open failed: \(errorText(rc))"); return .stopped }
        let timeBase = av_q2d(stream.pointee.time_base)
        var canvasSize = (width: Int(parameters.pointee.width), height: Int(parameters.pointee.height))
        if canvasSize.width == 0 {
            for i in 0..<streamCount {
                if let other = format.pointee.streams[i], let par = other.pointee.codecpar, par.pointee.codec_type == AVMEDIA_TYPE_VIDEO {
                    canvasSize = (Int(par.pointee.width), Int(par.pointee.height))
                    break
                }
            }
        }
        condition.lock(); canvas = canvasSize; condition.unlock()
        guard let packet = av_packet_alloc() else { fail("cannot allocate a packet"); return .stopped }
        var packetOptional: UnsafeMutablePointer<AVPacket>? = packet
        defer { av_packet_free(&packetOptional) }

        // Position the demuxer for the requested start; later seeks come back here through `.reopen`.
        condition.lock()
        let target = pendingSeek ?? playhead
        pendingSeek = nil
        frames.removeAll()
        decodedThrough = target
        condition.unlock()
        if target > 2 {
            let early = target - 2 // a little early so a subtitle already on screen is found
            if av_seek_frame(format, Int32(streamIndex), Int64(early / timeBase), AVSEEK_FLAG_BACKWARD) < 0,
               av_seek_frame(format, -1, Int64(early * Double(AV_TIME_BASE)), AVSEEK_FLAG_BACKWARD) < 0 {
                Log.notice(.subtitle, "Embedded subtitles #\(streamIndex): seek to \(target.clockString) failed; reading from the start")
            }
        }
        let codecName = String(cString: avcodec_get_name(parameters.pointee.codec_id))
        if isText {
            Log.info(.subtitle, "Embedded subtitles #\(streamIndex): decoding \(codecName) text from \(target.clockString)")
        } else {
            Log.info(.subtitle, "Embedded subtitles #\(streamIndex): decoding \(codecName) on a \(canvasSize.width)×\(canvasSize.height) canvas from \(target.clockString)")
        }

        var finished = false
        while true {
            condition.lock()
            if stopped { condition.unlock(); return .stopped }
            if pendingSeek != nil { condition.unlock(); return .reopen }
            if finished || decodedThrough > playhead + Self.readAhead {
                condition.wait(until: Date().addingTimeInterval(0.5))
                condition.unlock()
                continue
            }
            condition.unlock()

            rc = av_read_frame(format, packet)
            if rc < 0 {
                if rc == Self.averrorEOF { finished = true; continue }
                if isStopped { return .stopped }
                Log.notice(.subtitle, "Embedded subtitles #\(streamIndex): read failed (\(errorText(rc))); waiting for a seek")
                finished = true
                continue
            }
            let pts = packet.pointee.pts != Self.noPTS ? Double(packet.pointee.pts) * timeBase
                : (packet.pointee.dts != Self.noPTS ? Double(packet.pointee.dts) * timeBase : decodedThrough)
            if Int(packet.pointee.stream_index) == streamIndex {
                var subtitle = AVSubtitle()
                var got: Int32 = 0
                let decodedBytes = avcodec_decode_subtitle2(context, &subtitle, &got, packet)
                if decodedBytes >= 0, got != 0 {
                    let base = subtitle.pts != Self.noPTS ? Double(subtitle.pts) / Double(AV_TIME_BASE) : pts
                    let start = base + Double(subtitle.start_display_time) / 1000
                    let end: TimeInterval? = subtitle.end_display_time > 0 ? base + Double(subtitle.end_display_time) / 1000 : nil
                    if isText {
                        for i in 0..<Int(subtitle.num_rects) {
                            guard let rect = subtitle.rects[i]?.pointee else { continue }
                            let raw = rect.type == SUBTITLE_ASS ? rect.ass : (rect.type == SUBTITLE_TEXT ? rect.text : nil)
                            guard let raw, let cue = SubtitleParser.cue(fromDecoderEvent: String(cString: raw), id: 0, start: start, end: end ?? start + 4) else { continue }
                            appendText(cue)
                        }
                        avsubtitle_free(&subtitle)
                        av_packet_unref(packet)
                        condition.lock()
                        if pts > decodedThrough { decodedThrough = pts }
                        condition.unlock()
                        continue
                    }
                    var images: [BitmapSubtitleImage] = []
                    for i in 0..<Int(subtitle.num_rects) {
                        if let rect = subtitle.rects[i], let image = Self.makeImage(rect.pointee) { images.append(image) }
                    }
                    if context.pointee.width > 0 { canvasSize = (Int(context.pointee.width), Int(context.pointee.height)) }
                    append(BitmapSubtitleFrame(start: start, end: end, images: images, canvasWidth: canvasSize.width, canvasHeight: canvasSize.height))
                    avsubtitle_free(&subtitle)
                }
            }
            av_packet_unref(packet)
            condition.lock()
            if pts > decodedThrough { decodedThrough = pts }
            canvas = canvasSize
            let cutoff = playhead - Self.keepBehind
            if frames.count > 2, let keepFrom = frames.lastIndex(where: { $0.start <= cutoff }), keepFrom > 0 {
                frames.removeFirst(keepFrom)
            }
            condition.unlock()
        }
    }

    private func append(_ frame: BitmapSubtitleFrame) {
        condition.lock()
        if let last = frames.indices.last, frames[last].end == nil || frames[last].end! > frame.start {
            frames[last].end = frame.start
        }
        frames.append(frame)
        decoded += 1
        let count = decoded
        condition.unlock()
        if count == 1 || count % 200 == 0 {
            Log.info(.subtitle, "Embedded subtitles #\(streamIndex): \(count) frames decoded, latest at \(frame.start.clockString) (\(frame.images.count) images)")
        }
    }

    /// Text cues survive seeks, so a cue decoded twice (re-read after a seek) is added once.
    private func appendText(_ cue: SubtitleCue) {
        let key = "\(Int(cue.start * 1000))|\(cue.text)"
        condition.lock()
        guard cueKeys.insert(key).inserted else { condition.unlock(); return }
        cues.append(SubtitleCue(id: cues.count, start: cue.start, end: cue.end, text: cue.text, isTop: cue.isTop))
        cueVersion += 1
        decoded += 1
        let count = decoded
        condition.unlock()
        if count == 1 || count % 200 == 0 {
            Log.info(.subtitle, "Embedded subtitles #\(streamIndex): \(count) text cues decoded, latest at \(cue.start.clockString)")
        }
    }

    /// Expands a paletted FFmpeg rect (`AV_PIX_FMT_PAL8`, AARRGGBB entries) into a premultiplied RGBA CGImage.
    private static func makeImage(_ rect: AVSubtitleRect) -> BitmapSubtitleImage? {
        guard rect.type == SUBTITLE_BITMAP, rect.w > 0, rect.h > 0, let indices = rect.data.0, let paletteBytes = rect.data.1 else { return nil }
        let width = Int(rect.w), height = Int(rect.h), stride = Int(rect.linesize.0), colors = Int(rect.nb_colors)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        paletteBytes.withMemoryRebound(to: UInt32.self, capacity: max(colors, 1)) { palette in
            for y in 0..<height {
                for x in 0..<width {
                    let index = Int(indices[y * stride + x])
                    let color = index < colors ? palette[index] : 0
                    let alpha = Int((color >> 24) & 0xff)
                    let offset = (y * width + x) * 4
                    rgba[offset] = UInt8(Int((color >> 16) & 0xff) * alpha / 255)
                    rgba[offset + 1] = UInt8(Int((color >> 8) & 0xff) * alpha / 255)
                    rgba[offset + 2] = UInt8(Int(color & 0xff) * alpha / 255)
                    rgba[offset + 3] = UInt8(alpha)
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return BitmapSubtitleImage(image: image, x: Int(rect.x), y: Int(rect.y), width: width, height: height)
    }
}
