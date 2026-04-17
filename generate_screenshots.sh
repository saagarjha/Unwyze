#!/bin/sh

set -ex

DEVICE="$1"
RESULT_BUNDLE="Screenshots-$DEVICE.xcresult"

{
	xcrun simctl boot "$DEVICE"
	xcrun simctl bootstatus "$DEVICE"
	xcrun simctl status_bar "$DEVICE" override --time 2007-01-09T17:41:00.000Z --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState discharging --batteryLevel 100
	xcodebuild test -project Unwyze.xcodeproj -scheme Unwyze -destination "platform=iOS Simulator,name=$DEVICE" -resultBundlePath "$RESULT_BUNDLE" -only-testing:UnwyzeUITests/UnwyzeUITests/testScreenshots
	xcrun xcresulttool export attachments --path "$RESULT_BUNDLE" --output-path "$RESULT_BUNDLE"
} >&2
jq -r '.[].attachments[].exportedFileName | "'"$RESULT_BUNDLE"'/\(.)"' "$RESULT_BUNDLE/manifest.json" | sort
