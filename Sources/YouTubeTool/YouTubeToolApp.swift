import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let queue: DownloadQueue

    override init() {
        #if DEBUG
        Snapshot.runIfRequested()
        TextCheck.runIfRequested()
        #endif
        AppSettings.register()
        queue = DownloadQueue()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (swift run) rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        #if DEBUG
        Snapshot.runWindowSnapshotIfRequested()
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        queue.cancelAll()  // don't leave yt-dlp/ffmpeg running
    }
}

@main
struct YouTubeToolApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("YouTube Tool", id: "main") {
            ContentView()
                .environment(appDelegate.queue)
                .frame(minWidth: 760, minHeight: 560)
        }
        .defaultSize(width: 860, height: 680)
        // No visible title bar: content runs to the top, traffic lights float over it.
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)

        Settings {
            SettingsView()
                .environment(appDelegate.queue)
        }
        .windowResizability(.contentSize)  // window is exactly the 600×560 content, not stretchable
    }
}
