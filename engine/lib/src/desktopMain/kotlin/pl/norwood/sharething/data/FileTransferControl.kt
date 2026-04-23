package pl.norwood.sharething.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
sealed class FileTransferControl {
    @Serializable
    @SerialName("OFFER")
    data class Offer(
        val transferId: String,
        val peerId: String,
        val nickname: String,
        val filename: String,
        val totalBytes: Long,
        val addresses: List<String> = emptyList()
    ) : FileTransferControl()

    @Serializable
    @SerialName("RESPONSE")
    data class Response(
        val transferId: String,
        val accepted: Boolean,
        val message: String? = null,
        val peerId: String? = null,
        val addresses: List<String> = emptyList()
    ) : FileTransferControl()

    @Serializable
    @SerialName("DATA_START")
    data class DataStart(
        val transferId: String,
        val peerId: String,
        val filename: String,
        val totalBytes: Long
    ) : FileTransferControl()

    @Serializable
    @SerialName("COMPLETION")
    data class Completion(
        val transferId: String, val completed: Boolean, val message: String? = null
    ) : FileTransferControl()
}
