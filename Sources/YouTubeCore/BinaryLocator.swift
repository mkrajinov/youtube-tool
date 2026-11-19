import Foundation

/// Where a tool was found. Order of preference matches the cases.
public enum ToolSource: String, Sendable, Equatable {
    case custom          // path set in Settings
    case updatable       // ~/Library/Application Support/YouTubeTool/bin (yt-dlp only, self-updates)
    case bundled         // YouTubeTool.app/Contents/Helpers
    case system          // Homebrew / PATH (dev fallback)

    public var label: String {
        switch self {
        case .custom: "Custom path"
        case .updatable: "Bundled, updatable copy"
        case .bundled: "Bundled"
        case .system: "Homebrew"
        }
    }
}

public struct LocatedTool: Sendable, Equatable {
    public let url: URL
    public let source: ToolSource

    public init(url: URL, source: ToolSource) {
        self.url = url
        self.source = source
    }
}

/// Finds yt-dlp, ffmpeg, ffprobe and deno: custom path → updatable copy → app bundle → Homebrew.
public struct BinaryLocator: Sendable {
    public static let systemDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    public var bundledDirectory: URL?
    public var updatableDirectory: URL?
    /// Set YTT_NO_SYSTEM_TOOLS=1 to prove the app runs without Homebrew.
    public var allowSystem: Bool

    public init(bundledDirectory: URL?, updatableDirectory: URL?,
                allowSystem: Bool = ProcessInfo.processInfo.environment["YTT_NO_SYSTEM_TOOLS"] != "1") {
        self.bundledDirectory = bundledDirectory
        self.updatableDirectory = updatableDirectory
        self.allowSystem = allowSystem
    }

    public func locate(_ name: String, override: String? = nil,
                       fileManager: FileManager = .default) -> LocatedTool? {
        if let override = override?.trimmingCharacters(in: .whitespaces), !override.isEmpty {
            let path = (override as NSString).expandingTildeInPath
            return fileManager.isExecutableFile(atPath: path)
                ? LocatedTool(url: URL(fileURLWithPath: path), source: .custom) : nil
        }
        var candidates: [(URL, ToolSource)] = []
        if let updatableDirectory { candidates.append((updatableDirectory, .updatable)) }
        if let bundledDirectory { candidates.append((bundledDirectory, .bundled)) }
        if allowSystem {
            candidates += Self.systemDirectories.map { (URL(fileURLWithPath: $0), .system) }
        }
        for (dir, source) in candidates {
            let url = dir.appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: url.path) {
                return LocatedTool(url: url, source: source)
            }
        }
        return nil
    }

    /// Homebrew-only lookup, kept for tests and tooling.
    public static func locate(_ name: String) -> URL? {
        BinaryLocator(bundledDirectory: nil, updatableDirectory: nil, allowSystem: true).locate(name)?.url
    }
}

/// yt-dlp versions look like "2026.10.26" or "2026.10.26.1"; compare numerically.
public enum ToolVersion {
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").compactMap { Int($0) }
        let pb = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
