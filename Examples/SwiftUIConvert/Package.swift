// swift-tools-version:5.9
import PackageDescription

// A SwiftUI consumer of SwiftRAR that uses only the published products.
// `ConvertUI` holds the view and model and builds for iOS and macOS;
// `SwiftUIConvert` is a minimal macOS app around it (`swift run`).
let package = Package(
    name: "SwiftUIConvert",
    platforms: [.iOS(.v16), .macOS(.v13)],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .target(
            name: "ConvertUI",
            dependencies: [.product(name: "SwiftRAR", package: "SwiftRAR")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .executableTarget(
            name: "SwiftUIConvert",
            dependencies: ["ConvertUI"],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
    ]
)
