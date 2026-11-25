// swift-tools-version:5.5
// The swift-tools-version declares the minimum version of Swift required to build this package.
// Swift Package: Library

import PackageDescription;

let package = Package(
    name: "Library",
    platforms: [
        .macOS(.v12), .iOS(.v15)
    ],
    products: [
        .library(
            name: "Library",
            targets: ["Library"]
        )
    ],
    dependencies: [ ],
    targets: [
        .binaryTarget(
            name: "bibleFFI",
            // Library/release.sh in atecce/lib, library-20261124-799ae11 (799ae1111c648f0f331a86d3239bb03a47266d03)
            url: "https://github.com/atecce/lib/releases/download/library-20261124-799ae11/bibleFFI.xcframework.zip",
            checksum: "884d4b28e0e91e428f3cb691034f0f6665fcb73f54f1f2598c78955cfd473abf"
        ),
        .target(
            name: "Library",
            dependencies: [
                .target(name: "bibleFFI")
            ]
        ),
    ]
)