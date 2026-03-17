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

## 📜 License
This project is licensed under the **GPL-3.0 License** - see the LICENSE file for details.
