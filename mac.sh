#!/bin/zsh
# Build the app for this Mac and open it: a release build wrapped in a
# minimal Optimates.app under .build/, since SwiftData needs a bundle.
#
#     ./mac.sh
cd ${0:A:h} || exit 1
swift build -c release || exit 1
app=.build/Optimates.app
rm -rf $app && mkdir -p $app/Contents/MacOS
cp "$(swift build -c release --show-bin-path)/Optimates" $app/Contents/MacOS/
cat > $app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Optimates</string>
<key>CFBundleIdentifier</key><string>pub.atec.optimates.mac</string>
<key>CFBundleExecutable</key><string>Optimates</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
pkill -x Optimates
open $app
