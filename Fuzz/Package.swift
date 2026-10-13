// swift-tools-version:5.9
import PackageDescription

// libFuzzer harness. Separate package so the main package never depends on
// sanitizer flags. Requires the swift.org toolchain (see build.sh / README):
// Xcode's toolchain does not support -sanitize=fuzzer.
let package = Package(
    name: "SwiftRARFuzz",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "..")],
    targets: [
        .executableTarget(
            name: "SwiftRARFuzz",
            dependencies: [.product(name: "SwiftRAR", package: "SwiftRAR")]
        ),
    ]
)
