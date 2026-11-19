import Foundation

/// Builds yt-dlp command lines. Kept pure so it can be unit tested.
public enum YTDLPArguments {
    public static let progressTag = "[ytt-progress]"
    public static let postprocessTag = "[ytt-post]"
    public static let fileTag = "[ytt-file]"

    public static let outputTemplate = "%(title)s [%(id)s].%(ext)s"

    public static func metadata(url: String) -> [String] {
        ["--dump-single-json", "--no-playlist", "--no-warnings", "--", url]
    }

    public static func download(url: String, options: DownloadOptions) -> [String] {
        var args: [String] = [
            "--no-playlist",
            "--newline",
            "--no-colors",
            // --print implies --quiet; undo that so "[Merger] ..." style log lines reach stdout,
            // and --progress keeps the progress lines coming.
            "--no-quiet",
            "--progress",
            "--progress-template",
            "download:\(progressTag)%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s",
            "--progress-template",
            "postprocess:\(postprocessTag)%(progress.postprocessor)s",
            "--print", "after_move:\(fileTag)%(filepath)s",
            "-P", options.outputDirectory.path,
            "-o", outputTemplate,
        ]

        if let ffmpeg = options.ffmpegLocation {
            args += ["--ffmpeg-location", ffmpeg.path]
        }

        switch options.mode {
        case .video:
            // Prefer H.264 + AAC so the mp4 plays in QuickTime; fall back to the best available.
            args += [
                "-f", "bv*[vcodec^=avc1]+ba[ext=m4a]/b[ext=mp4]/bv*+ba/b",
                "--merge-output-format", "mp4",
            ]
            if options.embedMetadata {
                args += ["--embed-metadata", "--embed-thumbnail"]
            }
        case .audio:
            args += ["-f", preferredAudioSelector(for: options.audioFormat)]
            args += ["-x", "--audio-format", options.audioFormat.rawValue, "--audio-quality", "0"]
            if options.embedMetadata {
                if options.audioFormat.supportsMetadata { args.append("--embed-metadata") }
                if options.audioFormat.supportsThumbnail { args.append("--embed-thumbnail") }
            }
        }

        args += ["--", url]
        return args
    }

    /// Picks a source stream that avoids re-encoding when possible.
    static func preferredAudioSelector(for format: AudioFormat) -> String {
        switch format {
        case .m4a: "ba[ext=m4a]/ba/b"
        case .opus: "ba[acodec=opus]/ba/b"
        case .mp3, .wav: "ba/b"
        }
    }

    /// Basic check that the input looks like a YouTube URL.
    public static func isLikelyYouTubeURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host()?.lowercased() else { return false }
        let hosts = ["youtube.com", "youtu.be", "youtube-nocookie.com"]
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
