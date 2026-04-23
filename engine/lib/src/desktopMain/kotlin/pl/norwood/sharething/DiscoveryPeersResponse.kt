package pl.norwood.sharething

import kotlinx.serialization.Serializable

@Serializable
data class DiscoveryPeersResponse(
    val peers: List<DiscoveryPeerResponse>
)