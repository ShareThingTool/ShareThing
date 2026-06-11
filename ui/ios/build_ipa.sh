#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Building iOS app (no codesign)..."
flutter build ios --release --no-codesign

APP="build/ios/Release-iphoneos/Runner.app"
ENTITLEMENTS="ios/Runner/Runner.entitlements"
OUT="build/ios/ShareThing.ipa"

if [ ! -d "$APP" ]; then
  echo "ERROR: $APP not found. Build failed."
  exit 1
fi

echo "==> Signing binary with ldid..."
if ! command -v ldid &>/dev/null; then
  echo "ERROR: ldid not found. Install it with: brew install ldid"
  exit 1
fi
ldid -S"$ENTITLEMENTS" "$APP/Runner"

echo "==> Packaging IPA..."
WORK="$(mktemp -d)"
mkdir "$WORK/Payload"
cp -r "$APP" "$WORK/Payload/Runner.app"

mkdir -p "$(dirname "$OUT")"
(cd "$WORK" && zip -qr "$(pwd)/out.ipa" Payload/)
mv "$WORK/out.ipa" "$OUT"
rm -rf "$WORK"

echo "==> Done: $OUT"
echo "    Transfer to device and open with TrollStore."
