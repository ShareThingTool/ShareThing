#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

FRAMEWORKS_DIR="../ui/ios/Frameworks"
mkdir -p "$FRAMEWORKS_DIR"

gomobile bind \
  -target ios,iossimulator \
  -androidapi 21 \
  -o "$FRAMEWORKS_DIR/P2p.xcframework" \
  .

echo "Built P2p.xcframework -> $FRAMEWORKS_DIR/P2p.xcframework"
