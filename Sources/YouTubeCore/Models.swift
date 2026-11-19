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
    /// Put before the file name, e.g. "07 - " for numbered playlist downloads.
    public var filePrefix: String

    public init(
        mode: DownloadMode,
        audioFormat: AudioFormat = .m4a,
        outputDirectory: URL,
        embedMetadata: Bool = true,
        ffmpegLocation: URL? = nil,
        filePrefix: String = ""
    ) {
        self.mode = mode
        self.audioFormat = audioFormat
        self.outputDirectory = outputDirectory
        self.embedMetadata = embedMetadata
        self.ffmpegLocation = ffmpegLocation
        self.filePrefix = filePrefix
    }

    /// Extension of the finished file.
    public var fileExtension: String {
        mode == .video ? "mp4" : audioFormat.rawValue
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
    /// Spoken language as YouTube reports it, e.g. "en" (often missing).
    public let language: String?
    /// Languages with uploaded captions, e.g. ["en", "de-DE"].
    public let subtitleLanguages: [String]
    /// Languages with automatic captions; "<lang>-orig" marks the spoken language.
    public let automaticCaptionLanguages: [String]

    enum CodingKeys: String, CodingKey {
        case id, title, channel, uploader, duration, thumbnail, language, subtitles
        case webpageURL = "webpage_url"
        case automaticCaptions = "automatic_captions"
    }

    /// Only the keys of the caption dictionaries matter.
    private struct Ignored: Decodable {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        channel = try c.decodeIfPresent(String.self, forKey: .channel)
        uploader = try c.decodeIfPresent(String.self, forKey: .uploader)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        thumbnail = try c.decodeIfPresent(String.self, forKey: .thumbnail)
        webpageURL = try c.decodeIfPresent(String.self, forKey: .webpageURL)
        language = try? c.decodeIfPresent(String.self, forKey: .language)
        let subs = (try? c.decodeIfPresent([String: [Ignored]].self, forKey: .subtitles)) ?? nil
        let auto = (try? c.decodeIfPresent([String: [Ignored]].self, forKey: .automaticCaptions)) ?? nil
        subtitleLanguages = (subs?.keys).map { Array($0).sorted() } ?? []
        automaticCaptionLanguages = (auto?.keys).map { Array($0).sorted() } ?? []
    }

    public init(id: String, title: String, channel: String? = nil, uploader: String? = nil,
                duration: Double? = nil, thumbnail: String? = nil, webpageURL: String? = nil,
                language: String? = nil, subtitleLanguages: [String] = [], automaticCaptionLanguages: [String] = []) {
        self.id = id
        self.title = title
        self.channel = channel
        self.uploader = uploader
        self.duration = duration
        self.thumbnail = thumbnail
        self.webpageURL = webpageURL
        self.language = language
        self.subtitleLanguages = subtitleLanguages
        self.automaticCaptionLanguages = automaticCaptionLanguages
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
