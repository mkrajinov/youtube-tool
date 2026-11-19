import AppKit
import Foundation
import Observation
import YouTubeCore

@MainActor
@Observable
final class DownloadQueue {
    struct Tools: Equatable {
        var ytdlp: LocatedTool?
        var ffmpeg: LocatedTool?
        var ffprobe: LocatedTool?
        var deno: LocatedTool?
        var ytdlpVersion: String?
        var bundled: ToolInstaller.BundledVersions?
        var isPreparing = false

        var isReady: Bool { !isPreparing && ytdlp != nil && ffmpeg != nil }
        var missing: [String] {
            [ytdlp == nil ? "yt-dlp" : nil, ffmpeg == nil ? "ffmpeg" : nil].compactMap { $0 }
        }
    }

    enum UpdateState: Equatable {
        case idle
        case running
        case done(String)
        case failed(String)
    }

    private(set) var jobs: [DownloadJob] = []
    private(set) var tools = Tools(isPreparing: true)
    private(set) var updateState = UpdateState.idle

    /// YouTubeTool.app/Contents/Helpers (nil when run via `swift run`).
    static var helpersDirectory: URL? {
        let dir = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }

    /// Versions of the bundled tools, written by scripts/build-app.sh.
    static var bundledVersions: ToolInstaller.BundledVersions? {
        Bundle.main.url(forResource: "tool-versions", withExtension: "json")
            .flatMap(ToolInstaller.bundledVersions(file:))
    }

