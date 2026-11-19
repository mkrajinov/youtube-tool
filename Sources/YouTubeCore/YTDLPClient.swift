import Foundation

public enum YTDLPError: LocalizedError, Equatable {
    case failed(String)
    case cancelled
    case invalidMetadata(String)

    public var errorDescription: String? {
        switch self {
        case .failed(let message): message
        case .cancelled: "Cancelled"
        case .invalidMetadata(let detail): "Could not read video info: \(detail)"
        }
    }
}

/// Splits a byte stream into lines on `\n` or `\r`. Thread-safe.
public final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    private let lock = NSLock()

    public init() {}

    public func append(_ chunk: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        pending.append(chunk)
        var lines: [String] = []
        while let idx = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = pending[pending.startIndex..<idx]
            pending.removeSubrange(pending.startIndex...idx)
            if !lineData.isEmpty {
                lines.append(String(decoding: lineData, as: UTF8.self))
            }
        }
        return lines
    }

    public func flush() -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard !pending.isEmpty else { return [] }
        let line = String(decoding: pending, as: UTF8.self)
        pending.removeAll()
        return [line]
    }
}

/// A running yt-dlp process that can be cancelled from any thread.
public final class RunningProcess: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var _cancelled = false

    init(process: Process) { self.process = process }

    public var wasCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }

    /// Sends SIGINT (yt-dlp cleans up and stops its ffmpeg child), then SIGTERM after a grace period.
    public func cancel() {
        lock.lock()
        let already = _cancelled
        _cancelled = true
        lock.unlock()
        guard !already, process.isRunning else { return }
        process.interrupt()
        let process = self.process
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if process.isRunning { process.terminate() }
        }
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}

public struct DownloadHandle: Sendable {
    public let events: AsyncThrowingStream<YTDLPEvent, Error>
    public let cancel: @Sendable () -> Void
}

public struct YTDLPClient: Sendable {
    public let executable: URL
    /// deno binary used to solve YouTube's JavaScript challenges.
    public let jsRuntime: URL?
    /// Extra directories put on PATH (e.g. where ffmpeg/ffprobe live).
    public let toolDirectories: [URL]

    public init(executable: URL, jsRuntime: URL? = nil, toolDirectories: [URL] = []) {
        self.executable = executable
        self.jsRuntime = jsRuntime
        self.toolDirectories = toolDirectories
    }

    /// PATH is built only from the located tools plus system dirs, never inherited,
    /// so a Homebrew install can't silently stand in for the bundled tools.
    var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        var dirs = [executable.deletingLastPathComponent().path]
        if let jsRuntime { dirs.append(jsRuntime.deletingLastPathComponent().path) }
        dirs += toolDirectories.map(\.path)
        var seen = Set<String>()
        dirs = dirs.filter { seen.insert($0).inserted }
        env["PATH"] = (dirs + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }

    /// Arguments added to every extraction call.
    var commonArguments: [String] {
        guard let jsRuntime else { return [] }
        return ["--js-runtimes", "deno:\(jsRuntime.path)"]
    }

    private func makeProcess(_ arguments: [String], common: Bool = true) -> (Process, Pipe, Pipe) {
        let process = Process()
        process.executableURL = executable
        process.arguments = (common ? commonArguments : []) + arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        return (process, out, err)
    }

    // MARK: Metadata

    public func fetchMetadata(url: String) async throws -> VideoMetadata {
        try await fetchJSON(YTDLPArguments.metadata(url: url))
    }

    /// The videos in a playlist or channel tab.
    public func fetchPlaylist(url: String) async throws -> PlaylistInfo {
        try await fetchJSON(YTDLPArguments.playlist(url: url))
    }

