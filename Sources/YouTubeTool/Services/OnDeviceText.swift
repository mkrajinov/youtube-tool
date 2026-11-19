import AVFoundation
import Foundation
import FoundationModels
import Speech
import YouTubeCore

/// What this Mac can do on-device: speech recognition (fallback when a video has no captions)
/// and Apple Intelligence summaries. Both need macOS 26.
enum OnDeviceText {
    enum SummaryStatus: Equatable {
        case available
        case needsNewerMacOS
        case deviceNotEligible
        case appleIntelligenceOff
        case modelNotReady

        var message: String {
            switch self {
            case .available: "Apple Intelligence, on this Mac"
            case .needsNewerMacOS: "Needs macOS 26 or later"
            case .deviceNotEligible: "This Mac doesn't support Apple Intelligence"
            case .appleIntelligenceOff: "Turn on Apple Intelligence in System Settings"
            case .modelNotReady: "Apple Intelligence is still downloading"
            }
        }
    }

    static var summaryStatus: SummaryStatus {
        guard #available(macOS 26, *) else { return .needsNewerMacOS }
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(.deviceNotEligible): return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): return .appleIntelligenceOff
        case .unavailable: return .modelNotReady
        }
    }

    static var speechAvailable: Bool {
        guard #available(macOS 26, *) else { return false }
        return SpeechTranscriber.isAvailable
    }
}

enum TextPipelineError: LocalizedError {
    case noCaptionsAndNoSpeech
    case unsupportedLanguage(String)
    case summaryUnavailable(String)
    case audioConversion(String)

    var errorDescription: String? {
        switch self {
        case .noCaptionsAndNoSpeech:
            "No captions on YouTube, and on-device speech recognition needs macOS 26"
        case .unsupportedLanguage(let language):
            "No captions on YouTube, and speech recognition doesn't support \(language)"
        case .summaryUnavailable(let reason):
            "Summary unavailable: \(reason)"
        case .audioConversion(let detail):
            "Could not prepare audio for transcription: \(detail)"
        }
    }
}

// MARK: Speech recognition

@available(macOS 26, *)
enum SpeechTranscription {
    /// Transcribes a 16 kHz mono WAV file. `progress` gets 0...1 as audio is processed.
    static func transcribe(
        wav: URL,
        languageHint: String?,
        duration: Double?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (lines: [TranscriptLine], locale: Locale) {
        let requested = requestedLocale(languageHint)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            let name = Locale.current.localizedString(forIdentifier: requested.identifier) ?? requested.identifier
            throw TextPipelineError.unsupportedLanguage(name)
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()  // language model, first use only
        }

        let results = transcriber.results
        let collector = Task {
            var lines: [TranscriptLine] = []
            for try await result in results where result.isFinal {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    lines.append(TranscriptLine(start: result.range.start.seconds, text: text))
                }
                if let duration, duration > 0 {
                    progress(min(result.range.end.seconds / duration, 1))
                }
            }
            return lines
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        do {
            let file = try AVAudioFile(forReading: wav)
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            collector.cancel()
            throw error
        }
        return (try await collector.value, locale)
    }

    /// YouTube gives a bare language ("en"). Use the user's own region when it's their language
    /// (en_GB stays en_GB), otherwise the language's main region ("en" -> en_US, not en_SG).
    static func requestedLocale(_ hint: String?) -> Locale {
        guard let hint else { return Locale.current }
        let language = Locale.Language(identifier: hint)
        if language.languageCode == Locale.current.language.languageCode { return Locale.current }
        return Locale(identifier: language.maximalIdentifier)
    }
}

/// Converts any downloaded media to the 16 kHz mono WAV speech recognition reads best.
enum AudioConverter {
    static func wav(from input: URL, ffmpeg: URL, to output: URL) async throws {
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                             "-i", input.path, "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", output.path]
        let err = Pipe()
        process.standardError = err
        process.standardOutput = FileHandle.nullDevice
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        guard status == 0 else {
            let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw TextPipelineError.audioConversion(message.split(separator: "\n").last.map(String.init) ?? "ffmpeg exited with \(status)")
        }
    }
}

// MARK: Summaries

@available(macOS 26, *)
enum Summarizer {
    /// The on-device model has a small context window, so long transcripts are summarised in parts
    /// (notes per part), then the notes are summarised.
    static let partCharacters = 5000

    static func summarize(
        title: String,
        transcript: String,
        progress: @escaping @Sendable (_ step: Int, _ total: Int) -> Void
    ) async throws -> String {
        let status = OnDeviceText.summaryStatus
        guard status == .available else { throw TextPipelineError.summaryUnavailable(status.message) }
        // With no text the model would invent a summary from the title alone.
        guard transcript.count >= 40 else { throw TextPipelineError.summaryUnavailable("the transcript is too short") }

        var text = transcript
        var limit = partCharacters
        var round = 0
        while true {
            let parts = TextChunker.chunks(text, maxCharacters: limit)
            if parts.count <= 1 {
                progress(1, 1)
                return try await finalSummary(title: title, text: parts.first ?? "")
            }
            round += 1
            var notes: [String] = []
            for (index, part) in parts.enumerated() {
                progress(index + 1, parts.count + 1)
                do {
                    notes.append(try await partNotes(title: title, text: part, index: index + 1, total: parts.count))
                } catch where isContextOverflow(error) && limit > 1500 {
                    limit /= 2
                    notes = []
                    break
                }
            }
            if notes.isEmpty { continue }  // retry this round with smaller parts
            text = notes.joined(separator: "\n")
            if round > 4 { limit = max(limit / 2, 1500) }  // notes keep growing: force convergence
        }
    }

    private static let language = "Write in the same language as the transcript."

    private static func partNotes(title: String, text: String, index: Int, total: Int) async throws -> String {
        let session = LanguageModelSession(instructions: """
            You take short notes on part of a YouTube video transcript. \
            List the main points as 3 to 6 terse bullet points. No introduction. \(language)
            """)
        let response = try await session.respond(
            to: "Video: \(title)\nPart \(index) of \(total) of the transcript:\n\n\(text)",
            options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 300))
        return response.content
    }

    private static func finalSummary(title: String, text: String) async throws -> String {
        let session = LanguageModelSession(instructions: """
            You summarise YouTube videos from their transcript or from notes on it. \
            Reply in Markdown: first a short overview of 2 to 3 sentences, \
            then a line "## Key points" followed by 4 to 8 bullet points. \
            No introduction, no closing remarks. \(language)
            """)
        let response = try await session.respond(
            to: "Video: \(title)\n\n\(text)",
            options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 700))
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The error type for an over-long prompt changed in macOS 27; match both by name.
    private static func isContextOverflow(_ error: any Error) -> Bool {
        let text = String(describing: error)
        return text.contains("exceededContextWindowSize") || text.contains("contextSizeExceeded")
    }
}
