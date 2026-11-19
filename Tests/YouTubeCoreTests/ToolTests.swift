import Foundation
import Testing
@testable import YouTubeCore

@Suite struct ToolVersionTests {
    @Test func comparesDateVersions() {
        #expect(ToolVersion.isNewer("2026.10.26", than: "2026.9.30"))
        #expect(ToolVersion.isNewer("2026.10.26.1", than: "2026.10.26"))
        #expect(!ToolVersion.isNewer("2026.10.26", than: "2026.10.26"))
        #expect(!ToolVersion.isNewer("2025.12.1", than: "2026.1.1"))
    }
}

@Suite struct ClientEnvironmentTests {
    @Test func pathIsBuiltFromToolsOnly() {
        let client = YTDLPClient(
            executable: URL(fileURLWithPath: "/App/Helpers/yt-dlp"),
            jsRuntime: URL(fileURLWithPath: "/App/Helpers/deno"),
            toolDirectories: [URL(fileURLWithPath: "/App/Helpers")])
        let path = client.environment["PATH"] ?? ""
        #expect(path == "/App/Helpers:/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(!path.contains("homebrew"))
        #expect(client.commonArguments == ["--js-runtimes", "deno:/App/Helpers/deno"])
    }
}

@Suite struct LocatorAndInstallerTests {
    let fm = FileManager.default

    func makeDir() throws -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("ytt-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func makeExecutable(_ url: URL, _ content: String = "#!/bin/sh\n") throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    @Test func locatorPrefersUpdatableThenBundled() throws {
        let root = try makeDir()
        let bundled = root.appendingPathComponent("Helpers"), updatable = root.appendingPathComponent("bin")
        try makeExecutable(bundled.appendingPathComponent("yt-dlp"))
        try makeExecutable(bundled.appendingPathComponent("ffmpeg"))
        let locator = BinaryLocator(bundledDirectory: bundled, updatableDirectory: updatable, allowSystem: false)

        #expect(locator.locate("yt-dlp")?.source == .bundled)
        try makeExecutable(updatable.appendingPathComponent("yt-dlp"))
        #expect(locator.locate("yt-dlp")?.source == .updatable)
        #expect(locator.locate("ffmpeg")?.source == .bundled)
        #expect(locator.locate("deno") == nil)  // no Homebrew fallback when disabled
        #expect(locator.locate("ffmpeg", override: "/nope/ffmpeg") == nil)
    }

    @Test func installerCopiesThenRespectsNewerCopy() async throws {
        let root = try makeDir()
        let bundled = root.appendingPathComponent("Helpers"), dest = root.appendingPathComponent("bin")
        try makeExecutable(bundled.appendingPathComponent("yt-dlp"), "#!/bin/sh\necho bundled\n")
        let target = dest.appendingPathComponent("yt-dlp")

        // First launch: copy is created.
        var outcome = try await ToolInstaller.prepareUpdatableYTDLP(
            bundledDir: bundled, bundledVersion: "2026.10.26", destinationDir: dest,
            installedVersion: { _ in nil })
        #expect(outcome == .installed)
        #expect(fm.isExecutableFile(atPath: target.path))

        // After `yt-dlp -U` the copy is newer: keep it.
        try makeExecutable(target, "#!/bin/sh\necho updated\n")
        outcome = try await ToolInstaller.prepareUpdatableYTDLP(
            bundledDir: bundled, bundledVersion: "2026.10.26", destinationDir: dest,
            installedVersion: { _ in "2026.11.30" })
        #expect(outcome == .keptExisting)
        #expect(try String(contentsOf: target, encoding: .utf8).contains("updated"))

        // A newer app ships a newer yt-dlp: replace the old copy.
        outcome = try await ToolInstaller.prepareUpdatableYTDLP(
            bundledDir: bundled, bundledVersion: "2026.10.26", destinationDir: dest,
            installedVersion: { _ in "2026.9.1" })
        #expect(outcome == .replaced(old: "2026.9.1"))
        #expect(try String(contentsOf: target, encoding: .utf8).contains("bundled"))
    }
}
