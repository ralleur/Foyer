import Foundation
import QuartzCore
import UIKit
import VelaFoundation
#if canImport(Libmpv)
import Libmpv
#endif

/// Thin, thread-aware wrapper around libmpv. Commands are issued from the main thread;
/// events arrive on a private queue and are forwarded to the main actor.
#if canImport(Libmpv)
final class MPVController: @unchecked Sendable {
    struct Options {
        var hardwareDecoding = true
        var subtitleFontScale: Double = 1
        var cacheSeconds: Double = 30
        var demuxerMaxBytes = 200 * 1024 * 1024
        var demuxerBackBytes = 60 * 1024 * 1024
        var userAgent = DeviceInfo.httpUserAgent
    }

    enum Event {
        case fileLoaded
        case playbackRestart
        case endFile(reason: Int32, error: Int32)
        case propertyChanged(name: String, value: Any?)
        case log(prefix: String, level: String, text: String)
        case shutdown
    }

    private(set) var handle: OpaquePointer?
    private let eventQueue = DispatchQueue(label: "app.vela.mpv.events", qos: .userInitiated)
    private let stateLock = NSLock()
    private var isDestroyed = false
    /// Called on the main thread.
    var onEvent: (@MainActor (Event) -> Void)?

    let layer: CAMetalLayer

    init(layer: CAMetalLayer, options: Options) throws {
        self.layer = layer
        guard let mpv = mpv_create() else {
            throw VelaError(.videoLoadFailed, detail: "mpv_create failed")
        }
        handle = mpv

        // Rendering: Metal via MoltenVK, VideoToolbox decoding.
        var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        check(mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &wid), "wid")
        set("vo", "gpu-next")
        set("gpu-api", "vulkan")
        set("gpu-context", "moltenvk")
        set("hwdec", options.hardwareDecoding ? "videotoolbox" : "no")
        set("hwdec-codecs", "all")
        set("video-rotate", "no")
        // tvOS has no EDR path for a Metal layer: keep output SDR and let libplacebo tone-map HDR sources well.
        set("target-colorspace-hint", "no")
        set("tone-mapping", "bt.2446a")
        set("gamut-mapping-mode", "perceptual")
        set("dither-depth", "auto")
        set("video-sync", "audio")
        set("interpolation", "no")
        set("deinterlace", "auto")

        // Audio: decode everything to PCM and hand the system the channel layout it supports.
        set("ao", "avfoundation,audiounit")
        set("audio-channels", "auto-safe")
        set("audio-pitch-correction", "yes")
        set("volume-max", "100")

        // Subtitles: libass with embedded fonts; sensible defaults for a TV.
        set("sub-auto", "no")
        set("sub-ass", "yes")
        set("embeddedfonts", "yes")
        set("sub-font", "Helvetica Neue")
        set("sub-font-size", String(Int(52 * options.subtitleFontScale)))
        set("sub-border-size", "3")
        set("sub-shadow-offset", "1")
        set("sub-margin-y", "60")
        set("sub-scale-with-window", "yes")
        set("sub-ass-override", "no")
        set("sub-fix-timing", "yes")
        set("sid", "no")

        // Network and cache: generous read-ahead for high bitrate remuxes, bounded memory.
        set("cache", "yes")
        set("cache-secs", String(Int(options.cacheSeconds)))
        set("cache-pause", "yes")
        set("cache-pause-initial", "yes")
        set("cache-pause-wait", "1.5")
        set("demuxer-max-bytes", String(options.demuxerMaxBytes))
        set("demuxer-max-back-bytes", String(options.demuxerBackBytes))
        set("demuxer-readahead-secs", String(Int(options.cacheSeconds)))
        set("demuxer-seekable-cache", "yes")
        set("network-timeout", "20")
        // Key/value list (comma separated); values must not contain commas themselves.
        set("stream-lavf-o", "reconnect=1,reconnect_streamed=1,reconnect_delay_max=6,reconnect_on_network_error=1")
        set("user-agent", options.userAgent)
        set("hr-seek", "default")
        set("hr-seek-framedrop", "yes")

