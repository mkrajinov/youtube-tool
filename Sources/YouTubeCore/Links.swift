import Foundation

/// What a YouTube link points at.
public enum YouTubeLink: Equatable, Sendable {
    /// One video. `playlistURL` is set when the link was opened from a playlist (`&list=`).
    case video(url: String, playlistURL: String?)
    /// A playlist or a channel tab, normalised so yt-dlp lists its videos.
    case playlist(url: String)

    public static func classify(_ text: String) -> YouTubeLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard YTDLPArguments.isLikelyYouTubeURL(trimmed),
              let components = URLComponents(string: trimmed),
              let host = components.host?.lowercased() else { return nil }
        let query = components.queryItems ?? []
        func param(_ name: String) -> String? {
            query.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        let list = param("list").map(playlistURL)
        let segments = components.path.split(separator: "/").map(String.init)

        if host == "youtu.be" || host.hasSuffix(".youtu.be") {
            return segments.isEmpty ? nil : .video(url: trimmed, playlistURL: list)
        }
        guard let first = segments.first?.lowercased() else { return nil }
        switch first {
        case "watch":
            if param("v") != nil { return .video(url: trimmed, playlistURL: list) }
            return list.map { .playlist(url: $0) }
        case "playlist":
            return list.map { .playlist(url: $0) }
        case "shorts", "live", "embed", "v":
            return segments.count > 1 ? .video(url: trimmed, playlistURL: list) : nil
        case "channel", "c", "user":
            guard segments.count > 1 else { return nil }
            return .playlist(url: channelURL(host: host, base: segments.prefix(2), tab: segments.dropFirst(2).first))
        default:
            if first.hasPrefix("@") {
                return .playlist(url: channelURL(host: host, base: segments.prefix(1), tab: segments.dropFirst().first))
            }
            return nil
        }
    }

    public var url: String {
        switch self {
        case .video(let url, _), .playlist(let url): url
        }
    }

    static func playlistURL(_ id: String) -> String {
        "https://www.youtube.com/playlist?list=\(id)"
    }

    /// A channel's front page lists Videos, Shorts and Live as sub-playlists; go to Videos instead.
    private static func channelURL(host: String, base: ArraySlice<String>, tab: String?) -> String {
        let tab = tab.map { $0.lowercased() == "featured" ? "videos" : $0 } ?? "videos"
        let site = host.hasPrefix("music.") ? host : "www.youtube.com"
        return "https://\(site)/\(base.joined(separator: "/"))/\(tab)"
    }
}

public enum LinkExtractor {
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?:https?://)?(?:[a-z0-9-]+\.)*(?:youtube\.com|youtu\.be|youtube-nocookie\.com)/[^\s<>"'`\])}|,]*"#,
        options: [.caseInsensitive])

    /// Every YouTube link in a piece of text (a pasted list, a .txt or Markdown file), in order,
    /// without duplicates. Links without "https://" get it added.
    public static func links(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        var result: [String] = []
        for match in pattern.matches(in: text, range: range) {
            guard let r = Range(match.range, in: text) else { continue }
            var link = String(text[r])
            while let last = link.last, ".;:!?".contains(last) { link.removeLast() }
            if !link.lowercased().hasPrefix("http") { link = "https://" + link }
            if YTDLPArguments.isLikelyYouTubeURL(link), seen.insert(link).inserted {
                result.append(link)
            }
        }
        return result
    }
}
