# ShareThing

ShareThing is a privacy-first peer-to-peer file sharing client split into a Flutter UI and platform-specific libp2p nodes.

## Architecture

- `ui/`
  - Flutter UI, persistent state, and process orchestration
  - stores config and local friend data as JSON files
  - does not perform peer discovery, transport negotiation, or file byte streaming
- `engine/`
  - headless Kotlin JVM node for desktop
  - communicates with Flutter over newline-delimited JSON on stdin/stdout
- `p2pbridge/`
  - Go libp2p bridge for Android
  - invoked from the Android host layer

## JSON Contract

Flutter sends newline-delimited JSON commands to the node layer. The primary command types are:

- `START_NODE`
- `STOP_NODE`
- `SEND_FILE`
- `ACCEPT_FILE`
- `REJECT_FILE`

The node emits JSON events back to Flutter. The primary event types are:

- `NODE_STARTED`
- `PEER_DISCOVERED`
- `PEER_NICKNAME_CHANGED`
- `INCOMING_FILE_REQUEST`
- `TRANSFER_UPDATE`

## Storage

Client data is stored in platform-appropriate application directories:

- Linux
  - config: `~/.config/sharething/`
  - data: `~/.local/share/sharething/`
- Windows
  - config: `%APPDATA%\\ShareThing\\`
  - data: `%LOCALAPPDATA%\\ShareThing\\`
- macOS
  - `~/Library/Application Support/ShareThing/`
- Android
  - app-specific support/data directories

## Current State

- Desktop node startup and identity persistence are wired.
- Flutter friend/config storage is file-backed JSON.
- Dart-side LAN networking and Dart-side file streaming were removed to restore the intended architecture boundary.
- `SEND_FILE`, `ACCEPT_FILE`, and `REJECT_FILE` are part of the shared contract, but full node-side transfer handling is not implemented yet.

## Build

### Desktop Engine

```bash
cd engine
JAVA_HOME=/usr/lib/jvm/java-21-openjdk ./gradlew :lib:desktopJar :lib:syncDesktopJar --no-daemon
```

### Flutter UI

Use `fvm`:

```bash
cd ui
fvm flutter analyze
fvm flutter test
fvm flutter build linux
```

### Android Go Bridge

The Android bridge source lives in `p2pbridge/`, but the checked-in Android app currently consumes a prebuilt bridge artifact in `ui/android/app/libs/`.
