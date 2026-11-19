import Foundation
import Observation
import YouTubeCore

@MainActor
@Observable
final class DownloadJob: Identifiable {
    enum State: Equatable {
        case fetchingInfo
        case queued
        case downloading
        case processing(String)
        case finished
        case failed(String)
        case cancelled

        var isActive: Bool {
            switch self {
            case .fetchingInfo, .queued, .downloading, .processing: true
            case .finished, .failed, .cancelled: false
            }
        }
    }

    /// What to produce after the download: a transcript, and optionally a summary of it.
    struct TextRequest: Equatable {
        var transcript = false
        var summary = false

        var isEmpty: Bool { !transcript && !summary }
    }

    enum TextState: Equatable {
        case none
        case waiting
        case fetchingCaptions
        case preparingAudio
        case transcribing(Double?)
        case summarizing(step: Int, total: Int)
        case done
        case failed(String)

        var isActive: Bool {
            switch self {
            case .waiting, .fetchingCaptions, .preparingAudio, .transcribing, .summarizing: true
            case .none, .done, .failed: false
            }
        }
    }

    let id = UUID()
    let url: String
    let options: DownloadOptions
    let createdAt = Date()

    var text: TextRequest
    var textState: TextState = .none
    var transcriptURL: URL?
    var summaryURL: URL?
    /// Transcript text without timestamps, kept for summarising later.
    @ObservationIgnored var transcriptPlain: String?
    @ObservationIgnored var textTask: Task<Void, Never>?

    var state: State = .fetchingInfo
    var metadata: VideoMetadata?
    var progress = DownloadProgress()
    /// yt-dlp downloads video and audio as separate streams in video mode; count them for the UI.
    var streamIndex = 1
    var outputURL: URL?

    @ObservationIgnored var cancelAction: (@Sendable () -> Void)?
    @ObservationIgnored var task: Task<Void, Never>?

    init(url: String, options: DownloadOptions, text: TextRequest = TextRequest()) {
        self.url = url
        self.options = options
        self.text = text
    }

    var displayTitle: String { metadata?.title ?? url }

    /// "Channel · 12:34 · Audio · m4a"
    var hint: String {
        [metadata?.author, Format.duration(metadata?.duration), options.summary]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    func apply(_ event: YTDLPEvent) {
        switch event {
        case .progress(let next):
            if let prevDone = progress.downloadedBytes, let nextDone = next.downloadedBytes,
               let prevFraction = progress.fraction, prevFraction > 0.9, nextDone < prevDone {
                streamIndex += 1
            }
            progress = next
            if state != .downloading { state = .downloading }
        case .postprocessing(let label):
            state = .processing(label)
        case .finishedFile(let path):
            outputURL = URL(fileURLWithPath: path)
        case .log:
            break
        }
    }
}
