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
            // Library/release.sh in atecce/lib, library-20261124-ea6c256 (ea6c256a8f81f81b3266d2f5d7b215ce3e7fa213)
            url: "https://github.com/atecce/lib/releases/download/library-20261124-ea6c256/bibleFFI.xcframework.zip",
            checksum: "7098b41a0102f3aac48ebcae80c36ad33878676de43d0203e3b8afce0716c326"
        ),
        .target(
            name: "Library",
            dependencies: [
                .target(name: "bibleFFI")
            ]
        ),
    ]
)