package pl.norwood.sharething.data

import java.io.File

data class OutgoingTransfer(
    val transferId: String,
    val targetPeerId: String,
    val file: File
)
