package pl.norwood.sharething

actual class P2PEngine actual constructor() {
    actual fun startNode(
        nickname: String,
        discoveryServers: List<String>
    ): EngineEvent.NodeStarted {
        return EngineEvent.NodeStarted(
            peerId = "",
            listenAddresses = emptyList()
        )
    }

    actual fun stopNode() {
    }

    actual fun sendFile(targetPeerId: String, filePath: String): EngineEvent {
        return EngineEvent.Error("Android engine is provided by the Go bridge in the Flutter app.")
    }

    actual fun acceptFile(transferId: String, savePath: String): EngineEvent {
        return EngineEvent.Error("Android engine is provided by the Go bridge in the Flutter app.")
    }

    actual fun rejectFile(transferId: String): EngineEvent {
        return EngineEvent.Error("Android engine is provided by the Go bridge in the Flutter app.")
    }
}
