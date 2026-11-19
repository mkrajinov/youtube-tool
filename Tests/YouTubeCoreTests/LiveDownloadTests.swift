import Foundation
import Testing
@testable import YouTubeCore

/// Real network downloads.
///   Homebrew tools:  YTT_LIVE=1 YTT_OUT=/some/dir swift test --filter LiveDownloadTests
///   Bundled tools only (no Homebrew fallback, PATH limited to the tools dir):
///                    YTT_LIVE=1 YTT_TOOLS_DIR=YouTubeTool.app/Contents/Helpers YTT_OUT=/some/dir swift test --filter LiveDownloadTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["YTT_LIVE"] == "1"), .serialized)
struct LiveDownloadTests {
    /// 3.5 minute music video; stable and widely available.
    let url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    let ytdlp: URL
    let ffmpegDir: URL?
    let deno: URL?
    let client: YTDLPClient

    init() throws {
        let env = ProcessInfo.processInfo.environment
        let locator: BinaryLocator
        if let dir = env["YTT_TOOLS_DIR"] {
            let tools = URL(fileURLWithPath: dir, isDirectory: true).standardizedFileURL
            locator = BinaryLocator(bundledDirectory: tools, updatableDirectory: nil, allowSystem: false)
        } else {
            locator = BinaryLocator(bundledDirectory: nil, updatableDirectory: nil, allowSystem: true)
        }
        ytdlp = try #require(locator.locate("yt-dlp")).url
        ffmpegDir = locator.locate("ffmpeg")?.url.deletingLastPathComponent()
        deno = locator.locate("deno")?.url
        client = YTDLPClient(executable: ytdlp, jsRuntime: deno, toolDirectories: [ffmpegDir].compactMap { $0 })
        print("live tools: yt-dlp=\(ytdlp.path) ffmpeg dir=\(ffmpegDir?.path ?? "-") deno=\(deno?.path ?? "-")")
    }

    var out: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["YTT_OUT"] ?? NSTemporaryDirectory())
            .appendingPathComponent("live", isDirectory: true)
    }

    @Test func metadata() async throws {
        let meta = try await client.fetchMetadata(url: url)
        #expect(meta.id == "dQw4w9WgXcQ")
        #expect(!meta.title.isEmpty)
        #expect((meta.duration ?? 0) > 10)
    }

    @Test func captions() async throws {
        let meta = try await client.fetchMetadata(url: url)
        let track = try #require(CaptionPicker.pick(for: meta))
        #expect(track.baseLanguage == "en")
        let dir = out.appendingPathComponent("captions-\(UUID().uuidString)")
        let vtt = try await client.fetchCaptions(url: url, track: track, into: dir)
        let lines = WebVTT.lines(from: try String(contentsOf: vtt, encoding: .utf8))
        #expect(lines.count > 10)
        #expect(lines.contains { $0.text.localizedCaseInsensitiveContains("never gonna give you up") })
        print("captions \(track.label): \(lines.count) lines, first: \(lines.first?.text ?? "-")")
    }

    @Test(arguments: [
        (DownloadMode.audio, AudioFormat.m4a, "m4a"),
        (.audio, .mp3, "mp3"),
        (.audio, .opus, "opus"),
        (.video, .m4a, "mp4"),
    ])
    func download(mode: DownloadMode, format: AudioFormat, ext: String) async throws {
        let options = DownloadOptions(mode: mode, audioFormat: format,
                                      outputDirectory: out.appendingPathComponent(ext),
                                      ffmpegLocation: ffmpegDir)
        let handle = client.download(url: url, options: options)
        var progressEvents = 0, post: [String] = [], file: String?
        for try await event in handle.events {
            switch event {
            case .progress: progressEvents += 1
            case .postprocessing(let p): post.append(p)
            case .finishedFile(let f): file = f
            case .log: break
            }
        }
        print("[\(ext)] progress events: \(progressEvents), post: \(Set(post)), file: \(file ?? "nil")")
        #expect(progressEvents > 0)
        #expect(!post.isEmpty)
        let path = try #require(file)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(path.hasSuffix("." + ext))
    }

    @Test func cancelStopsProcess() async throws {
        // A long video so the download is still running when we cancel.
        let long = "https://www.youtube.com/watch?v=aqz-KE-bpKQ"
        let dir = out.appendingPathComponent("cancel")
        let handle = client.download(
            url: long, options: DownloadOptions(mode: .video, outputDirectory: dir, ffmpegLocation: ffmpegDir))
        var sawProgress = false
        do {
            for try await event in handle.events {
                if case .progress = event, !sawProgress {
                    sawProgress = true
                    handle.cancel()
                }
            }
            Issue.record("expected cancellation error")
        } catch let error as YTDLPError {
            #expect(error == .cancelled)
        }
        #expect(sawProgress)
    }
}
