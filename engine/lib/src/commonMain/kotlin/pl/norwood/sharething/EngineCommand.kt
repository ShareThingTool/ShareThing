package pl.norwood.sharething

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
sealed class EngineCommand {
    abstract val requestId: String

    @Serializable
    @SerialName("start_node")
    data class StartNode(override val requestId: String, val port: Int) : EngineCommand()

    @Serializable
    @SerialName("stop_node")
    data class StopNode(override val requestId: String) : EngineCommand()


    @Serializable
    @SerialName("get_port")
    data class GetPort(override val requestId: String) : EngineCommand()

    @Serializable
    @SerialName("get_id")
    data class GetId(override val requestId: String) : EngineCommand()

    @Serializable
    @SerialName("get_listen_address")
    data class GetListenAddress(override val requestId: String) : EngineCommand()

    @Serializable
    @SerialName("connect")
    data class Connect(
        override val requestId: String,
        val multiaddr: String
    ) : EngineCommand()
}

@Serializable
data class EngineResponse(
    val requestId: String? = null,
    val type: String, // "response" or "event"
    val data: String? = null,
    val error: String? = null
)
