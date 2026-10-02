import Foundation

/// Appends formatted entries to a text file and rotates it once it grows past `maxBytes`
/// (the previous file is kept as `<name>.1`). Writes happen on a serial queue; failures are
/// ignored so logging never affects the app. Lets logs be pulled off an Apple TV without a debugger.
public final class FileLogSink: LogSink, @unchecked Sendable {
    public let url: URL
    public let rotatedURL: URL
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "app.vela.filelog", qos: .utility)
    private var handle: FileHandle?
    private var size = 0

    public init(url: URL, maxBytes: Int = 2_000_000) {
        self.url = url
        self.rotatedURL = url.appendingPathExtension("1")
        self.maxBytes = maxBytes
        queue.sync { open() }
    }

    public func write(_ entry: LogEntry) {
        let line = entry.formatted + "\n"
        queue.async { [self] in
            let data = Data(line.utf8)
            if size + data.count > maxBytes { rotate() }
            guard let handle else { return }
            do {
                try handle.write(contentsOf: data)
                size += data.count
            } catch {
                self.handle = nil
            }
        }
    }

    /// Blocks until queued lines are on disk (before copying the file, and in tests).
    public func flush() {
        queue.sync { try? handle?.synchronize() }
    }

    private func open() {
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        size = Int((try? handle?.seekToEnd()) ?? 0)
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let manager = FileManager.default
        try? manager.removeItem(at: rotatedURL)
        try? manager.moveItem(at: url, to: rotatedURL)
        size = 0
        open()
    }
}
