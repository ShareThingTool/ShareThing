package pl.norwood.sharething

import kotlinx.serialization.Serializable

@Serializable
data class DiscoveryRegisterRequest(
    val peerId: String, val nick: String, val addresses: List<String>, val platform: String
)