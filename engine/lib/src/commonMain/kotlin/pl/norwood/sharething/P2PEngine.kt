package pl.norwood.sharething

expect class P2PEngine() {
    fun startNode(nickname: String, discoveryServers: List<String>): EngineEvent.NodeStarted

    fun stopNode()

    fun sendFile(targetPeerId: String, filePath: String): EngineEvent

    fun acceptFile(transferId: String, savePath: String): EngineEvent

    fun rejectFile(transferId: String): EngineEvent
}
