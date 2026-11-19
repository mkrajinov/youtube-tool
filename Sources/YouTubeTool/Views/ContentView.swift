import AppKit
import SwiftUI
import YouTubeCore

struct ContentView: View {
    @Environment(DownloadQueue.self) private var queue

    @AppStorage(SettingsKey.lastMode) private var modeRaw = DownloadMode.audio.rawValue
    @AppStorage(SettingsKey.lastAudioFormat) private var formatRaw = AudioFormat.m4a.rawValue
    @AppStorage(SettingsKey.outputDirectory) private var outputPath = AppSettings.defaultOutputDirectory.path
    @AppStorage(SettingsKey.maxConcurrent) private var maxConcurrent = 2
    @AppStorage(SettingsKey.wantTranscript) private var wantTranscript = false
    @AppStorage(SettingsKey.wantSummary) private var wantSummary = false

    @State private var urlText = ""
    @State private var inputError: String?
    @State private var isDropTargeted = false
    @State private var summaryStatus = OnDeviceText.summaryStatus

    private var mode: Binding<DownloadMode> {
        Binding(get: { DownloadMode(rawValue: modeRaw) ?? .audio }, set: { modeRaw = $0.rawValue })
    }

    private var format: Binding<AudioFormat> {
        Binding(get: { AudioFormat(rawValue: formatRaw) ?? .m4a }, set: { formatRaw = $0.rawValue })
    }

    /// A summary is made from the transcript, so they switch on and off together.
    private var transcriptToggle: Binding<Bool> {
        Binding(get: { wantTranscript || wantSummary }, set: {
            wantTranscript = $0
            if !$0 { wantSummary = false }
        })
    }

    private var summaryToggle: Binding<Bool> {
        Binding(get: { wantSummary && summaryStatus == .available }, set: {
            wantSummary = $0
            if $0 { wantTranscript = true }
        })
    }

