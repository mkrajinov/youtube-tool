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

    let id = UUID()
    let url: String
    let options: DownloadOptions
    let createdAt = Date()

    var state: State = .fetchingInfo
    var metadata: VideoMetadata?
    var progress = DownloadProgress()
    /// yt-dlp downloads video and audio as separate streams in video mode; count them for the UI.
    var streamIndex = 1
    var outputURL: URL?

    @ObservationIgnored var cancelAction: (@Sendable () -> Void)?
    @ObservationIgnored var task: Task<Void, Never>?

    init(url: String, options: DownloadOptions) {
        self.url = url
        self.options = options
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
