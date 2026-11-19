import Foundation

/// One video in a playlist, from `yt-dlp --flat-playlist`.
public struct PlaylistEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let url: String
    public let duration: Double?
    public let channel: String?
    /// Position in the playlist, from 1.
    public let index: Int
    /// Private or deleted: listed by YouTube but can't be downloaded.
    public let isUnavailable: Bool

    public init(id: String, title: String, url: String, duration: Double? = nil,
                channel: String? = nil, index: Int, isUnavailable: Bool = false) {
        self.id = id
        self.title = title
        self.url = url
        self.duration = duration
        self.channel = channel
        self.index = index
        self.isUnavailable = isUnavailable
    }

    /// YouTube's standard 320x180 thumbnail (flat entries carry odd sizes or none).
    public var thumbnail: String { "https://i.ytimg.com/vi/\(id)/mqdefault.jpg" }

    /// Enough to show a job card and download; captions info is fetched later if needed.
    public var partialMetadata: VideoMetadata {
        VideoMetadata(id: id, title: title, channel: channel, duration: duration,
                      thumbnail: thumbnail, webpageURL: url)
    }
}

public struct PlaylistInfo: Sendable, Equatable, Decodable {
    public let id: String
    public let title: String
    public let channel: String?
    public let entries: [PlaylistEntry]

    public var totalDuration: Double {
        entries.reduce(0) { $0 + ($1.duration ?? 0) }
    }

    public init(id: String, title: String, channel: String?, entries: [PlaylistEntry]) {
        self.id = id
        self.title = title
        self.channel = channel
        self.entries = entries
    }

    private struct Raw: Decodable {
        let id: String?
        let title: String?
        let channel: String?
        let uploader: String?
        let url: String?
        let ieKey: String?
        let duration: Double?
        let availability: String?
        let entries: [Raw]?

        enum CodingKeys: String, CodingKey {
            case id, title, channel, uploader, url, duration, availability, entries
            case ieKey = "ie_key"
        }
    }

    public init(from decoder: any Decoder) throws {
        let raw = try Raw(from: decoder)
        id = raw.id ?? ""
        title = raw.title ?? "Playlist"
        channel = raw.channel ?? raw.uploader

        // Channel front pages nest playlists (Videos, Shorts, …); flatten them.
        var videos: [Raw] = []
        func collect(_ items: [Raw]) {
            for item in items {
                if let nested = item.entries { collect(nested) } else { videos.append(item) }
            }
        }
        collect(raw.entries ?? [])

        var seen = Set<String>()
        var result: [PlaylistEntry] = []
        for video in videos {
            guard let id = video.id, video.ieKey == nil || video.ieKey == "Youtube",
                  seen.insert(id).inserted else { continue }
            let title = video.title ?? id
            let hidden = ["private", "needs_auth", "subscriber_only", "premium_only"]
            let unavailable = (title.hasPrefix("[") && title.hasSuffix("]") && video.duration == nil)
                || hidden.contains(video.availability ?? "")
            result.append(PlaylistEntry(
                id: id, title: title,
                url: video.url ?? "https://www.youtube.com/watch?v=\(id)",
                duration: video.duration,
                channel: video.channel ?? video.uploader ?? channel,
                index: result.count + 1,
                isUnavailable: unavailable))
        }
        entries = result
    }
}

/// Folder and file names for playlist downloads.
public enum PlaylistNaming {
    /// A playlist title made safe as a folder name.
    public static func folderName(_ title: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: " -")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return cleaned.isEmpty ? "Playlist" : String(cleaned.prefix(120))
    }

    /// "07 - " for item 7 of 40, "007 - " for item 7 of 120.
    public static func numberPrefix(index: Int, count: Int) -> String {
        let width = max(2, String(count).count)
        let number = String(index)
        return String(repeating: "0", count: max(0, width - number.count)) + number + " - "
    }
}

/// Finds videos already downloaded into a folder, by the "[id]" tag in the file name.
public enum ExistingDownloads {
    private static let tag = try! NSRegularExpression(pattern: #"\[([A-Za-z0-9_-]{11})\]\.([A-Za-z0-9]+)$"#)

    /// Video ids that have a finished file with `fileExtension` (e.g. "mp4", "m4a").
    public static func ids(fromFileNames names: [String], fileExtension: String) -> Set<String> {
        var ids = Set<String>()
        for name in names {
            let range = NSRange(name.startIndex..., in: name)
            guard let match = tag.firstMatch(in: name, range: range),
                  let id = Range(match.range(at: 1), in: name),
                  let ext = Range(match.range(at: 2), in: name),
                  name[ext].lowercased() == fileExtension.lowercased() else { continue }
            ids.insert(String(name[id]))
        }
        return ids
    }

    public static func ids(in directory: URL, fileExtension: String) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return ids(fromFileNames: names, fileExtension: fileExtension)
    }
}
