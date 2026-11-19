import SwiftUI
import YouTubeCore

/// Lists a playlist's or channel's videos so the user can pick which to download.
struct PlaylistSheet: View {
    @Environment(DownloadQueue.self) private var queue
    let request: DownloadQueue.PlaylistRequest

    @AppStorage(SettingsKey.playlistOwnFolder) private var ownFolder = true
    @AppStorage(SettingsKey.playlistNumbered) private var numbered = false

    private enum Phase {
        case loading
        case failed(String)
        case loaded(PlaylistInfo)
    }

    @State private var phase = Phase.loading
    @State private var selected: Set<String> = []
    @State private var filter = ""
    /// Ids already downloaded, for the download folder (false) and the playlist's own folder (true).
    @State private var existing: [Bool: Set<String>] = [:]
    /// Videos already in the download list (e.g. the one whose link offered this playlist).
    @State private var inQueue: Set<String> = []
    private var scrollable = true

    init(request: DownloadQueue.PlaylistRequest) {
        self.request = request
    }

    #if DEBUG
    /// Snapshot rendering: start loaded, without a ScrollView (it doesn't render offscreen).
    init(request: DownloadQueue.PlaylistRequest, preview: PlaylistInfo, downloaded: Set<String>) {
        self.request = request
        scrollable = false
        _phase = State(initialValue: .loaded(preview))
        _existing = State(initialValue: [true: downloaded, false: []])
        _selected = State(initialValue: Set(preview.entries.filter { !$0.isUnavailable && !downloaded.contains($0.id) }
            .dropLast(2).map(\.id)))
    }
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch phase {
            case .loading: loadingView
            case .failed(let message): failedView(message)
            case .loaded(let info): loadedView(info)
            }
        }
        .padding(20)
        .frame(width: 700, height: 620)
        .background(Theme.windowBackground)
        .task(id: request.id) {
            if scrollable { await load() }  // not for snapshot previews
        }
    }

    // MARK: Loading

    private func load() async {
        phase = .loading
        filter = ""
        do {
            let info = try await queue.fetchPlaylist(request.url)
            let ext = DownloadOptions(mode: request.mode, audioFormat: request.audioFormat,
                                      outputDirectory: AppSettings.outputDirectory).fileExtension
            existing = [
                false: ExistingDownloads.ids(in: DownloadQueue.playlistDirectory(for: info, ownFolder: false), fileExtension: ext),
                true: ExistingDownloads.ids(in: DownloadQueue.playlistDirectory(for: info, ownFolder: true), fileExtension: ext),
            ]
            inQueue = Set(info.entries.map(\.id).filter { id in
                queue.jobs.contains { $0.state != .cancelled && ($0.metadata?.id == id || $0.url.contains(id)) }
            })
            let skip = (existing[ownFolder] ?? []).union(inQueue)
            selected = Set(info.entries.filter { !$0.isUnavailable && !skip.contains($0.id) }.map(\.id))
            phase = .loaded(info)
        } catch is CancellationError {
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("Reading the playlist…").font(.system(size: 13, weight: .semibold))
            Text(request.url).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Text("Long playlists and channels take a few seconds.").font(.system(size: 11)).foregroundStyle(.secondary)
            Button("Cancel") { queue.dismissPlaylist(request) }
                .buttonStyle(ChipButtonStyle())
                .keyboardShortcut(.cancelAction)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 12) {
            IconChip(name: "Warning2", tint: Theme.failure, size: 40)
            Text("Couldn't read the playlist").font(.system(size: 13, weight: .semibold))
            Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).textSelection(.enabled)
            HStack {
                Button("Close") { queue.dismissPlaylist(request) }
                    .buttonStyle(ChipButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button { Task { await load() } } label: {
                    HStack(spacing: 5) { Icon(name: "Refresh", size: 14); Text("Try again") }
                }
                .buttonStyle(ChipButtonStyle())
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
    }

    // MARK: Loaded

    private func loadedView(_ info: PlaylistInfo) -> some View {
        let done = existing[ownFolder] ?? []
        let visible = visibleEntries(info)
        return Group {
            header(info)
            controls(info, visible: visible)
            list(visible, done: done)
            footer(info, done: done)
        }
    }

    private func visibleEntries(_ info: PlaylistInfo) -> [PlaylistEntry] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return info.entries }
        return info.entries.filter {
            $0.title.localizedCaseInsensitiveContains(query) || ($0.channel?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private func header(_ info: PlaylistInfo) -> some View {
        HStack(spacing: 12) {
            IconChip(name: "MusicPlaylist", tint: Theme.accentStart, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(info.title).font(.system(size: 16, weight: .bold)).lineLimit(1)
                Text([info.channel, "\(info.entries.count) videos", Format.duration(info.totalDuration)]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func controls(_ info: PlaylistInfo, visible: [PlaylistEntry]) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Icon(name: "SearchNormal1", size: 14).foregroundStyle(.secondary)
                TextField("Filter", text: $filter).textFieldStyle(.plain).font(.system(size: 12))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Theme.chipBackground))
            .frame(maxWidth: 200)

            Button("All") { selected.formUnion(visible.filter { !$0.isUnavailable }.map(\.id)) }
                .buttonStyle(ChipButtonStyle())
            Button("None") { selected.subtract(visible.map(\.id)) }
                .buttonStyle(ChipButtonStyle())
            Spacer()
            TogglePill(title: "Own folder", icon: "Folder2", isOn: ownFolderToggle)
                .help("Save into a folder named after the playlist")
            TogglePill(title: "Numbered", icon: "Hashtag", isOn: $numbered)
                .help("Start each file name with its playlist position, e.g. \"07 - \"")
        }
    }

    /// Switching folders changes which videos count as already downloaded.
    private var ownFolderToggle: Binding<Bool> {
        Binding(get: { ownFolder }, set: { value in
            ownFolder = value
            selected.subtract(existing[value] ?? [])
        })
    }

    private func list(_ entries: [PlaylistEntry], done: Set<String>) -> some View {
        Group {
            if scrollable {
                ScrollView { rows(entries, done: done) }
            } else {
                rows(entries, done: done).frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .background(CardSurface(radius: 16))
    }

    private func rows(_ entries: [PlaylistEntry], done: Set<String>) -> some View {
            LazyVStack(spacing: 2) {
                ForEach(entries) { entry in
                    PlaylistRow(entry: entry, isSelected: selected.contains(entry.id),
                                isDownloaded: done.contains(entry.id), isInQueue: inQueue.contains(entry.id)) {
                        if selected.contains(entry.id) { selected.remove(entry.id) } else { selected.insert(entry.id) }
                    }
                }
                if entries.isEmpty {
                    Text("No videos match \"\(filter)\"")
                        .font(.system(size: 12)).foregroundStyle(.secondary).padding(30)
                }
            }
            .padding(8)
    }

    private func footer(_ info: PlaylistInfo, done: Set<String>) -> some View {
        let picked = info.entries.filter { selected.contains($0.id) }
        let duration = Format.duration(picked.reduce(0) { $0 + ($1.duration ?? 0) })
        let what = request.mode == .video ? "Video · mp4" : "Audio · \(request.audioFormat.rawValue)"
        let text = request.text.summary ? " + transcript + summary" : (request.text.transcript ? " + transcript" : "")
        let folder = AppSettings.abbreviated(DownloadQueue.playlistDirectory(for: info, ownFolder: ownFolder))
        let skipped = info.entries.filter { done.contains($0.id) && !selected.contains($0.id) }.count

        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(picked.count) of \(info.entries.count) selected" + (duration.map { " · \($0)" } ?? ""))
                    .font(.system(size: 12, weight: .semibold))
                Text("\(what)\(text) → \(folder)" + (skipped > 0 ? " · \(skipped) already downloaded" : ""))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("Cancel") { queue.dismissPlaylist(request) }
                .buttonStyle(ChipButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button {
                queue.enqueue(picked, from: info, request: request, ownFolder: ownFolder, numbered: numbered)
                queue.dismissPlaylist(request)
            } label: {
                HStack(spacing: 6) {
                    Icon(name: "DocumentDownload", size: 15)
                    Text(picked.isEmpty ? "Download" : "Download \(picked.count)")
                }
            }
            .buttonStyle(GradientButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(picked.isEmpty)
        }
    }
}

private struct PlaylistRow: View {
    let entry: PlaylistEntry
    let isSelected: Bool
    let isDownloaded: Bool
    let isInQueue: Bool
    let toggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            check
            Text("\(entry.index)")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 30, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if let channel = entry.channel {
                    Text(channel).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if entry.isUnavailable {
                tag("Unavailable", color: .secondary)
            } else if isDownloaded {
                tag("Downloaded", color: Theme.success)
            } else if isInQueue {
                tag("In queue", color: Theme.active)
            }
            Text(Format.duration(entry.duration) ?? "")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isHovered && !entry.isUnavailable ? Theme.chipBackground : .clear))
        .contentShape(Rectangle())
        .opacity(entry.isUnavailable ? 0.45 : 1)
        .onHover { isHovered = $0 }
        .onTapGesture { if !entry.isUnavailable { toggle() } }
    }

    @ViewBuilder private var check: some View {
        if isSelected {
            Icon(name: "TickCircle", size: 18).foregroundStyle(Theme.accentStart)
        } else {
            Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1.5).frame(width: 16, height: 16)
                .frame(width: 18, height: 18)
        }
    }

    private func tag(_ text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            AccentPill(color: color, length: 8)
            Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.1)))
    }
}
