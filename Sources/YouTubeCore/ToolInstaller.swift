import Foundation

/// The app bundle is signed and may be read-only, so `yt-dlp -U` can't update the bundled copy.
/// Instead the bundled yt-dlp is copied to Application Support and updated there.
public enum ToolInstaller {
    public struct BundledVersions: Decodable, Sendable, Equatable {
        public let ytdlp: String?
        public let deno: String?
        public let ffmpeg: String?

        enum CodingKeys: String, CodingKey {
            case ytdlp = "yt-dlp", deno, ffmpeg
        }
    }

    public static func bundledVersions(file: URL) -> BundledVersions? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(BundledVersions.self, from: data)
    }

    public enum Outcome: Equatable, Sendable {
        case noBundledCopy
        case installed          // copy was missing
        case replaced(old: String?)  // bundled release is newer than the copy
        case keptExisting       // copy is the same or newer (e.g. after -U)
    }

    /// Makes sure `destinationDir/yt-dlp` exists and is at least as new as the bundled one.
    @discardableResult
    public static func prepareUpdatableYTDLP(
        bundledDir: URL,
        bundledVersion: String?,
        destinationDir: URL,
        installedVersion: @Sendable (URL) async -> String?,
        fileManager: FileManager = .default
    ) async throws -> Outcome {
        let source = bundledDir.appendingPathComponent("yt-dlp")
        guard fileManager.isExecutableFile(atPath: source.path) else { return .noBundledCopy }
        let target = destinationDir.appendingPathComponent("yt-dlp")

        var outcome = Outcome.installed
        if fileManager.isExecutableFile(atPath: target.path) {
            let current = await installedVersion(target)
            if let current, let bundledVersion, !ToolVersion.isNewer(bundledVersion, than: current) {
                return .keptExisting
            }
            if current != nil, bundledVersion == nil { return .keptExisting }
            outcome = .replaced(old: current)
        }

        try fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        let staging = destinationDir.appendingPathComponent("yt-dlp.installing")
        try? fileManager.removeItem(at: staging)
        try fileManager.copyItem(at: source, to: staging)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
        if fileManager.fileExists(atPath: target.path) {
            _ = try fileManager.replaceItemAt(target, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: target)
        }
        return outcome
    }
}
