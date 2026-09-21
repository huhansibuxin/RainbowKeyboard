#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
device="${1:?Pass a booted simulator UDID}"
build="$(mktemp -d /tmp/rainbow-keyboard-tests.XXXXXX)"
app="$build/KeyboardTests.app"
mkdir -p "$app"
cp Tests/Info.plist "$app/Info.plist"
bundle="com.minis.rainbowkeyboard.tests"
if [[ "${2:-}" == "--wetype-isolation" ]]; then
    bundle="com.tencent.wetype.rk-isolation"
    plutil -replace CFBundleIdentifier -string "$bundle" "$app/Info.plist"
fi
if [[ "${2:-}" == "--qq-light-colors" ]]; then
    bundle="com.tencent.mqq"
    plutil -replace CFBundleIdentifier -string "$bundle" "$app/Info.plist"
fi
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
if [[ "${2:-}" == "--settings" ]]; then
    prefs="$app/SettingsProbe.bundle"
    mkdir -p "$prefs"
    cp RainbowKeyboardPrefs/Resources/Info.plist "$prefs/Info.plist"
    cp RainbowKeyboardPrefs/Resources/RainbowKeyboardPrefs.plist "$prefs/Entry.plist"
    cp RainbowKeyboardPrefs/Resources/RainbowKeyboard.plist "$prefs/RainbowKeyboard.plist"
    cp RainbowKeyboardPrefs/Resources/PackageInfo.json "$prefs/PackageInfo.json"
    cp RainbowKeyboardPrefs/Resources/SliderHelp.plist "$prefs/SliderHelp.plist"
    cp RainbowKeyboardPrefs/Resources/*.png "$prefs/"
    xcrun clang -x objective-c -fobjc-arc -fmodules -isysroot "$sdk" -target arm64-apple-ios15.0-simulator \
        -framework UIKit -bundle -Wl,-undefined,dynamic_lookup -I"${THEOS:-$HOME/theos}/vendor/include" \
        RainbowKeyboardPrefs/RKBRootListController.m -o "$prefs/RainbowKeyboardPrefs"
    codesign --force --sign - "$prefs"
fi
perl "${THEOS:-$HOME/theos}/bin/logos.pl" -c generator=internal CandidateGradient.xm > "$build/CandidateGradient.generated.mm"
perl "${THEOS:-$HOME/theos}/bin/logos.pl" -c generator=internal PureBlackKeyboard.xm > "$build/PureBlackKeyboard.generated.mm"
xcrun clang++ -x objective-c++ -fobjc-arc -fmodules -isysroot "$sdk" -target arm64-apple-ios15.0-simulator \
    -framework UIKit -framework QuartzCore -framework CoreGraphics -I. -I"$build" Tests/KeyboardTests.m \
    RainbowEffectView.m RKNeonPress.m RKKeyboardGeometry.m RKBlackBitmap.m -o "$app/KeyboardTests"
codesign --force --sign - "$app"
xcrun simctl install "$device" "$app"
xcrun simctl terminate "$device" "$bundle" >/dev/null 2>&1 || true
data="$(xcrun simctl get_app_container "$device" "$bundle" data)"
rm -f "$data/Documents/results.json" "$data/Documents/native-keyboard.json" "$data/Documents/settings.json" "$data/Documents/native-neon-press.json"
xcrun simctl launch "$device" "$bundle" "${2:---tests}"
if [[ "${2:-}" == "--settings" ]]; then
    for attempt in {1..90}; do
        [[ -f "$data/Documents/settings.json" ]] && break
        sleep 1
    done
    cat "$data/Documents/settings.json"
    jq -e '.passed == true' "$data/Documents/settings.json"
    printf '\nSettings probe: %s/Documents/settings.json\n' "$data"
    exit 0
fi
sleep 4
if [[ "${2:-}" == "--native-neon-press" || "${2:-}" == "--native-neon-colors" || "${2:-}" == "--native-neon-dim" ]]; then
    for attempt in {1..30}; do
        [[ -f "$data/Documents/native-neon-press.json" ]] && break
        sleep 1
    done
    cat "$data/Documents/native-neon-press.json"
    jq -e '.passed == true' "$data/Documents/native-neon-press.json"
    printf '\nNeon press preview: %s/Documents/native-neon-press.png\n' "$data"
    exit 0
fi
if [[ "${2:-}" == "--native-keyboard" || "${2:-}" == "--native-colors" || "${2:-}" == "--native-live-colors" || "${2:-}" == "--qq-light-colors" ]]; then
    for attempt in {1..30}; do
        [[ -f "$data/Documents/native-keyboard.json" ]] && break
        sleep 1
    done
    xcrun simctl io "$device" screenshot "$data/Documents/native-keyboard.png"
    cat "$data/Documents/native-keyboard.json"
    printf '\nNative keyboard screenshot: %s/Documents/native-keyboard.png\n' "$data"
    jq -e 'any(.views[]; .testKeyName == "International-Key" and
        .compositedMetrics.maxChannel == 255 and .pressedCompositedMetrics.maxChannel == 255 and
        .releasedCompositedMetrics.maxChannel == 255)' "$data/Documents/native-keyboard.json"
    if [[ "${2:-}" == "--qq-light-colors" ]]; then
        jq -e '.qqAppearanceHook and .qqAppearanceOverrides > 0 and .appLightAppearance' "$data/Documents/native-keyboard.json"
    fi
    if [[ "${2:-}" == "--native-colors" || "${2:-}" == "--native-live-colors" || "${2:-}" == "--qq-light-colors" ]]; then
        jq -e '.firstResponder and all(.views[] | select(.keyMetrics.opaque > 0);
                .keyMetrics.maxChannel == 255 and .pressedKeyMetrics.maxChannel == 255 and
            .releasedKeyMetrics.maxChannel == 255) and any(.views[];
            .class == "UIKeyboardLayoutStar" and .keyCount > 20 and
            .paletteFaceMatches >= .keyCount * 0.7)' "$data/Documents/native-keyboard.json"
        exit 0
    fi
    jq -e '.firstResponder and .pureBlackConfigHook and .pureBlackActionHook and .nativeCandidateHook and
        .nativePredictionHook and (.nativeLabelDraws > 0) and
        any(.views[]; .class == "UIKeyboardLayoutStar" and .keyCount > 20) and
        ([.views[] | select(.keyMetrics)] | length > 20) and
        all(.views[] | select(.keyMetrics); .keyMetrics.gray < .keyMetrics.pixelCount * 0.25) and
        all(.views[] | select(.keyMetrics.opaque > 0); .keyMetrics.maxChannel == 255) and
        any(.views[]; .pressedKeyMetrics != null) and
        all(.views[] | select(.pressedKeyMetrics);
            .pressedKeyMetrics.gray < .pressedKeyMetrics.pixelCount * 0.25 and
            .releasedKeyMetrics.gray < .releasedKeyMetrics.pixelCount * 0.25 and
            (if .keyMetrics.opaque > 0 then
                .pressedKeyMetrics.maxChannel == 255 and .releasedKeyMetrics.maxChannel == 255
             else true end)) and
        any(.views[]; .actionKeyMetrics.colored == 0 and .actionKeyMetrics.maxChannel == 255)' \
        "$data/Documents/native-keyboard.json"
    exit 0
fi
cat "$data/Documents/results.json"
printf '\nImages and runtime probe: %s/Documents\n' "$data"
jq -e 'length > 0 and all(.[]; .passed == true)' "$data/Documents/results.json"
