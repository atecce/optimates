#!/bin/zsh
# Build the iOS app and run it in the Simulator, reading the equities API.
#
#     ./simulator.sh [DEVICE]      e.g. "iPhone 15 Pro" (the default)
#     EQUITIES_TICKER=aapl ./simulator.sh    # open a company at launch
#     EQUITIES_API=http://localhost:8787 ./simulator.sh   # a local equities-api --no-access
#
# The app gets through Cloudflare Access with the service token from
# ~/.cloudflared/equities-app.env, passed in its environment (a phone signs in
# with email instead). Needs jq (brew install jq).

# CF_ACCESS_CLIENT_ID and CF_ACCESS_CLIENT_SECRET.
set -a; source ~/.cloudflared/equities-app.env; set +a
device=${1:-iPhone 15 Pro}
# The directory this script is in.
cd ${0:A:h} || exit 1

# Several simulators can share a name (one per iOS version installed), so
# pick one by its ID: a running one if there is, else the newest iOS.
id=$(xcrun simctl list devices available -j | jq -r --arg name "$device" '
  [.devices | to_entries[] | select(.key | contains("iOS")) | .key as $os
   | .value[] | select(.name == $name) | {id: .udid, os: $os, booted: (.state == "Booted")}]
  | sort_by(.booted, .os) | last | .id // empty')
[ -n "$id" ] || { echo "no simulator named $device (xcrun simctl list devices)" >&2; exit 1 }

# Build for the Simulator into ./build (git-ignored).
xcodebuild -project Optimates.xcodeproj -scheme Optimates -configuration Debug \
  -destination "platform=iOS Simulator,id=$id" -derivedDataPath build \
  -quiet build || exit 1

# Boot the simulated phone, unless it is already running, and show it.
xcrun simctl boot $id 2>/dev/null
open -a Simulator

# Install the app, replacing any earlier build.
xcrun simctl install $id build/Build/Products/Debug-iphonesimulator/Optimates.app || exit 1

# Launch it. simctl passes variables prefixed SIMCTL_CHILD_ into the app's
# environment with the prefix removed. --terminate-running-process restarts
# the app if it was already open, so a new build takes effect.
SIMCTL_CHILD_CF_ACCESS_CLIENT_ID=$CF_ACCESS_CLIENT_ID SIMCTL_CHILD_CF_ACCESS_CLIENT_SECRET=$CF_ACCESS_CLIENT_SECRET \
  SIMCTL_CHILD_EQUITIES_API=$EQUITIES_API SIMCTL_CHILD_EQUITIES_TICKER=$EQUITIES_TICKER \
  xcrun simctl launch --terminate-running-process $id pub.atec.optimates
