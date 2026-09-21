#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
device="${1:?Pass a booted simulator UDID}"
build="$(mktemp -d /tmp/rainbow-relay-tests.XXXXXX)"
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
for role in relay reader; do
    app="$build/$role.app"
    mkdir -p "$app"
    cp Tests/Info.plist "$app/Info.plist"
    plutil -replace CFBundleIdentifier -string "com.minis.rainbowkeyboard.$role" "$app/Info.plist"
    xcrun clang -x objective-c -fobjc-arc -fmodules -isysroot "$sdk" -target arm64-apple-ios15.0-simulator \
        -framework UIKit Tests/PreferenceRelayProbe.m -o "$app/KeyboardTests"
    codesign --force --sign - "$app"
    xcrun simctl install "$device" "$app"
done
relay="com.minis.rainbowkeyboard.relay"
reader="com.minis.rainbowkeyboard.reader"
trap 'xcrun simctl terminate "$device" "$relay" >/dev/null 2>&1 || true; xcrun simctl terminate "$device" "$reader" >/dev/null 2>&1 || true' EXIT
relayData="$(xcrun simctl get_app_container "$device" "$relay" data)"
readerData="$(xcrun simctl get_app_container "$device" "$reader" data)"
rm -f "$relayData/Documents/writer.json" "$relayData/Documents/relay.json" "$readerData/Documents/reader.json"
xcrun simctl launch "$device" "$relay" --writer
sleep 1
jq -e '.saved' "$relayData/Documents/writer.json"
xcrun simctl terminate "$device" "$relay"
# Relaunch without saving: recover the previous process's persistent configuration.
xcrun simctl launch "$device" "$relay" --relay
sleep 1
jq -e '.restoredSaved and .restoredTransport' "$relayData/Documents/relay.json"
xcrun simctl launch "$device" "$reader" --reader
for attempt in {1..20}; do
    [[ -f "$readerData/Documents/reader.json" ]] && break
    sleep 1
done
cat "$readerData/Documents/reader.json"
jq -e '.passed' "$readerData/Documents/reader.json"
printf '\nRelay report: %s/Documents/reader.json\n' "$readerData"
