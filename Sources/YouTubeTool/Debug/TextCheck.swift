#if DEBUG
import Foundation
import YouTubeCore

/// Dev aid for the on-device text features, run from Terminal:
///   YouTubeTool --text-status
///   YouTubeTool --transcribe <media file> [language]   speech recognition (needs ffmpeg on PATH or bundled)
///   YouTubeTool --summarize <text file> [title]        Apple Intelligence summary
///   YouTubeTool --pipeline <url> -outputDirectory <dir>  download audio + transcript + summary, headless
@MainActor
enum TextCheck {
    static func runIfRequested() {
        let args = CommandLine.arguments
        if args.contains("--text-status") {
            print("speech recognition:", OnDeviceText.speechAvailable)
            print("summaries:", OnDeviceText.summaryStatus.message)
            exit(0)
        }
        if let i = args.firstIndex(of: "--transcribe"), i + 1 < args.count {
            let file = URL(fileURLWithPath: args[i + 1])
            let language = i + 2 < args.count ? args[i + 2] : nil
            run { try await transcribe(file, language: language) }
        }
        if let i = args.firstIndex(of: "--pipeline"), i + 1 < args.count {
            let url = args[i + 1]
            run { try await pipeline(url) }
        }
        if let i = args.firstIndex(of: "--summarize"), i + 1 < args.count {
            let file = URL(fileURLWithPath: args[i + 1])
            let title = i + 2 < args.count ? args[i + 2] : file.deletingPathExtension().lastPathComponent
            run { try await summarize(file, title: title) }
        }
    }

    private static func run(_ work: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await work(); exit(0) } catch { print("error:", error.localizedDescription, error); exit(1) }
        }
        RunLoop.main.run()
    }

    private static func transcribe(_ file: URL, language: String?) async throws {
        guard #available(macOS 26, *) else { throw TextPipelineError.noCaptionsAndNoSpeech }
        let locator = BinaryLocator(bundledDirectory: DownloadQueue.helpersDirectory,
                                    updatableDirectory: nil, allowSystem: true)
        guard let ffmpeg = locator.locate("ffmpeg") else { throw TextPipelineError.audioConversion("no ffmpeg") }
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("ytt-check-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        let start = Date()
        try await AudioConverter.wav(from: file, ffmpeg: ffmpeg.url, to: wav)
        let (lines, locale) = try await SpeechTranscription.transcribe(
            wav: wav, languageHint: language, duration: nil) { _ in }
        print("locale \(locale.identifier), \(lines.count) segments in \(Int(-start.timeIntervalSinceNow)) s")
        TranscriptFormatter.paragraphs(lines).forEach { print($0, "\n") }
    }

    private static func pipeline(_ url: String) async throws {
        AppSettings.register()
        let queue = DownloadQueue()
        while !queue.tools.isReady { try await Task.sleep(for: .milliseconds(200)) }
        print("tools:", queue.tools.ytdlp?.source.label ?? "-", "output:", AppSettings.outputDirectory.path)
        queue.enqueue(url, mode: .audio, audioFormat: .m4a,
                      textRequest: .init(transcript: true, summary: OnDeviceText.summaryStatus == .available))
        let job = try require_(queue.jobs.first)
        var last = ""
        while job.state.isActive || job.textState.isActive || (job.state == .finished && job.textState == .none) {
            let now = "\(job.state) | \(job.textState)"
            if now != last { print(now); last = now }
            try await Task.sleep(for: .milliseconds(300))
        }
        print("final:", job.state, job.textState)
        print("media:", job.outputURL?.path ?? "-")
        print("transcript:", job.transcriptURL?.path ?? "-")
        print("summary:", job.summaryURL?.path ?? "-")
    }

    private static func require_<T>(_ value: T?) throws -> T {
        guard let value else { throw TextPipelineError.audioConversion("nothing enqueued") }
        return value
    }

    private static func summarize(_ file: URL, title: String) async throws {
        guard #available(macOS 26, *) else { throw TextPipelineError.summaryUnavailable("macOS 26") }
        let text = try String(contentsOf: file, encoding: .utf8)
        let start = Date()
        let summary = try await Summarizer.summarize(title: title, transcript: text) { step, total in
            print("step \(step)/\(total)")
        }
        print("--- \(Int(-start.timeIntervalSinceNow)) s ---\n\(summary)")
    }
}
#endif
