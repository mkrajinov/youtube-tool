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

    /// A playlist or channel waiting for the user to pick videos, with the settings at the time.
    struct PlaylistRequest: Identifiable, Equatable {
        let id = UUID()
        let url: String
        let mode: DownloadMode
        let audioFormat: AudioFormat
        let text: DownloadJob.TextRequest
    }

    struct AddResult {
        var videos = 0
        var playlists = 0
        /// The one link added was a video opened from a playlist: offer the whole playlist.
        var playlistOffer: String?

        var isEmpty: Bool { videos == 0 && playlists == 0 }
    }

    /// Playlists shown one after another in the picker sheet.
    private(set) var playlistRequests: [PlaylistRequest] = []

    func dismissPlaylist(_ request: PlaylistRequest) {
        playlistRequests.removeAll { $0.id == request.id }
    }

    /// Adds every YouTube link found in `text`: videos go to the queue, playlists and channels
    /// open the picker.
    @discardableResult
    func add(_ text: String, mode: DownloadMode, audioFormat: AudioFormat,
             textRequest: DownloadJob.TextRequest = DownloadJob.TextRequest()) -> AddResult {
        let links = LinkExtractor.links(in: text).compactMap(YouTubeLink.classify)
        var result = AddResult()
        var newJobs: [DownloadJob] = []
        for link in links {
            switch link {
            case .video(let url, _):
                let options = makeOptions(mode: mode, audioFormat: audioFormat, directory: AppSettings.outputDirectory)
                newJobs.append(DownloadJob(url: url, options: options, text: textRequest))
            case .playlist(let url):
                openPlaylist(url, mode: mode, audioFormat: audioFormat, textRequest: textRequest)
                result.playlists += 1
            }
        }
        if links.count == 1, case .video(_, let playlist?) = links[0] { result.playlistOffer = playlist }
        result.videos = newJobs.count
        jobs.insert(contentsOf: newJobs, at: 0)
        newJobs.forEach(fetchInfo)
        return result
    }

    func openPlaylist(_ url: String, mode: DownloadMode, audioFormat: AudioFormat,
                      textRequest: DownloadJob.TextRequest) {
        guard !playlistRequests.contains(where: { $0.url == url }) else { return }
        playlistRequests.append(PlaylistRequest(url: url, mode: mode, audioFormat: audioFormat, text: textRequest))
    }

    func fetchPlaylist(_ url: String) async throws -> PlaylistInfo {
        guard let ytdlp = tools.ytdlp else { throw YTDLPError.failed("yt-dlp not found") }
        return try await client(ytdlp).fetchPlaylist(url: url)
    }

    /// Where a playlist's videos go: the download folder, or a subfolder named after the playlist.
    static func playlistDirectory(for info: PlaylistInfo, ownFolder: Bool) -> URL {
        ownFolder
            ? AppSettings.outputDirectory.appendingPathComponent(PlaylistNaming.folderName(info.title), isDirectory: true)
            : AppSettings.outputDirectory
    }

    /// Queues the chosen videos of a playlist. They keep the playlist order.
    func enqueue(_ entries: [PlaylistEntry], from info: PlaylistInfo, request: PlaylistRequest,
                 ownFolder: Bool, numbered: Bool) {
        let directory = Self.playlistDirectory(for: info, ownFolder: ownFolder)
        let total = info.entries.count
        let newJobs = entries.map { entry in
            var options = makeOptions(mode: request.mode, audioFormat: request.audioFormat, directory: directory)
            if numbered { options.filePrefix = PlaylistNaming.numberPrefix(index: entry.index, count: total) }
            let job = DownloadJob(url: entry.url, options: options, text: request.text)
            job.metadata = entry.partialMetadata
            job.metadataIsPartial = true
            job.playlistLabel = "\(info.title) #\(entry.index)"
            job.state = .queued
            return job
        }
        jobs.insert(contentsOf: newJobs, at: 0)
        pump()
    }

    private func makeOptions(mode: DownloadMode, audioFormat: AudioFormat, directory: URL) -> DownloadOptions {
        DownloadOptions(
            mode: mode,
            audioFormat: audioFormat,
            outputDirectory: directory,
            embedMetadata: AppSettings.embedMetadata,
            ffmpegLocation: tools.ffmpeg?.url.deletingLastPathComponent()  // dir, so ffprobe resolves too
        )
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
        // Waiting jobs first, so cancelling a running one doesn't start the next.
        for job in jobs where job.state == .queued || job.state == .fetchingInfo {
            job.task?.cancel()
            job.state = .cancelled
        }
        infoWaiting.removeAll()
        jobs.filter(\.state.isActive).forEach(cancel)
        textQueue.forEach { $0.textState = .none }
        textQueue.removeAll()
        jobs.forEach { $0.textTask?.cancel() }
    }

    func retry(_ job: DownloadJob) {
        guard !job.state.isActive else { return }
        let fresh = DownloadJob(url: job.url, options: job.options, text: job.text)
        fresh.metadata = job.metadata
        fresh.metadataIsPartial = job.metadataIsPartial
        fresh.playlistLabel = job.playlistLabel
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
        job.textTask?.cancel()
        textQueue.removeAll { $0.id == job.id }
        infoWaiting.removeAll { $0.id == job.id }
        jobs.removeAll { $0.id == job.id }
    }

    func clearFinished() {
        jobs.filter { !$0.state.isActive && !$0.textState.isActive }.forEach(remove)
    }

    // MARK: Pipeline

    /// Info fetches waiting for a slot: a pasted list of 100 links shouldn't start 100 yt-dlp processes.
    private var infoWaiting: [DownloadJob] = []
    private var infoRunning = 0
    private static let maxInfoFetches = 3

    private func fetchInfo(for job: DownloadJob) {
        guard tools.ytdlp != nil else {
            job.state = .failed("yt-dlp not found. Reinstall the app or set a path in Settings.")
            return
        }
        job.state = .fetchingInfo
        infoWaiting.append(job)
        pumpInfo()
    }

    private func pumpInfo() {
        while infoRunning < Self.maxInfoFetches, !infoWaiting.isEmpty {
            let job = infoWaiting.removeFirst()
            guard job.state == .fetchingInfo, let ytdlp = tools.ytdlp else { continue }  // cancelled while waiting
            infoRunning += 1
            job.task = Task {
                do {
                    job.metadata = try await client(ytdlp).fetchMetadata(url: job.url)
                    if job.state == .fetchingInfo { job.state = .queued }
                } catch is CancellationError {
                    job.state = .cancelled
                } catch YTDLPError.cancelled {
                    job.state = .cancelled
                } catch {
                    if job.state == .fetchingInfo { job.state = .failed(error.localizedDescription) }
                }
                self.infoRunning -= 1
                self.pumpInfo()
                self.pump()
            }
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
                if !job.text.isEmpty { self.enqueueText(job) }
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

    // MARK: Transcripts and summaries

    /// Jobs waiting for a transcript or summary. One runs at a time: speech recognition and the
    /// language model use the whole Neural Engine.
    private var textQueue: [DownloadJob] = []
    private var textRunning = false

    /// From the job card buttons: add a transcript (and a summary) to a finished download.
    func requestText(for job: DownloadJob, summary: Bool) {
        guard job.state == .finished, !job.textState.isActive else { return }
        job.text.transcript = true
        if summary { job.text.summary = true }
        enqueueText(job)
    }

    private func enqueueText(_ job: DownloadJob) {
        job.textState = .waiting
        textQueue.append(job)
        pumpText()
    }

    private func pumpText() {
        guard !textRunning, !textQueue.isEmpty else { return }
        let job = textQueue.removeFirst()
        textRunning = true
        job.textTask = Task {
            do {
                try await self.makeText(for: job)
                job.textState = .done
            } catch is CancellationError {
                job.textState = .none
            } catch {
                job.textState = .failed(error.localizedDescription)
            }
            job.textTask = nil
            self.textRunning = false
            self.pumpText()
        }
    }

    private func makeText(for job: DownloadJob) async throws {
        guard let media = job.outputURL else { throw YTDLPError.failed("The downloaded file is missing") }
        if job.metadataIsPartial, let ytdlp = tools.ytdlp {
            // Playlist listings have no caption info; get the full details now.
            job.textState = .fetchingCaptions
            if let full = try? await client(ytdlp).fetchMetadata(url: job.url) {
                job.metadata = full
                job.metadataIsPartial = false
            }
            try Task.checkCancellation()
        }
        let title = job.metadata?.title ?? media.deletingPathExtension().lastPathComponent

        if job.transcriptPlain == nil || job.transcriptURL == nil {
            let (lines, source) = try await transcriptLines(for: job, media: media)
            guard !lines.isEmpty else { throw YTDLPError.failed("The transcript is empty") }
            let document = TranscriptFormatter.document(
                title: title, url: job.metadata?.webpageURL ?? job.url, source: source,
                paragraphs: TranscriptFormatter.paragraphs(lines))
            let url = TextOutputs.transcriptURL(for: media)
            try document.write(to: url, atomically: true, encoding: .utf8)
            job.transcriptURL = url
            job.transcriptPlain = TranscriptFormatter.paragraphs(lines, timestamps: false).joined(separator: "\n")
        }

        guard job.text.summary, let plain = job.transcriptPlain else { return }
        try Task.checkCancellation()
        guard #available(macOS 26, *) else {
            throw TextPipelineError.summaryUnavailable(OnDeviceText.SummaryStatus.needsNewerMacOS.message)
        }
        job.textState = .summarizing(step: 0, total: 1)
        let summary = try await Summarizer.summarize(title: title, transcript: plain) { step, total in
            Task { @MainActor in
                if job.textState.isActive { job.textState = .summarizing(step: step, total: total) }
            }
        }
        let url = TextOutputs.summaryURL(for: media)
        let markdown = "# \(title)\n\n\(job.metadata?.webpageURL ?? job.url)\n\n\(summary)\n\n"
            + "_Summarised on this Mac by Apple Intelligence from the transcript._\n"
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        job.summaryURL = url
    }

    /// YouTube captions when the video has them, otherwise on-device speech recognition.
    private func transcriptLines(for job: DownloadJob, media: URL) async throws -> ([TranscriptLine], String) {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("YouTubeTool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        if let metadata = job.metadata, let track = CaptionPicker.pick(for: metadata), let ytdlp = tools.ytdlp {
            job.textState = .fetchingCaptions
            do {
                let vtt = try await client(ytdlp).fetchCaptions(url: job.url, track: track, into: temp)
                let lines = WebVTT.lines(from: try String(contentsOf: vtt, encoding: .utf8))
                if !lines.isEmpty { return (lines, track.label) }
            } catch {
                NSLog("YouTubeTool: captions failed, falling back to speech recognition: \(error)")
            }
        }
        try Task.checkCancellation()

        guard #available(macOS 26, *), OnDeviceText.speechAvailable, let ffmpeg = tools.ffmpeg else {
            throw TextPipelineError.noCaptionsAndNoSpeech
        }
        job.textState = .preparingAudio
        let wav = temp.appendingPathComponent("audio.wav")
        try await AudioConverter.wav(from: media, ffmpeg: ffmpeg.url, to: wav)
        job.textState = .transcribing(nil)
        let (lines, locale) = try await SpeechTranscription.transcribe(
            wav: wav, languageHint: job.metadata?.language, duration: job.metadata?.duration
        ) { fraction in
            Task { @MainActor in
                if job.textState.isActive { job.textState = .transcribing(fraction) }
            }
        }
        let language = Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        return (lines, "Apple speech recognition on this Mac (\(language))")
    }

    func openTranscript(_ job: DownloadJob) {
        if let url = job.transcriptURL { NSWorkspace.shared.open(url) }
    }

    func openSummary(_ job: DownloadJob) {
        if let url = job.summaryURL { NSWorkspace.shared.open(url) }
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
