import Foundation

public enum DownloadMode: String, CaseIterable, Sendable, Codable {
    case video
    case audio

    public var label: String {
        switch self {
        case .video: "Video"
        case .audio: "Audio only"
        }
    }
}

public enum AudioFormat: String, CaseIterable, Sendable, Codable {
    case m4a, mp3, opus, wav

    /// Formats where yt-dlp can embed cover art.
    public var supportsThumbnail: Bool {
        switch self {
        case .m4a, .mp3: true
        case .opus, .wav: false
        }
    }

    /// Formats that carry tags (title, artist, ...).
    public var supportsMetadata: Bool { self != .wav }
}

public struct DownloadOptions: Sendable, Equatable {
    public var mode: DownloadMode
    public var audioFormat: AudioFormat
    public var outputDirectory: URL
    public var embedMetadata: Bool
    public var ffmpegLocation: URL?

    public init(
        mode: DownloadMode,
        audioFormat: AudioFormat = .m4a,
        outputDirectory: URL,
        embedMetadata: Bool = true,
        ffmpegLocation: URL? = nil
    ) {
        self.mode = mode
        self.audioFormat = audioFormat
        self.outputDirectory = outputDirectory
        self.embedMetadata = embedMetadata
        self.ffmpegLocation = ffmpegLocation
    }

    /// Human readable short description, e.g. "Video · mp4" or "Audio · m4a".
    public var summary: String {
        switch mode {
        case .video: "Video · mp4"
        case .audio: "Audio · \(audioFormat.rawValue)"
        }
    }
}

/// Subset of `yt-dlp -J` output that the app needs.
public struct VideoMetadata: Sendable, Decodable, Equatable {
    public let id: String
    public let title: String
    public let channel: String?
    public let uploader: String?
    public let duration: Double?
    public let thumbnail: String?
    public let webpageURL: String?

    enum CodingKeys: String, CodingKey {
        case id, title, channel, uploader, duration, thumbnail
        case webpageURL = "webpage_url"
    }

    public init(id: String, title: String, channel: String? = nil, uploader: String? = nil,
                duration: Double? = nil, thumbnail: String? = nil, webpageURL: String? = nil) {
        self.id = id
        self.title = title
        self.channel = channel
        self.uploader = uploader
        self.duration = duration
        self.thumbnail = thumbnail
        self.webpageURL = webpageURL
    }

    public var author: String? { channel ?? uploader }
}

public enum Format {
    /// 754 -> "12:34", 3723 -> "1:02:03".
    public static func duration(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    public static func bytes(_ value: Double?) -> String? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }
}
