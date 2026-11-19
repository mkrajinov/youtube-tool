import Foundation
import Testing
@testable import YouTubeCore

@Suite struct CaptionPickerTests {
    private func meta(language: String? = nil, subs: [String] = [], auto: [String] = []) -> VideoMetadata {
        VideoMetadata(id: "x", title: "t", language: language, subtitleLanguages: subs, automaticCaptionLanguages: auto)
    }

    @Test func prefersUploadedCaptionsInSpokenLanguage() {
        let m = meta(language: "en", subs: ["de-DE", "en", "ja"], auto: ["de", "en", "en-orig"])
        #expect(CaptionPicker.pick(for: m) == CaptionTrack(language: "en", isAutomatic: false))
    }

    @Test func matchesRegionalUploadedTrack() {
        let m = meta(language: "de", subs: ["de-DE", "en"], auto: ["de-orig"])
        #expect(CaptionPicker.pick(for: m) == CaptionTrack(language: "de-DE", isAutomatic: false))
    }

    @Test func fallsBackToOriginalAutoCaptionsNotTranslations() {
        let m = meta(language: "bs", subs: ["en"], auto: ["bs-orig", "de", "en"])
        #expect(CaptionPicker.pick(for: m) == CaptionTrack(language: "bs-orig", isAutomatic: true))
    }

    @Test func usesOrigTrackWhenLanguageUnknown() {
        let m = meta(auto: ["de", "en", "fr-orig"])
        #expect(CaptionPicker.pick(for: m) == CaptionTrack(language: "fr-orig", isAutomatic: true))
    }

    @Test func ignoresLiveChatAndReturnsNilWithoutCaptions() {
        #expect(CaptionPicker.pick(for: meta(subs: ["live_chat"])) == nil)
        #expect(CaptionPicker.pick(for: meta()) == nil)
    }

    @Test func decodesCaptionKeysFromYTDLPJSON() throws {
        let json = """
        {"id":"a","title":"T","language":"en",
         "subtitles":{"en":[{"ext":"vtt"}],"live_chat":[{"ext":"json"}]},
         "automatic_captions":{"en-orig":[{"ext":"vtt"}],"de":[{"ext":"vtt"}]}}
        """
        let m = try JSONDecoder().decode(VideoMetadata.self, from: Data(json.utf8))
        #expect(m.language == "en")
        #expect(m.subtitleLanguages == ["en", "live_chat"])
        #expect(m.automaticCaptionLanguages == ["de", "en-orig"])
    }
}

@Suite struct WebVTTTests {
    @Test func removesRollingDuplicatesAndWordTimings() {
        let vtt = """
        WEBVTT
        Kind: captions
        Language: en

        00:00:00.320 --> 00:00:18.790 align:start position:0%

        [Music]

        00:00:18.800 --> 00:00:21.790 align:start position:0%

        We're<00:00:19.039><c> no</c><00:00:19.359><c> strangers</c><00:00:19.840><c> to</c>

        00:00:21.790 --> 00:00:21.800 align:start position:0%
        We're no strangers to


        00:00:21.800 --> 00:00:25.950 align:start position:0%
        We're no strangers to
        love.<00:00:22.800><c> You</c><00:00:23.039><c> know</c>

        00:00:25.950 --> 00:00:25.960 align:start position:0%
        love. You know

        """
        #expect(WebVTT.lines(from: vtt) == [
            TranscriptLine(start: 18.8, text: "We're no strangers to"),
            TranscriptLine(start: 21.8, text: "love. You know"),
        ])
    }

    @Test func keepsUploadedCaptionsAndDecodesEntities() {
        let vtt = """
        WEBVTT

        1
        00:00:01.360 --> 00:00:03.040
        [♪♪♪]

        2
        00:01:18.640 --> 00:01:21.880
        ♪ Tom &amp; Jerry ♪

        3
        00:01:22.640 --> 00:01:26.960
        Tom &amp; Jerry
        """
        #expect(WebVTT.lines(from: vtt) == [
            TranscriptLine(start: 78.64, text: "Tom & Jerry"),
            TranscriptLine(start: 82.64, text: "Tom & Jerry"),  // not rolling: repeats are real
        ])
    }

    @Test func parsesTimestamps() {
        #expect(WebVTT.parseTimestamp("01:02:03.500") == 3723.5)
        #expect(WebVTT.parseTimestamp("02:03.000") == 123)
        #expect(WebVTT.parseTimestamp("bad") == nil)
    }
}

@Suite struct TranscriptFormatterTests {
    @Test func groupsLinesIntoTimedParagraphs() {
        let lines = [
            TranscriptLine(start: 0, text: "Hello there."),
            TranscriptLine(start: 50, text: "This ends a sentence."),
            TranscriptLine(start: 60, text: "Next part"),
            TranscriptLine(start: 70, text: "continues."),
        ]
        #expect(TranscriptFormatter.paragraphs(lines, seconds: 45) == [
            "[0:00] Hello there. This ends a sentence.",
            "[1:00] Next part continues.",
        ])
    }

    @Test func forcesBreakWithoutPunctuation() {
        let lines = (0..<4).map { TranscriptLine(start: Double($0) * 50, text: "word") }
        #expect(TranscriptFormatter.paragraphs(lines, seconds: 45).count == 2)
    }
}

@Suite struct TextChunkerTests {
    @Test func keepsShortTextWhole() {
        #expect(TextChunker.chunks("short", maxCharacters: 100) == ["short"])
        #expect(TextChunker.chunks("  ", maxCharacters: 100) == [])
    }

    @Test func packsParagraphsUpToTheLimit() {
        let text = "aaaa\nbbbb\ncccc"
        #expect(TextChunker.chunks(text, maxCharacters: 9) == ["aaaa\nbbbb", "cccc"])
    }

    @Test func splitsLongParagraphsAtSentencesAndWords() {
        let text = "One two three. Four five six. " + String(repeating: "z", count: 25)
        let chunks = TextChunker.chunks(text, maxCharacters: 15)
        #expect(chunks.allSatisfy { $0.count <= 15 })
        #expect(chunks.first == "One two three.")
        #expect(chunks.joined().filter { $0 == "z" }.count == 25)
    }
}

@Suite struct TextOutputTests {
    @Test func namesFilesNextToTheDownload() {
        let media = URL(fileURLWithPath: "/d/Song [abc].m4a")
        #expect(TextOutputs.transcriptURL(for: media).path == "/d/Song [abc].transcript.txt")
        #expect(TextOutputs.summaryURL(for: media).path == "/d/Song [abc].summary.md")
    }

    @Test func captionArguments() {
        let args = YTDLPArguments.captions(url: "https://youtu.be/x",
                                           track: CaptionTrack(language: "en-orig", isAutomatic: true),
                                           directory: URL(fileURLWithPath: "/tmp/c"))
        #expect(args.contains("--write-auto-subs"))
        #expect(args.contains("--skip-download"))
        #expect(args.suffix(2) == ["--", "https://youtu.be/x"])
    }
}
