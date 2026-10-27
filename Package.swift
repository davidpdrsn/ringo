// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ringo",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/dduan/TOMLDecoder", from: "0.4.5"),
    ],
    targets: [
        .executableTarget(
            name: "Ringo",
            dependencies: ["TOMLDecoder"]
        ),
        .testTarget(
            name: "RingoTests",
            dependencies: ["Ringo"]
        ),
    ]
)
