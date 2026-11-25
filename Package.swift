// swift-tools-version:5.9
// Optimates, the equities dashboards as an app, reading lib's equities API
// (equities/api, at api.atec.pub behind Cloudflare Access). This package is
// the macOS app; Optimates.xcodeproj builds the same sources for iOS.
//
//     set -a; source ~/.cloudflared/equities-app.env; set +a; swift run

import PackageDescription

let package = Package(
    name: "Optimates",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Optimates"),
    ]
)
