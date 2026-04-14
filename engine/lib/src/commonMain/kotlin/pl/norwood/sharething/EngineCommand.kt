package pl.norwood.sharething

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
sealed class EngineCommand {
    @Serializable
    @SerialName("START_NODE")
    data class StartNode(
        val nickname: String,
        val discoveryServers: List<String> = emptyList()
    ) : EngineCommand()

    @Serializable
    @SerialName("STOP_NODE")
    data object StopNode : EngineCommand()

    @Serializable
    @SerialName("SEND_FILE")
    data class SendFile(
        val targetPeerId: String,
        val filePath: String
    ) : EngineCommand()

    @Serializable
    @SerialName("ACCEPT_FILE")
    data class AcceptFile(
        val transferId: String,
        val savePath: String
    ) : EngineCommand()

    @Serializable
    @SerialName("REJECT_FILE")
    data class RejectFile(
        val transferId: String
    ) : EngineCommand()
}

@Serializable
sealed class EngineEvent {
    @Serializable
    @SerialName("READY")
    data object Ready : EngineEvent()

    @Serializable
    @SerialName("NODE_STARTED")
    data class NodeStarted(
        val peerId: String,
        val listenAddresses: List<String>
    ) : EngineEvent()

    @Serializable
    @SerialName("NODE_STOPPED")
    data object NodeStopped : EngineEvent()

    @Serializable
    @SerialName("PEER_DISCOVERED")
    data class PeerDiscovered(
        val peerId: String,
        val nickname: String,
        val addresses: List<String>
    ) : EngineEvent()

    @Serializable
    @SerialName("PEER_NICKNAME_CHANGED")
    data class PeerNicknameChanged(
        val peerId: String,
        val newNickname: String
    ) : EngineEvent()

    @Serializable
    @SerialName("INCOMING_FILE_REQUEST")
    data class IncomingFileRequest(
        val transferId: String,
        val peerId: String,
        val filename: String,
        val totalBytes: Long
    ) : EngineEvent()

    @Serializable
    @SerialName("TRANSFER_UPDATE")
    data class TransferUpdate(
        val transferId: String,
        val direction: String,
        val bytesTransferred: Long,
        val totalBytes: Long,
        val speedBps: Long,
        val status: String,
        val peerId: String? = null,
        val filename: String? = null,
        val message: String? = null
    ) : EngineEvent()

    @Serializable
    @SerialName("ERROR")
    data class Error(
        val message: String
    ) : EngineEvent()
}
