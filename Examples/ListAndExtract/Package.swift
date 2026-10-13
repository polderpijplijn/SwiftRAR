// swift-tools-version:5.9
import PackageDescription

// A consumer of SwiftRAR outside the repository's own targets: it may use
// only the published products.
let package = Package(
    name: "ListAndExtract",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "ListAndExtract",
            dependencies: [.product(name: "SwiftRAR", package: "SwiftRAR")]
        ),
    ]
)
