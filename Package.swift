// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Netzblick",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Netzblick",
            path: "Sources/Netzblick",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        )
    ]
)
