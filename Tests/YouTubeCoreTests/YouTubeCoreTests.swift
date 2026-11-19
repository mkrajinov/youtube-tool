import Foundation
import Testing
@testable import YouTubeCore

@Suite struct ProgressParserTests {
    @Test func parsesFullProgressLine() {
        let event = ProgressParser.parse(line: "[ytt-progress]524288|1048576|NA|262144.5|2\n")
        guard case .progress(let p) = event else { Issue.record("expected progress"); return }
        #expect(p.downloadedBytes == 524288)
        #expect(p.totalBytes == 1048576)
        #expect(p.speed == 262144.5)
        #expect(p.eta == 2)
        #expect(p.fraction == 0.5)
    }

    @Test func fallsBackToEstimatedTotal() {
        let event = ProgressParser.parse(line: "[ytt-progress]100|NA|400.0|NA|NA")
        guard case .progress(let p) = event else { Issue.record("expected progress"); return }
        #expect(p.totalBytes == 400)
        #expect(p.speed == nil)
        #expect(p.eta == nil)
        #expect(p.fraction == 0.25)
    }

    @Test func unknownTotalHasNoFraction() {
        let event = ProgressParser.parse(line: "[ytt-progress]100|NA|NA|NA|NA")
        guard case .progress(let p) = event else { Issue.record("expected progress"); return }
        #expect(p.fraction == nil)
    }

    @Test func parsesPostprocessorAndFile() {
        #expect(ProgressParser.parse(line: "[ytt-post]ExtractAudio") == .postprocessing("Converting audio"))
        #expect(ProgressParser.parse(line: "[ytt-post]Merger") == .postprocessing("Merging video and audio"))
        #expect(ProgressParser.parse(line: "[ytt-file]/tmp/a [x].m4a") == .finishedFile("/tmp/a [x].m4a"))
        #expect(ProgressParser.parse(line: "[youtube] abc: Downloading webpage") == .log("[youtube] abc: Downloading webpage"))
        #expect(ProgressParser.parse(line: "[Merger] Merging formats into \"x.mp4\"") == .postprocessing("Merging video and audio"))
        #expect(ProgressParser.parse(line: "[ExtractAudio] Destination: x.mp3") == .postprocessing("Converting audio"))
        #expect(ProgressParser.parse(line: "[FixupM4a] Correcting container") == .postprocessing("Fixing container"))
    }

    @Test func extractsLastErrorLine() {
        let stderr = "WARNING: foo\nERROR: [youtube] x: Video unavailable\n"
        #expect(ProgressParser.errorMessage(fromStderr: stderr) == "[youtube] x: Video unavailable")
        #expect(ProgressParser.errorMessage(fromStderr: "WARNING: only") == nil)
    }
}

@Suite struct LineBufferTests {
    @Test func splitsOnNewlineAndCarriageReturn() {
        let buffer = LineBuffer()
        #expect(buffer.append(Data("one\ntw".utf8)) == ["one"])
        #expect(buffer.append(Data("o\r\nthree\r".utf8)) == ["two", "three"])
        #expect(buffer.append(Data("tail".utf8)).isEmpty)
        #expect(buffer.flush() == ["tail"])
        #expect(buffer.flush().isEmpty)
    }
}

@Suite struct ArgumentsTests {
    let dir = URL(fileURLWithPath: "/Users/me/Downloads/YouTubeTool")
    let url = "https://www.youtube.com/watch?v=abc"

    @Test func audioM4AAvoidsReencode() {
        let args = YTDLPArguments.download(url: url, options: DownloadOptions(mode: .audio, audioFormat: .m4a, outputDirectory: dir))
        #expect(args.contains("-x"))
        #expect(args.adjacent("--audio-format", "m4a"))
        #expect(args.adjacent("-f", "ba[ext=m4a]/ba/b"))
        #expect(args.contains("--embed-thumbnail"))
        #expect(args.adjacent("-P", dir.path))
        #expect(args.suffix(2) == ["--", url])
    }

    @Test func wavSkipsEmbedding() {
        let args = YTDLPArguments.download(url: url, options: DownloadOptions(mode: .audio, audioFormat: .wav, outputDirectory: dir))
        #expect(!args.contains("--embed-thumbnail"))
        #expect(!args.contains("--embed-metadata"))
    }

    @Test func videoMergesToMP4() {
        let ffmpeg = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        let args = YTDLPArguments.download(url: url, options: DownloadOptions(mode: .video, outputDirectory: dir, embedMetadata: false, ffmpegLocation: ffmpeg))
        #expect(args.adjacent("--merge-output-format", "mp4"))
        #expect(args.adjacent("--ffmpeg-location", ffmpeg.path))
        #expect(!args.contains("-x"))
        #expect(!args.contains("--embed-metadata"))
    }

    @Test func metadataIsSingleVideo() {
        let args = YTDLPArguments.metadata(url: url)
        #expect(args.contains("--no-playlist"))
        #expect(args.last == url)
    }

    @Test func recognisesYouTubeURLs() {
        #expect(YTDLPArguments.isLikelyYouTubeURL("https://www.youtube.com/watch?v=abc"))
        #expect(YTDLPArguments.isLikelyYouTubeURL(" https://youtu.be/abc "))
        #expect(YTDLPArguments.isLikelyYouTubeURL("https://music.youtube.com/watch?v=abc"))
        #expect(!YTDLPArguments.isLikelyYouTubeURL("https://notyoutube.com/x"))
        #expect(!YTDLPArguments.isLikelyYouTubeURL("youtube.com/watch?v=abc"))
    }

    @Test func formatsDuration() {
        #expect(Format.duration(754) == "12:34")
        #expect(Format.duration(3723) == "1:02:03")
        #expect(Format.duration(nil) == nil)
    }
}

private extension Array where Element == String {
    func adjacent(_ flag: String, _ value: String) -> Bool {
        guard let i = firstIndex(of: flag), i + 1 < count else { return false }
        return self[i + 1] == value
    }
}
