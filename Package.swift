// swift-tools-version:5.9
import PackageDescription

// License split:
//   RARCore, CBZWriter, SwiftRAR  -> MIT (LICENSE)
//   RARDecode                     -> unRAR license (Sources/RARDecode/LICENSE-UNRAR)
// The SwiftRAR product links RARDecode, so it carries both licenses;
// the RARCore and CBZWriter products are MIT only. See NOTICE.
let package = Package(
    name: "SwiftRAR",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "SwiftRAR", targets: ["SwiftRAR"]),
        .library(name: "CBZWriter", targets: ["CBZWriter"]),
        .library(name: "RARCore", targets: ["RARCore"]),
    ],
    targets: [
        .target(name: "RARCore"),
        .target(
            name: "RARDecode",
            dependencies: ["RARCore"],
            exclude: ["LICENSE-UNRAR"]
        ),
        .target(name: "CBZWriter", dependencies: ["RARCore"]),
        .target(name: "SwiftRAR", dependencies: ["RARCore", "RARDecode", "CBZWriter"]),
        .testTarget(
            name: "SwiftRARTests",
            dependencies: ["SwiftRAR", "RARCore", "RARDecode", "CBZWriter"]
        ),
    ]
)
