import AppKit
import SwiftUI
import YouTubeCore

struct SettingsView: View {
    @Environment(DownloadQueue.self) private var queue

    @AppStorage(SettingsKey.outputDirectory) private var outputPath = AppSettings.defaultOutputDirectory.path
    @AppStorage(SettingsKey.ytdlpPath) private var ytdlpPath = ""
    @AppStorage(SettingsKey.ffmpegPath) private var ffmpegPath = ""
    @AppStorage(SettingsKey.maxConcurrent) private var maxConcurrent = 2
    @AppStorage(SettingsKey.embedMetadata) private var embedMetadata = true

    @State private var showCustomPaths = false

    /// Kept for the snapshot tool; the view no longer scrolls.
    var scrollable = true

    var body: some View {
        content
            .frame(width: 600)
            .fixedSize(horizontal: false, vertical: true)  // window height follows the content
            .background(Theme.windowGradient.ignoresSafeArea())
            .background(HiddenTitleBar())
            .toolbar(removing: .title)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .onChange(of: ytdlpPath) { queue.refreshTools() }
            .onChange(of: ffmpegPath) { queue.refreshTools() }
            .onAppear { showCustomPaths = !ytdlpPath.isEmpty || !ffmpegPath.isEmpty }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card {
                SectionPill(text: "General")
                SettingRow(icon: "Folder2", title: "Save to",
                           hint: (outputPath as NSString).abbreviatingWithTildeInPath) {
                    HStack(spacing: 6) {
                        Button("Choose…", action: chooseFolder).buttonStyle(ChipButtonStyle())
                        Button("Reset") { outputPath = AppSettings.defaultOutputDirectory.path }
                            .buttonStyle(ChipButtonStyle())
                    }
                }
                SettingRow(icon: "Music", title: "Embed thumbnail & metadata",
                           hint: "Title, channel and cover art in the file") {
                    PillSwitch(isOn: $embedMetadata)
                }
                SettingRow(icon: "Timer1", title: "Parallel downloads",
                           hint: "Faster batches, but they share bandwidth") {
                    PillPicker(options: [1, 2, 3, 4], selection: $maxConcurrent, title: { "\($0)" })
                }
            }

            Card {
                SectionPill(text: "Tools")
                ytdlpRow
                toolRow(name: "ffmpeg + ffprobe", icon: "Video", found: queue.tools.ffmpeg,
                        version: queue.tools.ffmpeg?.source == .bundled ? queue.tools.bundled?.ffmpeg : nil,
                        purpose: "Merging and audio conversion")
                toolRow(name: "deno", icon: "Code", found: queue.tools.deno,
                        version: queue.tools.deno?.source == .bundled ? queue.tools.bundled?.deno : nil,
                        purpose: "YouTube's JavaScript checks")
                customPaths
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .padding(.top, 4)
    }

    /// Collapsed by default: a one-line row; expands to two path fields (the window grows to fit).
    @ViewBuilder
    private var customPaths: some View {
        SettingRow(icon: "Setting2", title: "Custom paths",
                   hint: showCustomPaths ? "Leave empty to use the built-in tools" : customPathsSummary,
                   tint: .secondary) {
            Button(showCustomPaths ? "Done" : "Edit") {
                withAnimation(.snappy(duration: 0.2)) { showCustomPaths.toggle() }
            }
            .buttonStyle(ChipButtonStyle())
        }
        if showCustomPaths {
            VStack(spacing: 8) {
                pathField("yt-dlp", text: $ytdlpPath)
                pathField("ffmpeg", text: $ffmpegPath)
            }
            .padding(.leading, 44)
            .transition(.opacity)
        }
    }

    private var customPathsSummary: String {
        let custom = [ytdlpPath.isEmpty ? nil : "yt-dlp", ffmpegPath.isEmpty ? nil : "ffmpeg"].compactMap { $0 }
        return custom.isEmpty ? "None, using the built-in tools" : "Custom: " + custom.joined(separator: ", ")
    }

    private var ytdlpRow: some View {
        let tool = queue.tools.ytdlp
        let version = queue.tools.ytdlpVersion.map { "v\($0)" }
        let hint = [tool?.source.label ?? "Not found", version].compactMap { $0 }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 6) {
            SettingRow(icon: "DocumentDownload", title: "yt-dlp", hint: hint,
                       tint: tool == nil ? Theme.failure : Theme.success) {
                Button { queue.updateYTDLP() } label: {
                    HStack(spacing: 6) {
                        if queue.updateState == .running {
                            ProgressView().controlSize(.mini)
                        } else {
                            Icon(name: "Refresh", size: 14)
                        }
                        Text(queue.updateState == .running ? "Updating…" : "Update")
                    }
                }
                .buttonStyle(GradientButtonStyle())
                .disabled(!queue.canUpdateYTDLP || queue.updateState == .running)
                .help(queue.canUpdateYTDLP ? "Download the latest yt-dlp. Use it when downloads start failing; YouTube changes often." : "Only the built-in copy can be updated here")
            }
            updateStatus.padding(.leading, 44)
        }
    }

    @ViewBuilder
    private var updateStatus: some View {
        switch queue.updateState {
        case .idle, .running:
            EmptyView()
        case .done(let message):
            HStack(spacing: 6) {
                AccentPill(color: Theme.success)
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        case .failed(let message):
            HStack(spacing: 6) {
                AccentPill(color: Theme.failure)
                Text(message).font(.system(size: 11)).foregroundStyle(Theme.failure).lineLimit(2)
            }
        }
    }

    private func toolRow(name: String, icon: String, found: LocatedTool?, version: String?, purpose: String) -> some View {
        let hint = [found?.source.label ?? "Not found", version.map { "v\($0)" }, purpose]
            .compactMap { $0 }.joined(separator: " · ")
        return SettingRow(icon: icon, title: name, hint: hint, tint: found == nil ? Theme.failure : Theme.success) {
            EmptyView()
        }
    }

    private func pathField(_ name: String, text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Text(name).font(.system(size: 12, weight: .semibold)).frame(width: 52, alignment: .leading)
            TextField("Built in", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.chipBackground))
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: outputPath)
        if panel.runModal() == .OK, let url = panel.url {
            outputPath = url.path
        }
    }
}

/// Icon chip + bold title + one-line muted hint + trailing control.
struct SettingRow<Trailing: View>: View {
    let icon: String
    let title: String
    let hint: String
    var tint: Color = Theme.accentStart
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            IconChip(name: icon, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .bold))
                Text(hint).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}
