package pl.norwood.sharething.data

data class KnownPeer(
    val peerId: String,
    val nickname: String,
    val addresses: List<String>,
    var lastSeenMillis: Long = System.currentTimeMillis()
)