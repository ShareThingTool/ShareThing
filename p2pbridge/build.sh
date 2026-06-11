#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

mkdir -p build ../ui/assets/engine

ext=""
if [[ "${GOOS:-$(go env GOOS)}" == "windows" ]]; then
  ext=".exe"
fi

CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o "build/p2p_engine${ext}" ./cmd/engine
cp "build/p2p_engine${ext}" "../ui/assets/engine/p2p_engine${ext}"
