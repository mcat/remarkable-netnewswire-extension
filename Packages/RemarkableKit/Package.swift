// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RemarkableKit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "RemarkableKit", targets: ["RemarkableKit"])
    ],
    targets: [
        .target(
            name: "RemarkableKit",
            path: "Sources/RemarkableKit"
        ),
        .testTarget(
            name: "RemarkableKitTests",
            dependencies: ["RemarkableKit"],
            path: "Tests/RemarkableKitTests"
        )
    ]
)
