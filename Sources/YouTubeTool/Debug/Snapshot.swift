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
            render(SettingsView(scrollable: false).environment(queue),
                   scheme: scheme, to: dir.appendingPathComponent("settings-\(suffix).png"))
        }
        exit(0)
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
        setSampleJobs([
            job("Designing Data-Intensive Applications — talk", .audio, .downloading, fraction: 0.62),
            job("BGP explained in 20 minutes", .video, .processing("Merging video and audio")),
            job("Kubernetes networking deep dive", .audio, .finished),
            job("Private video", .audio, .failed("[youtube] x: Video unavailable")),
            job("Fetching…", .video, .fetchingInfo),
        ])
    }
}
#endif
