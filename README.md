# Optimates

The equities dashboards of [atecce/lib](https://github.com/atecce/lib) as
an app, for iPhone and Mac: a company's stocks and flows, read from the
store through the Rust code in `lib`.

```
Optimates.xcodeproj    the iOS app (bundle ID pub.atec.optimates, team Y82E2K77P5)
Package.swift          the macOS app: swift run
Sources/Optimates/     the SwiftUI sources, shared by both
Library/               the Rust code as a Swift package: uniffi bindings and
                       a prebuilt xcframework, from a release of lib
simulator.sh           build and run the iOS app in the Simulator
```

## The Rust code

`Library/` is written by `lib`, not edited here. `Library/release.sh` in
lib builds `bibleFFI.xcframework` (iOS, iOS Simulator, macOS), publishes it
as a GitHub release, and with `--into` copies that build's Swift bindings
here and points `Library/Package.swift` at the release by URL and checksum:

```sh
# in a checkout of lib (branch swift-charts)
Library/release.sh --into ~/optimates
```

Then commit `Library/` here. The bindings and the binary must come from the
same build, which is why they move together.

Builds here, Xcode Cloud's included, download the binary and compile only
Swift.

## TestFlight

Xcode Cloud archives `Optimates` on pushes to `main` and sends the build to
TestFlight (internal testing). The app reads its data through Cloudflare;
its server token and Cloudflare Access credentials are entered once in the
app's settings and kept in the Keychain.
