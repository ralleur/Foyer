import UIKit
import AVKit
import ImageIO
import UniformTypeIdentifiers
import VelaFoundation
import PlaybackDecision

/// Thumbnail above the system scrubber while the user scrubs in AVPlayerViewController. AVKit only shows its own
/// previews for HLS streams with an I-frame playlist, which Jellyfin's streams do not have, and it exposes no scrub
/// position. The bar's time marker (accessibility identifier "Elapsed Time Scrubbing Marker") does: AVKit shows it
/// only while the user scrubs, with the scrub time as its text, and the matching trickplay thumbnail goes above it.
///
/// Smoothness: all tile sheets are fetched once when playback starts and cut into small JPEGs (~10 KB each), so a
/// scrub step only decodes one 320 px image; no network or large decode happens while scrubbing.
@MainActor
final class SystemScrubPreview {
    private static let markerIdentifier = "Elapsed Time Scrubbing Marker"
    private static let size = CGSize(width: 384, height: 216)

    private weak var controller: AVPlayerViewController?
    private let imageView = UIImageView()
    private let container = UIView()
    private var displayLink: CADisplayLink?
    private weak var marker: UIView?

    private var geometry: TrickplayGeometry?
    private var thumbnails: [Int: Data] = [:]
    private var loadTask: Task<Void, Never>?
    private var shownIndex: Int?
    #if DEBUG
    private var lastLoggedIndex: Int?
    #endif

    init() {
        container.isUserInteractionEnabled = false
        container.alpha = 0
        container.layer.cornerRadius = 14
        container.layer.masksToBounds = true
        container.layer.borderWidth = 2
        container.layer.borderColor = UIColor.white.withAlphaComponent(0.85).cgColor
        container.backgroundColor = .black
        imageView.contentMode = .scaleAspectFill
        imageView.frame = CGRect(origin: .zero, size: Self.size)
        container.addSubview(imageView)
        container.frame = CGRect(origin: .zero, size: Self.size)
    }

    func attach(to controller: AVPlayerViewController) {
        self.controller = controller
        if container.superview == nil { controller.view.addSubview(container) }
    }