        // Behaviour
        set("keep-open", "yes")
        set("idle", "yes")
        set("input-default-bindings", "no")
        set("input-vo-keyboard", "no")
        set("osd-level", "0")
        set("terminal", "no")
        set("msg-level", "all=warn,ffmpeg=error,vo=info,ao=info,demux=info,cplayer=info")

        check(mpv_initialize(mpv), "mpv_initialize")
        #if DEBUG
        mpv_request_log_messages(mpv, "info")
        #else
        mpv_request_log_messages(mpv, "warn")
        #endif

        observe("time-pos", MPV_FORMAT_DOUBLE)
        observe("duration", MPV_FORMAT_DOUBLE)
        observe("pause", MPV_FORMAT_FLAG)
        observe("paused-for-cache", MPV_FORMAT_FLAG)
        observe("core-idle", MPV_FORMAT_FLAG)
        observe("eof-reached", MPV_FORMAT_FLAG)
        observe("seeking", MPV_FORMAT_FLAG)
        observe("demuxer-cache-duration", MPV_FORMAT_DOUBLE)
        observe("cache-buffering-state", MPV_FORMAT_INT64)
        observe("track-list/count", MPV_FORMAT_INT64)
        observe("video-codec", MPV_FORMAT_STRING)
        observe("audio-codec-name", MPV_FORMAT_STRING)
        observe("hwdec-current", MPV_FORMAT_STRING)
        observe("frame-drop-count", MPV_FORMAT_INT64)
        observe("video-bitrate", MPV_FORMAT_DOUBLE)
        observe("video-params/sig-peak", MPV_FORMAT_DOUBLE)
        observe("container-fps", MPV_FORMAT_DOUBLE)
        observe("audio-params/channel-count", MPV_FORMAT_INT64)

        mpv_set_wakeup_callback(mpv, { context in
            guard let context else { return }
            let controller = Unmanaged<MPVController>.fromOpaque(context).takeUnretainedValue()
            controller.drainEvents()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    // MARK: Options & properties

    private func set(_ name: String, _ value: String) {
        guard let handle else { return }
        let result = mpv_set_option_string(handle, name, value)
        if result < 0 {
            Log.notice(.playback, "mpv option \(name)=\(value) rejected: \(String(cString: mpv_error_string(result)))")
        }
    }

    private func observe(_ name: String, _ format: mpv_format) {
        guard let handle else { return }
        mpv_observe_property(handle, 0, name, format)
    }

    @discardableResult
    private func check(_ status: Int32, _ what: String) -> Bool {
        if status < 0 {
            Log.error(.playback, "mpv \(what) failed: \(String(cString: mpv_error_string(status)))")
            return false
        }
        return true
    }

    func setProperty(_ name: String, string value: String) {
        guard let handle, !destroyed else { return }
        let result = mpv_set_property_string(handle, name, value)
        if result < 0 { Log.notice(.playback, "mpv set \(name)=\(value) failed: \(String(cString: mpv_error_string(result)))") }
    }

    func setProperty(_ name: String, flag value: Bool) {
        guard let handle, !destroyed else { return }
        var flag: Int32 = value ? 1 : 0
        mpv_set_property(handle, name, MPV_FORMAT_FLAG, &flag)
    }

    func setProperty(_ name: String, double value: Double) {
        guard let handle, !destroyed else { return }
        var v = value
        mpv_set_property(handle, name, MPV_FORMAT_DOUBLE, &v)
    }

    func getString(_ name: String) -> String? {
        guard let handle, !destroyed else { return nil }
        guard let cstr = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(cstr) }
        return String(cString: cstr)
    }

    func getDouble(_ name: String) -> Double? {
        guard let handle, !destroyed else { return nil }
        var value = Double()
        guard mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0 else { return nil }
        return value
    }

    func getInt(_ name: String) -> Int64? {
        guard let handle, !destroyed else { return nil }
        var value = Int64()
        guard mpv_get_property(handle, name, MPV_FORMAT_INT64, &value) >= 0 else { return nil }
        return value
    }

    func getFlag(_ name: String) -> Bool? {
        guard let handle, !destroyed else { return nil }
        var value = Int32()
        guard mpv_get_property(handle, name, MPV_FORMAT_FLAG, &value) >= 0 else { return nil }
        return value != 0
    }

    /// Runs an mpv command, e.g. `["loadfile", url, "replace"]`.
    @discardableResult
    func command(_ args: [String]) -> Int32 {
        guard let handle, !destroyed else { return -1 }
        var cStrings: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        cStrings.append(nil)
        defer { cStrings.forEach { free($0) } }
        let result = cStrings.withUnsafeMutableBufferPointer { buffer -> Int32 in
            buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) { pointer in
                mpv_command(handle, pointer)
            }
        }
        if result < 0 {
            Log.notice(.playback, "mpv command \(args.first ?? "") failed: \(String(cString: mpv_error_string(result)))")
        }
        return result
    }

