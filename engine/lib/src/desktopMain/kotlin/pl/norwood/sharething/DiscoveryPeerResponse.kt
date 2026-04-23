package pl.norwood.sharething

import kotlinx.serialization.Serializable

@Serializable
data class DiscoveryPeerResponse(
    val peerId: String,
    val nick: String? = null,
    val addresses: List<String> = emptyList(),
    val platform: String? = null
)