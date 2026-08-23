// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Pictool",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Pictool",
            path: "Sources/Pictool"
        ),
        .testTarget(
            name: "PictoolTests",
            dependencies: ["Pictool"],
            path: "Tests/PictoolTests"
        ),
    ]
)
