# Optimates

The equities dashboards of [atecce/lib](https://github.com/atecce/lib) as
an app, for iPhone and Mac: a company's stocks and flows, read from lib's
equities API (`equities/api`, at `api.atec.pub`).

```
Optimates.xcodeproj    the iOS app (bundle ID pub.atec.optimates, team Y82E2K77P5)
Package.swift          the macOS app: swift run
Sources/Optimates/     the SwiftUI sources, shared by both
  Generated/           the API's messages and client, from Proto/ (proto.sh)
Proto/                 the API's contract, equities.proto, copied from lib
proto.sh               copy the .proto from lib and generate the Swift
simulator.sh           build and run the iOS app in the Simulator
```

## The API

The app makes two calls, `Tickers` and `Dashboard`, to
`https://api.atec.pub`: a service on the Mac in lib that reads Postgres,
reached through a Cloudflare tunnel. Cloudflare Access stands in front of
it, and the service checks Access's signed assertion on every request too.

## The contract

`Proto/equities/v1/equities.proto` is the API, the same file lib serves
from (`equities/api/proto`). `proto.sh` copies it from a checkout of lib and
generates `Sources/Optimates/Generated`: the messages (swift-protobuf) and
a typed client (connect-swift). Items, periods and market fields are enums
(`.totalAssets`, `.quarter`, `.marketCap`), so a line the API doesn't know
doesn't compile. Calls travel as the Connect protocol, protobuf over plain
HTTP POST.

```sh
./proto.sh            # after changing the .proto in lib; commit all it writes
```

The packages are pinned exactly, the same in `Package.swift` and
`Optimates.xcodeproj`, and `proto.sh` builds the generators from them, so
generated code and runtime match. connect-swift 1.2.0 and swift-protobuf
1.34.1 are the last releases that build with Xcode 15.4 (Swift 5.10).

## Signing in

The app gets through Access in one of two ways:

- **A person**: Server settings → Sign in with email. Access sends a
  one-time code, and the session it sets (`CF_Authorization`) is kept in
  the Keychain and sent as `cf-access-token`. It lasts a month.
- **The Mac and scripts**: the `equities-app` service token, from
  `~/.cloudflared/equities-app.env`, in the environment or in settings:

  ```sh
  set -a; source ~/.cloudflared/equities-app.env; set +a; swift run
  ```

`EQUITIES_API=http://localhost:8787` points the app at a local
`equities-api --no-access` instead.

The app is plain Swift: no Rust, no database credentials, nothing but the
session.

## TestFlight

Xcode Cloud (workflow "Default") archives `Optimates` on every push to
`main`, prepared for the App Store, so each build is uploaded to App Store
Connect and appears in TestFlight; the internal testing group 家人 (jiārén),
with automatic distribution, sends it to the phone. Nothing goes to the App
Store unless submitted by hand.
