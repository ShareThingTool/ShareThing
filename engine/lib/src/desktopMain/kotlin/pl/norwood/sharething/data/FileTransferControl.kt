package pl.norwood.sharething.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
sealed class FileTransferControl {
    @Serializable
    @SerialName("OFFER")
    data class Offer(
        val transferId: String, val peerId: String, val nickname: String, val filename: String, val totalBytes: Long,
        val textContent: String? = null
    ) : FileTransferControl()

    @Serializable
    @SerialName("RESPONSE")
    data class Response(
        val transferId: String, val accepted: Boolean, val message: String? = null
    ) : FileTransferControl()

    @Serializable
    @SerialName("COMPLETION")
    data class Completion(
        val transferId: String, val completed: Boolean, val message: String? = null,
        val blake3Hash: String? = null
    ) : FileTransferControl()

    @Serializable
    @SerialName("DATA_ACK")
    data class DataAck(
        val transferId: String, val bytesReceived: Long
    ) : FileTransferControl()
}
