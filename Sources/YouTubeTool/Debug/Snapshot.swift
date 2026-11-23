#if DEBUG
import AppKit
import SwiftUI
import YouTubeCore

/// Dev aid: `YouTubeTool --snapshot <dir>` renders the main and settings views with sample data to PNGs and exits.
@MainActor
enum Snapshot {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        AppSettings.register()
        let queue = DownloadQueue()
        queue.loadSamples()

        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .light ? "light" : "dark"
            render(ContentView().environment(queue).frame(width: 860, height: 680),
                   scheme: scheme, to: dir.appendingPathComponent("main-\(suffix).png"))
            // ScrollView content doesn't render offscreen, so draw the queue cards separately.
            let cards = VStack(spacing: 10) {
                ForEach(queue.jobs) { JobCard(job: $0) }
            }
            .padding(20)
            .frame(width: 820)
            .background(Theme.windowBackground)
            render(cards.environment(queue), scheme: scheme, to: dir.appendingPathComponent("queue-\(suffix).png"))
            render(playlistPreview.environment(queue), scheme: scheme,
                   to: dir.appendingPathComponent("playlist-\(suffix).png"))
            render(SettingsView(scrollable: false).environment(queue),
                   scheme: scheme, to: dir.appendingPathComponent("settings-\(suffix).png"))
        }
        exit(0)
    }

    private static var playlistPreview: some View {
        let titles: [(String, Double?)] = [
            ("Why linear algebra?", 642), ("Vectors, what even are they?", 594),
            ("Linear combinations, span, and basis vectors", 586), ("[Private video]", nil),
            ("Linear transformations and matrices", 659), ("Matrix multiplication as composition", 603),
            ("Three-dimensional linear transformations", 279), ("The determinant", 600),
            ("Inverse matrices, column space and null space", 755), ("Nonsquare matrices", 264),
        ]
        let entries = titles.enumerated().map { i, t in
            PlaylistEntry(id: String(format: "video%06d", i), title: t.0, url: "https://youtu.be/\(i)",
                          duration: t.1, channel: t.1 == nil ? nil : "Math Notebook", index: i + 1,
                          isUnavailable: t.1 == nil)
        }
        let info = PlaylistInfo(id: "PL1", title: "Linear algebra, visually", channel: "Math Notebook", entries: entries)
        let request = DownloadQueue.PlaylistRequest(url: "https://www.youtube.com/playlist?list=PL1", mode: .audio,
                                                    audioFormat: .m4a, text: .init(transcript: true))
        return PlaylistSheet(request: request, preview: info, downloaded: [entries[1].id])
    }

    /// `YouTubeTool --snapshot-windows <dir>`: real windows (main with sample jobs, playlist picker),
    /// light and dark, placed off screen. Call after the app finished launching.
    static func runWindowsSnapshotIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot-windows"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        AppSettings.register()
        let queue = DownloadQueue()
        queue.loadSamples()
        let links = """
            https://www.youtube.com/watch?v=dQw4w9WgXcQ
            https://youtu.be/jNQXAC9IVRw
            https://www.youtube.com/playlist?list=PLZHQObOWTQDPD3MizzM2xVFitgF8hE_ab
            """
        var windows: [(NSWindow, String)] = []
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let main = window(ContentView(initialText: links).environment(queue), size: NSSize(width: 860, height: 820))
            main.appearance = NSAppearance(named: appearance)
            WindowChrome.apply(to: main)
            windows.append((main, "window-main-\(name).png"))
            let sheet = window(playlistPreview.environment(queue), size: NSSize(width: 700, height: 620))
            sheet.appearance = NSAppearance(named: appearance)
            windows.append((sheet, "window-playlist-\(name).png"))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            for (window, file) in windows {
                guard let frameView = window.contentView?.superview,
                      let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { continue }
                frameView.cacheDisplay(in: frameView.bounds, to: rep)
                let url = dir.appendingPathComponent(file)
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                print("wrote \(url.path)")
            }
            exit(0)
        }
    }

    private static func window(_ view: some View, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: 200), size: size),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = Theme.windowBackgroundNS
        window.contentView = NSHostingView(rootView: view)
        window.setFrame(NSRect(origin: NSPoint(x: -4000, y: 200), size: size), display: true)
        window.orderFront(nil)
        return window
    }

    /// `YouTubeTool --snapshot-window <file.png>`: renders a real window, title bar and traffic lights
    /// included, placed off screen, then exits. Call after the app finished launching.
    static func runWindowSnapshotIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot-window"), i + 1 < args.count else { return }
        let out = URL(fileURLWithPath: args[i + 1])
        let queue = DownloadQueue()
        let window = NSWindow(contentRect: NSRect(x: -4000, y: 200, width: 860, height: 300),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: ContentView().environment(queue))
        window.setFrame(NSRect(x: -4000, y: 200, width: 860, height: 300), display: true)
        WindowChrome.apply(to: window)
        window.orderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let frameView = window.contentView?.superview,
                  let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { exit(1) }
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out)
            print("wrote \(out.path)")
            exit(0)
        }
    }

    private static func render(_ view: some View, scheme: ColorScheme, to url: URL) {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            print("failed to render \(url.lastPathComponent)")
            return
        }
        try? png.write(to: url)
        print("wrote \(url.path)")
    }
}

extension DownloadQueue {
    func loadSamples() {
        let dir = AppSettings.outputDirectory
        func job(_ title: String, _ mode: DownloadMode, _ state: DownloadJob.State, fraction: Double? = nil) -> DownloadJob {
            let j = DownloadJob(url: "https://youtu.be/x", options: DownloadOptions(mode: mode, outputDirectory: dir))
            j.metadata = VideoMetadata(id: "x", title: title, channel: "Some Channel", duration: 754)
            j.state = state
            if let fraction {
                j.progress = DownloadProgress(downloadedBytes: 48_000_000 * fraction, totalBytes: 48_000_000, speed: 3_200_000, eta: 9)
            }
            if state == .finished { j.outputURL = dir.appendingPathComponent("\(title) [x].m4a") }
            return j
        }
        let summarised = job("Kubernetes networking deep dive", .audio, .finished)
        summarised.textState = .done
        summarised.transcriptURL = dir.appendingPathComponent("k.transcript.txt")
        summarised.summaryURL = dir.appendingPathComponent("k.summary.md")
        let transcribing = job("Interview without captions", .audio, .finished)
        transcribing.textState = .transcribing(0.37)
        let fromPlaylist = job("Vectors, what even are they?", .audio, .queued)
        fromPlaylist.playlistLabel = "Linear algebra, visually #2"
        setSampleJobs([
            fromPlaylist,
            job("Distributed systems in one hour", .audio, .downloading, fraction: 0.62),
            job("BGP explained in 20 minutes", .video, .processing("Merging video and audio")),
            transcribing,
            summarised,
            job("Plain download", .audio, .finished),
            job("Private video", .audio, .failed("[youtube] x: Video unavailable")),
            job("Fetching…", .video, .fetchingInfo),
        ])
    }
}
#endif
