import Foundation
import YouTubeCore

/// UserDefaults keys shared by @AppStorage in views and the queue.
enum SettingsKey {
    static let outputDirectory = "outputDirectory"
    static let ytdlpPath = "ytdlpPath"
    static let ffmpegPath = "ffmpegPath"
    static let maxConcurrent = "maxConcurrent"
    static let embedMetadata = "embedMetadata"
    static let lastMode = "lastMode"
    static let lastAudioFormat = "lastAudioFormat"
    static let wantTranscript = "wantTranscript"
    static let wantSummary = "wantSummary"
    static let playlistOwnFolder = "playlistOwnFolder"
    static let playlistNumbered = "playlistNumbered"
}

enum AppSettings {
    static var defaultOutputDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YouTubeTool", isDirectory: true)
    }

    static func register() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.outputDirectory: defaultOutputDirectory.path,
            SettingsKey.ytdlpPath: "",
            SettingsKey.ffmpegPath: "",
            SettingsKey.maxConcurrent: 2,
            SettingsKey.embedMetadata: true,
            SettingsKey.lastMode: DownloadMode.audio.rawValue,
            SettingsKey.lastAudioFormat: AudioFormat.m4a.rawValue,
            SettingsKey.wantTranscript: false,
            SettingsKey.wantSummary: false,
            SettingsKey.playlistOwnFolder: true,
            SettingsKey.playlistNumbered: false,
        ])
    }

    static var outputDirectory: URL {
        let path = UserDefaults.standard.string(forKey: SettingsKey.outputDirectory) ?? ""
        return path.isEmpty ? defaultOutputDirectory : URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    static var maxConcurrent: Int {
        min(max(UserDefaults.standard.integer(forKey: SettingsKey.maxConcurrent), 1), 4)
    }

    static var embedMetadata: Bool { UserDefaults.standard.bool(forKey: SettingsKey.embedMetadata) }
    static var ytdlpOverride: String? { UserDefaults.standard.string(forKey: SettingsKey.ytdlpPath) }
    static var ffmpegOverride: String? { UserDefaults.standard.string(forKey: SettingsKey.ffmpegPath) }

    /// "~/Downloads/YouTubeTool"
    static func abbreviated(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}
