// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "YouTubeTool",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "YouTubeTool", targets: ["YouTubeTool"]),
    ],
    targets: [
        // Pure logic: yt-dlp arguments, progress parsing, process handling. No UI.
        .target(name: "YouTubeCore"),
        // SwiftUI app.
        .executableTarget(name: "YouTubeTool", dependencies: ["YouTubeCore"]),
        .testTarget(name: "YouTubeCoreTests", dependencies: ["YouTubeCore"]),
    ]
)
