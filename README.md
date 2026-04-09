# ShareThing – compatible p2p file sharing software

A decentralized P2P file-sharing application built with **Kotlin Multiplatform** and **Flutter**.

## Project Structure

* **`engine/`**: The core P2P logic.
    * Written in Kotlin Multiplatform.
    * Uses `jvm-libp2p` for decentralized networking.
    * Targets: Android (AAR) and JVM Desktop (JAR).
* **`ui/`**: The frontend application.
    * Built with Flutter.
    * Communicates with the engine via MethodChannels (Android) and JNI/Native bridges (Desktop).

## Getting Started

### Prerequisites
* **JDK 17 (minimum)** 
* **Flutter SDK** 
* **Android SDK**
* * **Go 1.21+** (for Android only) — https://go.dev/dl/
* **gomobile** (for Android only)
* **Android NDK** (installed via Android Studio → SDK Manager → SDK Tools)

### 🛠 Building the Engine
Before running the UI, you must compile the Kotlin engine to generate the necessary libraries.

1.  Navigate to the engine directory:
    ```bash
    cd engine
    ```
2.  Build the Desktop library:
    ```bash
    ./gradlew :lib:desktopJar
    ```
3.  Build the Android library:
    ```bash
    ./gradlew :lib:assembleRelease
    ```

### 📱 Running the UI
1.  Navigate to the UI directory:
    ```bash
    cd ui
    ```
2.  Fetch dependencies:
    ```bash
    flutter pub get
    ```
3.  Run the app:
    ```bash
    flutter run
    ```

    ### 🤖 Building the Android Engine (go-libp2p)

Android does not support JVM-based libp2p, so a separate Go bridge is used instead.
This must be built once and copied into the Flutter project before running on Android.

#### 1. Install Go
Download and install Go from https://go.dev/dl/ (1.21 or newer).
go get github.com/libp2p/go-libp2p@v0.38.1

#### 2. Install gomobile
```bash
go install golang.org/x/mobile/cmd/gomobile@latest
gomobile init
```

#### 3. Build the .aar
```bash
cd p2pbridge
gomobile bind -target android/arm64 -androidapi 21 -o p2p.aar .
```

This produces two files: `p2p.aar` and `p2p-sources.jar`.

#### 4. Copy into the Flutter project
```bash
cp p2p.aar ../ui/android/app/libs/
cp p2p-sources.jar ../ui/android/app/libs/
```

## 📜 License
This project is licensed under the **GPL-3.0 License** - see the LICENSE file for details.
