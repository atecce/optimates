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
Sources/Optimates/Cache.swift  the most recently used replies, on the device (SwiftData)
Sources/Optimates/Portfolio.swift  the owner's brokerage holdings and unrealized gains
Tests/OptimatesTests/  the contract (golden bytes, shared with lib) and the charts' logic
ci_scripts/            Xcode Cloud: build with the newest swift-protobuf
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
generates `Sources/Optimates/Generated`: the messages (swift-protobuf). The
client is `API` in `Series.swift`, about 50 lines on URLSession: each rpc a
`Method<Input, Output>`, so a call can only send and expect its own messages. Items, periods and market fields are enums
(`.totalAssets`, `.quarter`, `.marketCap`), so a line the API doesn't know
doesn't compile. Calls travel as the Connect protocol, protobuf over plain
HTTP POST.

```sh
./proto.sh            # after changing the .proto in lib; commit all it writes
```

swift-protobuf is the only dependency, pinned exactly, the same in
`Package.swift` and `Optimates.xcodeproj`; `proto.sh` builds the generator
from it, so generated code and runtime match. 1.34.1 is the last release
that builds with Xcode 15.4 (Swift 5.10). `proto.sh` needs protoc 3.15 or
later (`brew install protobuf`).

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

## Tests and the newest dependencies

`swift test` on the Mac, or the scheme's test action (the `OptimatesTests`
target, in the Simulator), runs the tests:

- the contract: a request and a response as hex, the same bytes lib's
  `equities/api` tests write with Rust, read and written here with the Swift
  generated from the same `.proto`;
- what the charts compute from the data (the crosshair's values).

Xcode Cloud builds with the newest swift-protobuf 1.x, not the pin:
`ci_scripts/ci_post_clone.sh` raises the pin, resolves the packages again and
regenerates the Swift with that release's generator, all before the build.
The Mac, which can't build those, keeps the pin and smoke-tests; the
workflow's test action tests the cloud's build. `OPTIMATES_PINNED=1` in the
workflow's environment builds the pin instead.

## On the device

The app keeps the API's most recent replies (the company list and the 40
most recently opened companies) in SwiftData, in Caches: as the protobuf
bytes that arrived, so the `.proto` stays the only schema. A screen shows
what's kept at once, marked "Saved …", then replaces it with the API's
answer; offline, what's kept stays, with why it wasn't updated. The system
may clear Caches; signing out does.

## Portfolio

At the top of the company list: the owner's brokerage accounts (lib's
`plaid`, through the API's `Holdings`), each position's value and unrealized
gain, and the totals. Shorts gain as their price falls; options are shown by
value only, for now. Pull to refresh syncs with the brokerage. Only the owner
sees it: the API refuses everyone else, family included.

## π and r

Below the portfolio: inflation (core PCE, PCE, CPI over a year, and expected
inflation, Cleveland Fed and Michigan), the fed funds rate against Taylor's
rule (r* 2, as in 1993, and 0.5), the 10-year Treasury against TIPS and
breakeven inflation, and the output and unemployment gaps (CBO). From FRED,
through the API's `Macro`; the arithmetic (`Macro.swift`) is tested.

## Real estate

Mortgage rates against the 10-year (and their spread), house prices against
rents over a year and as a price-to-rent index, the monthly payment on the
median house sold (20% down, 30 years fixed, at the rate of the day),
building and sales, months of supply, delinquency and debt service, and
homeownership against rental vacancy. From FRED (lib's fred/realestate.txt),
like π and r: both are `FREDScreen`s, panels over the API's `Macro`.
