// swift-tools-version:5.9
// Optimates, the equities dashboards as an app, reading lib's equities API
// (equities/api, at api.atec.pub behind Cloudflare Access) over Connect
// (a protobuf message POSTed, Sources/Optimates/Series.swift):
// Proto/equities/v1/equities.proto, compiled to Sources/Optimates/Generated
// by proto.sh. This package is the macOS app; Optimates.xcodeproj builds the
// same sources for iOS.
//
//     set -a; source ~/.cloudflared/equities-app.env; set +a; swift run Optimates

import PackageDescription

let package = Package(
    name: "Optimates",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Exact, and the same in Optimates.xcodeproj: proto.sh builds the
        // code generator from it, so generated code and runtime match.
        .package(url: "https://github.com/apple/swift-protobuf", exact: "1.34.1"),
    ],
    targets: [
        .executableTarget(
            name: "Optimates",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
    ]
)
