// swift-tools-version:5.9
// Optimates, the equities dashboards as an app, reading InfluxDB through the
// Rust `influx` crate of atecce/lib (Library: its uniffi bindings and a
// prebuilt xcframework from a lib release). This package is the macOS app;
// Optimates.xcodeproj builds the same sources for iOS.
//
//     source ~/.profile && swift run

import PackageDescription

let package = Package(
    name: "Optimates",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "Library")],
    targets: [
        .executableTarget(
            name: "Optimates",
            dependencies: [.product(name: "Library", package: "Library")],
            // The Rust static library's HTTP client (reqwest) reads proxy
            // settings and uses the system's certificates.
            linkerSettings: [.linkedFramework("SystemConfiguration"), .linkedFramework("Security")]
        ),
    ]
)
