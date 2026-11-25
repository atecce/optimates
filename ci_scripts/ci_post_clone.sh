#!/bin/zsh
# Xcode Cloud runs this after cloning, before every action (archive, test).
#
# The Mac here has Xcode 15.4 (Swift 5.10), so Package.swift and the project
# pin swift-protobuf to the last release it can build. Xcode Cloud's Xcode is
# current, so here the build moves to the newest 1.x release: the pins are
# raised, the packages resolved again, and the Swift regenerated from the
# .proto by that release's own generator, so generated code and runtime still
# match. The Mac's builds are the smoke tests; the workflow's test action
# runs the tests against this build before it ships.
#
# OPTIMATES_PINNED=1 in the workflow's environment builds the pins as
# committed instead.

set -e
cd ${0:A:h}/..

if [ -n "$OPTIMATES_PINNED" ]; then
  echo "OPTIMATES_PINNED: building swift-protobuf as pinned"
  exit 0
fi

pinned=$(sed -n 's/.*swift-protobuf", exact: "\([0-9.]*\)".*/\1/p' Package.swift)
latest=$(git ls-remote --tags --refs https://github.com/apple/swift-protobuf \
  | awk -F/ '{print $NF}' | grep -E '^1\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
echo "swift-protobuf: pinned $pinned, newest 1.x $latest"
[ -n "$latest" ] || { echo "no releases found: building as pinned"; exit 0 }
[ "$latest" = "$pinned" ] && exit 0

sed -i '' "s/swift-protobuf\", exact: \"$pinned\"/swift-protobuf\", exact: \"$latest\"/" Package.swift
sed -i '' "s/version = $pinned;/version = $latest;/" Optimates.xcodeproj/project.pbxproj
rm -f Package.resolved Optimates.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved

# protoc for proto.sh (Homebrew is installed on Xcode Cloud's machines).
if ! protoc --version 2>/dev/null | grep -qvE 'libprotoc 3\.([0-9]|1[0-4])\.'; then
  HOMEBREW_NO_AUTO_UPDATE=1 brew install protobuf
fi
./proto.sh --keep

# Xcode Cloud builds with automatic package resolution off, so the project
# needs its own resolved file. proto.sh's swift build has just written one
# for the new pin; the project's is the same pins, without the hash of
# Package.swift's dependencies (originHash, which Xcode computes for the
# project instead and accepts missing).
resolved=Optimates.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
mkdir -p ${resolved:h}
sed -e '/"originHash"/d' -e 's/"version" : 3/"version" : 2/' Package.resolved > $resolved
xcodebuild -resolvePackageDependencies -disableAutomaticPackageResolution -project Optimates.xcodeproj -scheme Optimates