    /// ~/Library/Application Support/YouTubeTool/bin, holds the self-updating yt-dlp.
    static var updatableDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YouTubeTool/bin", isDirectory: true)
    }

    private var locator: BinaryLocator {
        BinaryLocator(bundledDirectory: Self.helpersDirectory, updatableDirectory: Self.updatableDirectory)
    }

    init() {
        Task { await prepareTools() }
    }

    // MARK: Tools

    /// Copies the bundled yt-dlp to its updatable location (first launch / newer app), then locates everything.
    private func prepareTools() async {
        if let helpers = Self.helpersDirectory {
            let bundled = Self.bundledVersions
            do {
                try await ToolInstaller.prepareUpdatableYTDLP(
                    bundledDir: helpers,
                    bundledVersion: bundled?.ytdlp,
                    destinationDir: Self.updatableDirectory,
                    installedVersion: { await YTDLPClient(executable: $0).version() })
            } catch {
                // Fall back to running the bundled copy directly.
                NSLog("YouTubeTool: could not prepare updatable yt-dlp: \(error)")
            }
        }
        refreshTools()
    }

    func refreshTools() {
        let locator = self.locator
        var next = Tools(
            ytdlp: locator.locate("yt-dlp", override: AppSettings.ytdlpOverride),
            ffmpeg: locator.locate("ffmpeg", override: AppSettings.ffmpegOverride),
            ffprobe: nil,
            deno: locator.locate("deno"),
            bundled: Self.bundledVersions
        )
        // ffprobe must come from the same place as ffmpeg.
        if let ffmpeg = next.ffmpeg {
            let probe = ffmpeg.url.deletingLastPathComponent().appendingPathComponent("ffprobe")
            if FileManager.default.isExecutableFile(atPath: probe.path) {
                next.ffprobe = LocatedTool(url: probe, source: ffmpeg.source)
            }
        }
        tools = next
        guard let ytdlp = next.ytdlp else { return }
        Task {
            let version = await YTDLPClient(executable: ytdlp.url).version()
            if self.tools.ytdlp == ytdlp { self.tools.ytdlpVersion = version }
        }
    }

    /// yt-dlp configured with the located deno and ffmpeg.
    private func client(_ ytdlp: LocatedTool) -> YTDLPClient {
        YTDLPClient(
            executable: ytdlp.url,
            jsRuntime: tools.deno?.url,
            toolDirectories: [tools.ffmpeg?.url.deletingLastPathComponent()].compactMap { $0 })
    }

    var canUpdateYTDLP: Bool { tools.ytdlp?.source == .updatable }

    func updateYTDLP() {
        guard let ytdlp = tools.ytdlp, ytdlp.source == .updatable, updateState != .running else { return }
        updateState = .running
        Task {
            let result = await YTDLPClient(executable: ytdlp.url).update()
            updateState = result.succeeded ? .done(result.message) : .failed(result.message)
            refreshTools()
        }
    }

    // MARK: Counts

    var runningCount: Int {
        jobs.count { job in
            switch job.state {
            case .downloading, .processing: true
            default: false
            }
        }
    }

    var activeCount: Int { jobs.count { $0.state.isActive } }
    var finishedCount: Int { jobs.count { !$0.state.isActive } }

    // MARK: Queue operations

    /// Accepts one or more URLs separated by whitespace. Returns how many were added.
    @discardableResult
    func enqueue(_ text: String, mode: DownloadMode, audioFormat: AudioFormat) -> Int {
        let urls = text
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter(YTDLPArguments.isLikelyYouTubeURL)
        for url in urls {
            let options = DownloadOptions(
                mode: mode,
                audioFormat: audioFormat,
                outputDirectory: AppSettings.outputDirectory,
                embedMetadata: AppSettings.embedMetadata,
                ffmpegLocation: tools.ffmpeg?.url.deletingLastPathComponent()  // dir, so ffprobe resolves too
            )
            let job = DownloadJob(url: url, options: options)
            jobs.insert(job, at: 0)
            fetchInfo(for: job)
        }
        return urls.count
    }

    func cancel(_ job: DownloadJob) {
        switch job.state {
        case .fetchingInfo, .queued:
            job.task?.cancel()
            job.state = .cancelled
            pump()
        case .downloading, .processing:
            job.cancelAction?()  // the running task sets .cancelled and cleans up
        default:
            break
        }
    }

    func cancelAll() {
        jobs.filter(\.state.isActive).forEach(cancel)
    }

    func retry(_ job: DownloadJob) {
        guard !job.state.isActive else { return }
        let fresh = DownloadJob(url: job.url, options: job.options)
        fresh.metadata = job.metadata
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = fresh
        }
        if fresh.metadata == nil {
            fetchInfo(for: fresh)
        } else {
            fresh.state = .queued
            pump()
        }
    }

    func remove(_ job: DownloadJob) {
        cancel(job)
        jobs.removeAll { $0.id == job.id }
    }

    func clearFinished() {
        jobs.removeAll { !$0.state.isActive }
    }

    // MARK: Pipeline

    private func fetchInfo(for job: DownloadJob) {
        guard let ytdlp = tools.ytdlp else {
            job.state = .failed("yt-dlp not found. Reinstall the app or set a path in Settings.")
            return
        }
        job.state = .fetchingInfo
        job.task = Task {
            do {
                job.metadata = try await client(ytdlp).fetchMetadata(url: job.url)
                guard job.state == .fetchingInfo else { return }
                job.state = .queued
            } catch is CancellationError {
                job.state = .cancelled
            } catch YTDLPError.cancelled {
                job.state = .cancelled
            } catch {
                job.state = .failed(error.localizedDescription)
            }
            self.pump()
        }
    }

    /// Starts queued jobs, oldest first, up to the concurrency limit.
    private func pump() {
        let slots = AppSettings.maxConcurrent - runningCount
        guard slots > 0 else { return }
        let waiting = jobs.filter { $0.state == .queued }.sorted { $0.createdAt < $1.createdAt }
        for job in waiting.prefix(slots) {
            start(job)
        }
    }

    private func start(_ job: DownloadJob) {
        guard let ytdlp = tools.ytdlp else {
            job.state = .failed("yt-dlp not found. Reinstall the app or set a path in Settings.")
            return
        }
        let handle = client(ytdlp).download(url: job.url, options: job.options)
        job.cancelAction = handle.cancel
        job.state = .downloading
        job.task = Task {
            do {
                for try await event in handle.events {
                    job.apply(event)
                }
                job.state = .finished
            } catch YTDLPError.cancelled {
                job.state = .cancelled
                Self.removePartialFiles(for: job)
            } catch {
                job.state = .failed(error.localizedDescription)
            }
            job.cancelAction = nil
            self.pump()
        }
    }

    /// Deletes yt-dlp leftovers (*.part, *.ytdl, fragment and temp files) for a cancelled job.
    /// Only touches files whose name contains this video's "[id]" tag.
    private static func removePartialFiles(for job: DownloadJob) {
        guard let id = job.metadata?.id else { return }
        let fm = FileManager.default
        let dir = job.options.outputDirectory
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let tag = "[\(id)]"
        for name in names where name.contains(tag) {
            // Thumbnails are written before the download and only removed after embedding,
            // so a lone image with this video's tag is a leftover too.
            let isLeftover = name.hasSuffix(".part") || name.hasSuffix(".ytdl")
                || name.contains(".part-Frag") || name.contains(".temp.")
                || [".webp", ".jpg", ".png"].contains { name.hasSuffix($0) }
            if isLeftover {
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }

    #if DEBUG
    func setSampleJobs(_ sample: [DownloadJob]) { jobs = sample }
    #endif

    // MARK: Finder

    func reveal(_ job: DownloadJob) {
        if let url = job.outputURL, FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            openOutputFolder(job.options.outputDirectory)
        }
    }

    func play(_ job: DownloadJob) {
        guard let url = job.outputURL else { return }
        NSWorkspace.shared.open(url)
    }

    func openOutputFolder(_ dir: URL = AppSettings.outputDirectory) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }
}
