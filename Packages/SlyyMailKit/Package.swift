// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SlyyMailKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "SlyyMailKit", targets: ["SlyyMailKit"]),
    ],
    targets: [
        .target(name: "SlyyMailKit"),
        .testTarget(name: "SlyyMailKitTests", dependencies: ["SlyyMailKit"], resources: [.copy("Fixtures")]),
    ]
)