    private var textRequest: DownloadJob.TextRequest {
        DownloadJob.TextRequest(transcript: transcriptToggle.wrappedValue, summary: summaryToggle.wrappedValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if !queue.tools.isPreparing && !queue.tools.isReady { ToolsMissingCard() }
            inputCard
            queueSection
        }
        .padding(20)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            summaryStatus = OnDeviceText.summaryStatus  // e.g. Apple Intelligence just turned on
        }
        .background(Theme.windowGradient.ignoresSafeArea())
        .background(HiddenTitleBar())
        .dropDestination(for: URL.self) { urls, _ in
            let text = urls.map(\.absoluteString).joined(separator: "\n")
            return queue.enqueue(text, mode: mode.wrappedValue, audioFormat: format.wrappedValue,
                                 textRequest: textRequest) > 0
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.accentStart.opacity(0.08))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Icon(name: "DocumentDownload", size: 26)
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Theme.accent)
                        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(LinearGradient(colors: [.white.opacity(0.25), .clear], startPoint: .top, endPoint: .center)))
                )
                .shadow(color: Theme.accentStart.opacity(0.3), radius: 8, y: 3)
            VStack(alignment: .leading, spacing: 3) {
                Text("YouTube Tool").font(.system(size: 20, weight: .bold))
                Text(toolsSubtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { queue.openOutputFolder() } label: {
                HStack(spacing: 7) {
                    Icon(name: "Folder2", size: 17)
                    Text((outputPath as NSString).lastPathComponent).font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .help("Open \((outputPath as NSString).abbreviatingWithTildeInPath) in Finder")
            SettingsLink {
                Icon(name: "Setting2", size: 18)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Theme.chipBackground))
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
    }

    private var toolsSubtitle: String {
        let tools = queue.tools
        if tools.isPreparing { return "Preparing tools…" }
        guard tools.isReady else { return "Setup needed" }
        let ytdlp = tools.ytdlpVersion.map { "yt-dlp \($0)" } ?? "yt-dlp"
        let ffmpeg = tools.ffmpeg?.source == .bundled ? tools.bundled?.ffmpeg.map { "ffmpeg \($0)" } : nil
        let where_ = tools.ytdlp?.source == .system ? "Homebrew" : (tools.ytdlp?.source == .custom ? "custom" : "built in")
        return [ytdlp, ffmpeg ?? "ffmpeg", where_].joined(separator: " · ")
    }

    // MARK: Input

    private var inputCard: some View {
        Card {
            SectionPill(text: "New download")

            HStack(spacing: 10) {
                IconChip(name: "Link2", tint: Theme.accentStart)
                TextField("Paste a YouTube link (several separated by spaces or new lines)", text: $urlText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit(submit)
                Button {
                    if let s = NSPasteboard.general.string(forType: .string) { urlText = s }
                } label: {
                    HStack(spacing: 5) {
                        Icon(name: "ClipboardText", size: 14)
                        Text("Paste")
                    }
                }
                .buttonStyle(ChipButtonStyle())
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.chipBackground))

            HStack(alignment: .center, spacing: 14) {
                PillPicker(
                    options: DownloadMode.allCases,
                    selection: mode,
                    title: { $0.label },
                    icon: { $0 == .video ? "Video" : "Music" }
                )
                if mode.wrappedValue == .audio {
                    PillPicker(options: AudioFormat.allCases, selection: format, title: { $0.rawValue })
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
                Spacer()
                Button(action: submit) {
                    HStack(spacing: 6) {
                        Icon(name: "DocumentDownload", size: 15)
                        Text("Download")
                    }
                }
                .buttonStyle(GradientButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!queue.tools.isReady || urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            HStack(spacing: 6) {
                TogglePill(title: "Transcript", icon: "DocumentText", isOn: transcriptToggle)
                    .help("Save the video's text next to the file: YouTube captions, or speech recognition on this Mac when there are none")
                TogglePill(title: "Summary", icon: "MagicStar", isOn: summaryToggle,
                           isEnabled: summaryStatus == .available)
                    .help(summaryStatus == .available
                          ? "Summarise the transcript with Apple Intelligence, on this Mac"
                          : summaryStatus.message)
                if summaryStatus != .available {
                    Text(summaryStatus.message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
            }

            HStack(spacing: 6) {
                if let inputError {
                    Icon(name: "Warning2", size: 13).foregroundStyle(Theme.failure)
                    Text(inputError).foregroundStyle(Theme.failure)
                } else {
                    Icon(name: "Folder2", size: 13).foregroundStyle(.secondary)
                    Text(summaryLine).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11))
        }
    }

    private var summaryLine: String {
        let what = mode.wrappedValue == .video ? "Video · mp4 (H.264, up to 1080p)" : "Audio · \(formatRaw)"
        let dir = (outputPath as NSString).abbreviatingWithTildeInPath
        let text = summaryToggle.wrappedValue ? " + transcript + summary" : (transcriptToggle.wrappedValue ? " + transcript" : "")
        return "\(what)\(text) → \(dir) · up to \(maxConcurrent) at a time"
    }

    private func submit() {
        let added = queue.enqueue(urlText, mode: mode.wrappedValue, audioFormat: format.wrappedValue,
                                  textRequest: textRequest)
        if added > 0 {
            urlText = ""
            inputError = nil
        } else {
            inputError = "That doesn't look like a YouTube link."
        }
    }

    // MARK: Queue

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SectionPill(text: "Queue", color: .secondary)
                if !queue.jobs.isEmpty {
                    Text("\(queue.activeCount) active · \(queue.finishedCount) done")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if queue.finishedCount > 0 {
                    Button { queue.clearFinished() } label: {
                        HStack(spacing: 5) { Icon(name: "Broom", size: 14); Text("Clear finished") }
                    }
                    .buttonStyle(ChipButtonStyle())
                }
            }
            .frame(minHeight: 28)

            if queue.jobs.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(queue.jobs) { job in
                            JobCard(job: job)
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Icon(name: "DocumentDownload", size: 36).foregroundStyle(.tertiary)
            Text("No downloads yet").font(.system(size: 13, weight: .semibold))
            Text("Paste a link above, or drop one onto this window.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shown when yt-dlp or ffmpeg can't be found (bundle damaged, or a bad custom path).
struct ToolsMissingCard: View {
    @Environment(DownloadQueue.self) private var queue

    var body: some View {
        Card {
            HStack(spacing: 12) {
                IconChip(name: "Warning2", tint: Theme.failure)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(queue.tools.missing.joined(separator: " and ")) not found")
                        .font(.system(size: 13, weight: .bold))
                    Text("The app ships with these tools. Check custom paths in Settings, or rebuild with scripts/build-app.sh.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                SettingsLink {
                    HStack(spacing: 5) { Icon(name: "Setting2", size: 14); Text("Settings") }
                }
                .buttonStyle(ChipButtonStyle())
                Button { queue.refreshTools() } label: {
                    HStack(spacing: 5) { Icon(name: "Refresh", size: 14); Text("Check again") }
                }
                .buttonStyle(ChipButtonStyle())
            }
        }
    }
}
