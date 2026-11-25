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
            // release-library.sh in atecce/lib, library-20261124-ec0112e (ec0112e9fd7496dd0d318ea2542d7eed8bee299e)
            url: "https://github.com/atecce/lib/releases/download/library-20261124-ec0112e/bibleFFI.xcframework.zip",
            checksum: "47154db6f88b2c70a1a1e6ba34d9021478aa4e34cffe65089594dec0582a030a"
        ),
        .target(
            name: "Library",
            dependencies: [
                .target(name: "bibleFFI")
            ]
        ),
    ]
)