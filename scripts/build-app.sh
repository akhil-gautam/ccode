#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# Packaging below uses the native SwiftPM resource layout.
sh scripts/swift-check.sh build --build-system native -c release --product ccode
APP_DIR="$PWD/dist/ccode.app"
# Start clean so obsolete resources cannot leak into a release.
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp .build/release/ccode "$APP_DIR/Contents/MacOS/ccode"
cp Sources/CCode/Resources/Inter-Regular.otf "$APP_DIR/Contents/Resources/Inter-Regular.otf"
cp Sources/CCode/Resources/Inter-LICENSE.txt "$APP_DIR/Contents/Resources/Inter-LICENSE.txt"
# SwiftTerm's Metal loader explicitly searches Contents/Resources.
cp -R .build/release/SwiftTerm_SwiftTerm.bundle "$APP_DIR/Contents/Resources/SwiftTerm_SwiftTerm.bundle"
cp -f .build/checkouts/SwiftTerm/LICENSE "$APP_DIR/Contents/Resources/SwiftTerm-LICENSE.txt"
cp -f scripts/claude-acp-native-subagents.mjs "$APP_DIR/Contents/Resources/claude-acp-native-subagents.mjs"
cp -f scripts/claude-acp-checkpoints.mjs "$APP_DIR/Contents/Resources/claude-acp-checkpoints.mjs"
cp -f scripts/claude-acp-checkpoint-files.mjs "$APP_DIR/Contents/Resources/claude-acp-checkpoint-files.mjs"
cp -f scripts/claude-acp-side-question.mjs "$APP_DIR/Contents/Resources/claude-acp-side-question.mjs"
cp -f scripts/claude-acp-configuration.mjs "$APP_DIR/Contents/Resources/claude-acp-configuration.mjs"
cp -f scripts/claude-configuration.mjs "$APP_DIR/Contents/Resources/claude-configuration.mjs"
cp -f scripts/simulator-control.py "$APP_DIR/Contents/Resources/simulator-control.py"
rm -rf "$APP_DIR/Contents/Resources/SimulatorControl"
cp -R scripts/SimulatorControl "$APP_DIR/Contents/Resources/SimulatorControl"
ROOT_XML=$(printf '%s' "$PWD" | sed 's/\&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ccode</string>
<key>CFBundleIdentifier</key><string>dev.ccode.native</string>
<key>CFBundleName</key><string>ccode</string>
<key>CFBundleDisplayName</key><string>ccode</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>ccode uses the microphone only when you start dictation, to add text to your draft.</string>
<key>NSSpeechRecognitionUsageDescription</key><string>ccode recognizes dictation on this device. Recognized text stays in a review buffer until you insert it into your draft.</string>
<key>CCodeDevelopmentRoot</key><string>$ROOT_XML</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP_DIR"
printf '%s\n' "$APP_DIR"
