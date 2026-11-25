# Optimates

The equities dashboards of [atecce/lib](https://github.com/atecce/lib) as
an app, for iPhone and Mac: a company's stocks and flows, read from lib's
equities API (`equities/api`, at `api.atec.pub`).

```
Optimates.xcodeproj    the iOS app (bundle ID pub.atec.optimates, team Y82E2K77P5)
Package.swift          the macOS app: swift run
Sources/Optimates/     the SwiftUI sources, shared by both
simulator.sh           build and run the iOS app in the Simulator
```

## The API

The app makes two requests, `GET /tickers` and `GET /dashboard`, to
`https://api.atec.pub`: a service on the Mac in lib that reads Postgres,
reached through a Cloudflare tunnel. Cloudflare Access stands in front of
it, and the service checks Access's signed assertion on every request too.

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
