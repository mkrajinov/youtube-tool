import Foundation

public struct DownloadProgress: Sendable, Equatable {
    public var downloadedBytes: Double?
    public var totalBytes: Double?
    public var speed: Double?        // bytes per second
    public var eta: Double?          // seconds

    public init(downloadedBytes: Double? = nil, totalBytes: Double? = nil, speed: Double? = nil, eta: Double? = nil) {
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.speed = speed
        self.eta = eta
    }

    /// 0...1, or nil when the total size is unknown.
    public var fraction: Double? {
        guard let done = downloadedBytes, let total = totalBytes, total > 0 else { return nil }
        return min(max(done / total, 0), 1)
    }
}

public enum YTDLPEvent: Sendable, Equatable {
    case progress(DownloadProgress)
    case postprocessing(String)
    case finishedFile(String)
    case log(String)
}

public enum ProgressParser {
    /// Parses one line of yt-dlp stdout produced with `YTDLPArguments.download`.
    public static func parse(line raw: String) -> YTDLPEvent {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if let rest = line.dropPrefix(YTDLPArguments.progressTag) {
            let fields = rest.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            func num(_ i: Int) -> Double? {
                guard i < fields.count else { return nil }
                return Double(fields[i].trimmingCharacters(in: .whitespaces))  // "NA" -> nil
            }
            return .progress(DownloadProgress(
                downloadedBytes: num(0),
                totalBytes: num(1) ?? num(2),
                speed: num(3),
                eta: num(4)
            ))
        }
        if let rest = line.dropPrefix(YTDLPArguments.postprocessTag) {
            return .postprocessing(prettyPostprocessor(rest))
        }
        if let rest = line.dropPrefix(YTDLPArguments.fileTag) {
            return .finishedFile(rest)
        }
        // Post-processor log lines, e.g. "[Merger] Merging formats into ...".
        if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
            let tag = String(line[line.index(after: line.startIndex)..<close])
            if postprocessorTags.contains(tag) {
                return .postprocessing(prettyPostprocessor(tag))
            }
        }
        return .log(line)
    }

    static let postprocessorTags: Set<String> = [
        "Merger", "ExtractAudio", "EmbedThumbnail", "ThumbnailsConvertor",
        "Metadata", "FFmpegMetadata", "FixupM4a", "FixupM3u8", "FixupDuplicateMoov",
        "VideoConvertor", "VideoRemuxer",
    ]

    static func prettyPostprocessor(_ name: String) -> String {
        switch name {
        case "Merger": "Merging video and audio"
        case "ExtractAudio": "Converting audio"
        case "EmbedThumbnail", "ThumbnailsConvertor": "Embedding thumbnail"
        case "Metadata", "FFmpegMetadata": "Writing metadata"
        case "VideoConvertor", "VideoRemuxer": "Converting video"
        case let n where n.hasPrefix("Fixup"): "Fixing container"
        case "MoveFiles": "Finishing"
        case "", "NA": "Post-processing"
        default: name
        }
    }

    /// Pulls the human-readable part out of an "ERROR: ..." line.
    public static func errorMessage(fromStderr stderr: String) -> String? {
        let errors = stderr
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { $0.hasPrefix("ERROR:") }
        guard let last = errors.last else { return nil }
        return String(last.dropFirst("ERROR:".count)).trimmingCharacters(in: .whitespaces)
    }
}

extension String {
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
