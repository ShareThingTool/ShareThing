package pl.norwood.sharething.data

import pl.norwood.sharething.P2PEngine

data class PendingIncomingTransfer(
    val transferId: String,
    val peerId: String,
    val fileName: String,
    val totalBytes: Long,
    val handler: P2PEngine.FileTransferMessageHandler
)