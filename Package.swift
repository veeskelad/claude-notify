// swift-tools-version:5.9
import PackageDescription

// Notchy.app is assembled from this executable by scripts/build-app.sh (Info.plist, signing).
let package = Package(
    name: "Notchy",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Notchy",
            path: "Sources/Notchy"
        ),
    ]
)
