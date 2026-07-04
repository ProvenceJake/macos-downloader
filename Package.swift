// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MacOSDownloader",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MacOSDownloader", targets: ["MacOSDownloader"])
    ],
    targets: [
        .executableTarget(
            name: "MacOSDownloader",
            path: "Sources/MacOSDownloader"
        )
    ]
)
