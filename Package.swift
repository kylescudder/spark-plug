// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SparkPlug",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SparkPlug",
            path: "Sources/SparkPlug"
        )
    ]
)
