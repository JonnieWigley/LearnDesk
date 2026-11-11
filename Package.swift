// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LearnDesk",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "LearnDesk", path: "Sources/LearnDesk")
    ]
)
