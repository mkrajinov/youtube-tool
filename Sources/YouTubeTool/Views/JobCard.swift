import SwiftUI
import YouTubeCore

struct JobCard: View {
    @Environment(DownloadQueue.self) private var queue
    let job: DownloadJob

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            thumbnail
            VStack(alignment: .leading, spacing: 6) {
                Text(job.displayTitle)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(job.hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if showsProgressBar {
                    GradientProgressBar(fraction: barFraction)
                        .padding(.top, 2)
                }
                statusLine
                if job.textState != .none { textStatusLine }
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(14)
        .background(CardSurface(radius: 18))
        .contextMenu {
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(job.url, forType: .string)
            }
            if job.outputURL != nil { Button("Show in Finder") { queue.reveal(job) } }
            Divider()
            Button("Remove from List") { queue.remove(job) }
        }
    }

    // MARK: Pieces

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.chipBackground)
            if let string = job.metadata?.thumbnail, let url = URL(string: string) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        placeholderIcon
                    }
                }
            } else {
                placeholderIcon
            }
        }
        .frame(width: 128, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var placeholderIcon: some View {
        Icon(name: job.options.mode == .audio ? "Music" : "Video", size: 24)
            .foregroundStyle(.secondary)
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            AccentPill(color: statusColor)
            Text(statusText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(statusTextColor)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            switch job.state {
            case .fetchingInfo, .queued, .downloading, .processing:
                IconButton(icon: "CloseCircle", help: "Cancel", tint: Theme.failure) { queue.cancel(job) }
            case .finished:
                textButtons
                IconButton(icon: "PlayCircle", help: "Play") { queue.play(job) }
                IconButton(icon: "Folder2", help: "Show in Finder") { queue.reveal(job) }
                IconButton(icon: "Trash", help: "Remove from list") { queue.remove(job) }
            case .failed, .cancelled:
                IconButton(icon: "Refresh", help: "Retry") { queue.retry(job) }
                IconButton(icon: "Trash", help: "Remove from list") { queue.remove(job) }
            }
        }
    }

    // MARK: Transcript and summary

    private var textStatusLine: some View {
        HStack(spacing: 8) {
            AccentPill(color: textColor)
            if job.textState.isActive {
                ProgressView().controlSize(.mini)
            }
            Text(textStatusText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(textColor == Theme.failure ? Theme.failure : .secondary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    private var textColor: Color {
        switch job.textState {
        case .none, .waiting: Theme.neutral
        case .fetchingCaptions, .preparingAudio, .transcribing, .summarizing: Theme.active
        case .done: Theme.success
        case .failed: Theme.failure
        }
    }

    private var textStatusText: String {
        switch job.textState {
        case .none: ""
        case .waiting: "Transcript waiting for the previous one"
        case .fetchingCaptions: "Getting captions from YouTube…"
        case .preparingAudio: "No captions, preparing audio for speech recognition…"
        case .transcribing(let fraction):
            "Transcribing on this Mac" + (fraction.map { " · " + $0.formatted(.percent.precision(.fractionLength(0))) } ?? "") + "…"
        case .summarizing(let step, let total):
            total > 1 && step < total ? "Summarising part \(step) of \(total - 1)…" : "Writing summary…"
        case .done:
            [job.transcriptURL.map { _ in "Transcript" }, job.summaryURL.map { _ in "summary" }]
                .compactMap { $0 }.joined(separator: " and ") + " saved"
        case .failed(let message): message
        }
    }

    /// Open the transcript/summary, or make them for a finished download.
    @ViewBuilder
    private var textButtons: some View {
        if job.transcriptURL != nil {
            IconButton(icon: "DocumentText", help: "Open transcript") { queue.openTranscript(job) }
        } else if !job.textState.isActive {
            IconButton(icon: "DocumentText", help: "Make a transcript") { queue.requestText(for: job, summary: false) }
        }
        if job.summaryURL != nil {
            IconButton(icon: "MagicStar", help: "Open summary") { queue.openSummary(job) }
        } else if !job.textState.isActive, OnDeviceText.summaryStatus == .available {
            IconButton(icon: "MagicStar", help: "Summarise with Apple Intelligence") { queue.requestText(for: job, summary: true) }
        }
    }

    // MARK: Derived state

    private var showsProgressBar: Bool {
        switch job.state {
        case .fetchingInfo, .downloading, .processing: true
        default: false
        }
    }

    private var barFraction: Double? {
        switch job.state {
        case .downloading: job.progress.fraction
        default: nil  // fetching info / post-processing are indeterminate
        }
    }

    private var statusColor: Color {
        switch job.state {
        case .fetchingInfo, .queued: Theme.neutral
        case .downloading, .processing: Theme.active
        case .finished: Theme.success
        case .failed: Theme.failure
        case .cancelled: Theme.neutral
        }
    }

    private var statusTextColor: Color {
        if case .failed = job.state { return Theme.failure }
        return .secondary
    }

    private var statusText: String {
        switch job.state {
        case .fetchingInfo:
            return "Fetching video info…"
        case .queued:
            return "Waiting for a free slot"
        case .downloading:
            let p = job.progress
            var parts: [String] = []
            if job.options.mode == .video { parts.append("Stream \(job.streamIndex)") }
            if let fraction = p.fraction {
                parts.append(fraction.formatted(.percent.precision(.fractionLength(0))))
            }
            if let done = Format.bytes(p.downloadedBytes), let total = Format.bytes(p.totalBytes) {
                parts.append("\(done) of \(total)")
            }
            if let speed = Format.bytes(p.speed) { parts.append("\(speed)/s") }
            if let eta = Format.duration(p.eta) { parts.append("\(eta) left") }
            return parts.isEmpty ? "Starting download…" : parts.joined(separator: " · ")
        case .processing(let label):
            return label + "…"
        case .finished:
            return job.outputURL?.lastPathComponent ?? "Done"
        case .failed(let message):
            return message
        case .cancelled:
            return "Cancelled"
        }
    }
}