    private var destroyed: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return isDestroyed
    }

    // MARK: Events

    private func drainEvents() {
        eventQueue.async { [weak self] in
            guard let self else { return }
            while true {
                self.stateLock.lock()
                let handle = self.isDestroyed ? nil : self.handle
                self.stateLock.unlock()
                guard let handle, let event = mpv_wait_event(handle, 0) else { return }
                let id = event.pointee.event_id
                if id == MPV_EVENT_NONE { return }
                if let parsed = self.parse(event.pointee) {
                    if case .shutdown = parsed { return }
                    Task { @MainActor [weak self] in self?.onEvent?(parsed) }
                }
            }
        }
    }

    private func parse(_ event: mpv_event) -> Event? {
        switch event.event_id {
        case MPV_EVENT_FILE_LOADED:
            return .fileLoaded
        case MPV_EVENT_PLAYBACK_RESTART:
            return .playbackRestart
        case MPV_EVENT_END_FILE:
            guard let data = event.data else { return .endFile(reason: 0, error: 0) }
            let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            return .endFile(reason: Int32(end.reason.rawValue), error: end.error)
        case MPV_EVENT_SHUTDOWN:
            return .shutdown
        case MPV_EVENT_LOG_MESSAGE:
            guard let data = event.data else { return nil }
            let message = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
            return .log(prefix: String(cString: message.prefix), level: String(cString: message.level),
                        text: String(cString: message.text).trimmingCharacters(in: .newlines))
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let data = event.data else { return nil }
            let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
            let name = String(cString: property.name)
            var value: Any?
            switch property.format {
            case MPV_FORMAT_DOUBLE:
                value = property.data?.assumingMemoryBound(to: Double.self).pointee
            case MPV_FORMAT_FLAG:
                value = property.data.map { $0.assumingMemoryBound(to: Int32.self).pointee != 0 }
            case MPV_FORMAT_INT64:
                value = property.data?.assumingMemoryBound(to: Int64.self).pointee
            case MPV_FORMAT_STRING:
                if let pointer = property.data?.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee {
                    value = String(cString: pointer)
                }
            default:
                value = nil
            }
            return .propertyChanged(name: name, value: value)
        default:
            return nil
        }
    }

    // MARK: Teardown

    /// Stops playback and destroys the context off the main thread (mpv_terminate_destroy blocks).
    func destroy() {
        stateLock.lock()
        guard !isDestroyed, let handle else {
            stateLock.unlock()
            return
        }
        isDestroyed = true
        self.handle = nil
        stateLock.unlock()
        mpv_set_wakeup_callback(handle, nil, nil)
        let layer = self.layer
        DispatchQueue.global(qos: .userInitiated).async {
            mpv_terminate_destroy(handle)
            DispatchQueue.main.async {
                layer.removeFromSuperlayer()
                Log.debug(.playback, "mpv context destroyed")
            }
        }
    }

    deinit {
        destroy()
    }

    static var versionString: String {
        let api = mpv_client_api_version()
        return "libmpv API \(api >> 16).\(api & 0xFFFF)"
    }
}
#endif

/// CAMetalLayer with two workarounds needed by MoltenVK-backed mpv (see MPVKit demo).
final class MPVMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            // MoltenVK briefly forces a 1×1 drawable to flush presentation; ignore it.
            if Int(newValue.width) > 1, Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }
}
