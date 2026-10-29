#!/bin/zsh
# Builds BarkDictate and installs it as ~/Applications/BarkDictate.app, then opens it.
set -e
cd "$(dirname "$0")"
swift build -c release --package-path app
APP=~/Applications/BarkDictate.app
pkill -x BarkDictate || true
mkdir -p "$APP/Contents/MacOS"
cp app/Resources/Info.plist "$APP/Contents/Info.plist"
cp app/.build/release/BarkDictate "$APP/Contents/MacOS/"
codesign --force --deep --sign - --identifier com.meeth.barkdictate "$APP"
# Each rebuild changes the app's signature, which invalidates the old Accessibility
# approval. Clear it so macOS asks again instead of silently blocking typing.
tccutil reset Accessibility com.meeth.barkdictate >/dev/null 2>&1 || true
open "$APP"
echo "Installed $APP. Turn it on in System Settings → Privacy & Security → Accessibility."