    private func fetchJSON<T: Decodable>(_ arguments: [String]) async throws -> T {
        let (process, out, err) = makeProcess(arguments)
        let handle = RunningProcess(process: process)

        let (status, stdout, stderr): (Int32, Data, Data) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { try process.run() } catch {
                        continuation.resume(throwing: error)
                        return
                    }
                    let errBox = DataBox()
                    let group = DispatchGroup()
                    group.enter()
                    DispatchQueue.global().async {
                        errBox.data = err.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                    let outData = out.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    group.wait()
                    continuation.resume(returning: (process.terminationStatus, outData, errBox.data))
                }
            }
        } onCancel: {
            handle.cancel()
        }

        if handle.wasCancelled { throw YTDLPError.cancelled }
        guard status == 0 else {
            let text = String(decoding: stderr, as: UTF8.self)
            throw YTDLPError.failed(ProgressParser.errorMessage(fromStderr: text) ?? "yt-dlp exited with code \(status)")
        }
        do {
            return try JSONDecoder().decode(T.self, from: stdout)
        } catch {
            throw YTDLPError.invalidMetadata(error.localizedDescription)
        }
    }

    // MARK: Download

    public func download(url: String, options: DownloadOptions) -> DownloadHandle {
        let (process, out, err) = makeProcess(YTDLPArguments.download(url: url, options: options))
        let handle = RunningProcess(process: process)

        let stream = AsyncThrowingStream<YTDLPEvent, Error> { continuation in
            continuation.onTermination = { reason in
                if case .cancelled = reason { handle.cancel() }
            }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try FileManager.default.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)
                    try process.run()
                } catch {
                    continuation.finish(throwing: error)
                    return
                }

                let errBox = DataBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errBox.data = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }

                let buffer = LineBuffer()
                let reader = out.fileHandleForReading
                while true {
                    let chunk = reader.availableData
                    if chunk.isEmpty { break }  // EOF
                    for line in buffer.append(chunk) {
                        continuation.yield(ProgressParser.parse(line: line))
                    }
                }
                for line in buffer.flush() {
                    continuation.yield(ProgressParser.parse(line: line))
                }

                process.waitUntilExit()
                group.wait()

                if handle.wasCancelled {
                    continuation.finish(throwing: YTDLPError.cancelled)
                } else if process.terminationStatus != 0 {
                    let text = String(decoding: errBox.data, as: UTF8.self)
                    let message = ProgressParser.errorMessage(fromStderr: text)
                        ?? "yt-dlp exited with code \(process.terminationStatus)"
                    continuation.finish(throwing: YTDLPError.failed(message))
                } else {
                    continuation.finish()
                }
            }
        }

        return DownloadHandle(events: stream, cancel: { handle.cancel() })
    }

    // MARK: Captions

    /// Downloads a caption track into `directory` and returns the VTT file.
    public func fetchCaptions(url: String, track: CaptionTrack, into directory: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let result = await runSimple(YTDLPArguments.captions(url: url, track: track, directory: directory), common: true) else {
            throw YTDLPError.failed("Could not start yt-dlp")
        }
        guard result.status == 0 else {
            throw YTDLPError.failed(ProgressParser.errorMessage(fromStderr: result.stderr)
                ?? "yt-dlp exited with code \(result.status)")
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        guard let vtt = files.first(where: { $0.pathExtension == "vtt" }) else {
            throw YTDLPError.failed("YouTube returned no captions for \(track.language)")
        }
        return vtt
    }

    // MARK: Version

    public func version() async -> String? {
        guard let result = await runSimple(["--version"]), result.status == 0 else { return nil }
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    public struct UpdateResult: Sendable {
        public let succeeded: Bool
        public let message: String
    }

    /// Runs `yt-dlp -U`. The binary must live in a writable location.
    public func update() async -> UpdateResult {
        guard let result = await runSimple(["-U", "--no-colors"]) else {
            return UpdateResult(succeeded: false, message: "Could not start yt-dlp")
        }
        let lines = (result.stdout + "\n" + result.stderr)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if result.status == 0 {
            let summary = lines.last { $0.hasPrefix("Updated yt-dlp") || $0.contains("up to date") } ?? lines.last
            return UpdateResult(succeeded: true, message: summary ?? "Done")
        }
        let error = ProgressParser.errorMessage(fromStderr: result.stderr) ?? lines.last
        return UpdateResult(succeeded: false, message: error ?? "yt-dlp exited with code \(result.status)")
    }

    private struct SimpleResult: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Runs yt-dlp to completion. Pass `common: true` for calls that talk to YouTube.
    private func runSimple(_ arguments: [String], common: Bool = false) async -> SimpleResult? {
        let (process, out, err) = makeProcess(arguments, common: common)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                guard (try? process.run()) != nil else {
                    continuation.resume(returning: nil)
                    return
                }
                let errBox = DataBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errBox.data = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                group.wait()
                continuation.resume(returning: SimpleResult(
                    status: process.terminationStatus,
                    stdout: String(decoding: data, as: UTF8.self),
                    stderr: String(decoding: errBox.data, as: UTF8.self)))
            }
        }
    }
}