    /// New item: forget the old thumbnails and fetch the new sheets in the background.
    func setTrickplay(_ geometry: TrickplayGeometry?, tileURL: ((Int) -> URL?)?) {
        loadTask?.cancel()
        thumbnails = [:]
        shownIndex = nil
        self.geometry = geometry
        hide()
        guard let geometry, let tileURL else { return }
        let urls = (0..<geometry.imageCount).map { tileURL($0) }
        loadTask = Task { [weak self] in
            let started = Date()
            var loaded = 0
            for (sheet, url) in urls.enumerated() {
                guard let url, !Task.isCancelled else { continue }
                guard let (data, response) = try? await URLSession.shared.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
                let cut = await Task.detached(priority: .utility) { Self.cut(sheet: data, index: sheet, geometry: geometry) }.value
                guard let self, !Task.isCancelled else { return }
                self.thumbnails.merge(cut) { $1 }
                loaded += 1
            }
            if loaded > 0 {
                Log.info(.playback, "Scrub previews ready: \(self?.thumbnails.count ?? 0) thumbnails from \(loaded) sheets in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
            }
        }
    }

    /// Runs the marker check once per frame while the transport bar is on screen.
    func setActive(_ active: Bool) {
        if active {
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: DisplayLinkTarget { [weak self] in self?.tick() }, selector: #selector(DisplayLinkTarget.fire))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else {
            displayLink?.invalidate()
            displayLink = nil
            hide()
        }
    }

    func stop() {
        setActive(false)
        loadTask?.cancel()
        thumbnails = [:]
    }

    // MARK: Per frame

    private func tick() {
        guard let controller, let geometry, !thumbnails.isEmpty else { return hide() }
        if marker?.window == nil {
            marker = Self.find(in: controller.view)
            if let marker { Log.debug(.playback, "Scrub marker found: \(type(of: marker)) '\((marker as? UILabel)?.text ?? marker.accessibilityLabel ?? "")'") }
        }
        guard let marker, let text = (marker as? UILabel)?.text ?? marker.accessibilityLabel, var time = Self.parse(text) else { return hide() }
        // AVKit shows this marker only while the user scrubs (it is hidden during normal playback).
        var scrubbing = Self.isVisible(marker)
        #if DEBUG
        // `-scrub-preview-demo <seconds>`: pretend the user scrubbed that far ahead (the simulator cannot swipe).
        let demoOffset = UserDefaults.standard.double(forKey: "scrub-preview-demo")
        if demoOffset != 0 { time += demoOffset; scrubbing = true }
        #endif
        guard scrubbing, let tile = geometry.tile(at: time) else { return hide() }
        let index = Int(time * 1000 / Double(max(geometry.info.interval, 1)))
        let clamped = min(max(index, 0), geometry.info.thumbnailCount - 1)
        if clamped != shownIndex, let data = thumbnails[clamped] ?? thumbnails[tile.imageIndex * geometry.thumbnailsPerImage] {
            imageView.image = UIImage(data: data)
            shownIndex = clamped
        }
        guard imageView.image != nil else { return hide() }
        let anchor = marker.convert(marker.bounds, to: controller.view)
        let bounds = controller.view.bounds
        let x = min(max(anchor.midX - Self.size.width / 2, 60), bounds.width - Self.size.width - 60)
        container.frame = CGRect(x: x, y: anchor.minY - Self.size.height - 28, width: Self.size.width, height: Self.size.height)
        controller.view.bringSubviewToFront(container)
        #if DEBUG
        if clamped != lastLoggedIndex {
            lastLoggedIndex = clamped
            Log.debug(.playback, "Scrub preview #\(clamped) at \(time.clockString), frame \(container.frame), superview \(container.superview.map { "\(type(of: $0))" } ?? "nil"), window \(container.window != nil)")
        }
        #endif
        if container.alpha < 1 { UIView.animate(withDuration: 0.12) { self.container.alpha = 1 } }
    }

    private func hide() {
        guard container.alpha > 0 else { return }
        UIView.animate(withDuration: 0.12) { self.container.alpha = 0 }
    }

    // MARK: Helpers

    private static func isVisible(_ view: UIView) -> Bool {
        var current: UIView? = view
        while let candidate = current {
            if candidate.isHidden || candidate.alpha < 0.01 { return false }
            current = candidate.superview
        }
        return view.window != nil
    }

    private static func find(in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == markerIdentifier { return view }
        for subview in view.subviews { if let found = find(in: subview) { return found } }
        return nil
    }

    /// "12:34", "1:02:03", "-5:00" → seconds.
    nonisolated static func parse(_ text: String) -> TimeInterval? {
        let parts = text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "-−")).split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var seconds: TimeInterval = 0
        for part in parts {
            guard let value = Int(part) else { return nil }
            seconds = seconds * 60 + TimeInterval(value)
        }
        return seconds
    }

    /// Cuts one tile sheet into per-thumbnail JPEGs keyed by the global thumbnail index.
    nonisolated static func cut(sheet data: Data, index sheet: Int, geometry: TrickplayGeometry) -> [Int: Data] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [:] }
        let info = geometry.info
        var result: [Int: Data] = [:]
        for slot in 0..<geometry.thumbnailsPerImage {
            let index = sheet * geometry.thumbnailsPerImage + slot
            guard index < info.thumbnailCount else { break }
            let rect = CGRect(x: (slot % max(info.tileWidth, 1)) * info.width, y: (slot / max(info.tileWidth, 1)) * info.height,
                              width: info.width, height: info.height)
            guard rect.maxX <= CGFloat(image.width), rect.maxY <= CGFloat(image.height), let crop = image.cropping(to: rect) else { continue }
            let out = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, crop, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            if CGImageDestinationFinalize(destination) { result[index] = out as Data }
        }
        return result
    }
}

/// CADisplayLink retains its target; this breaks the cycle with the preview.
private final class DisplayLinkTarget: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func fire() { action() }
}
