package pl.norwood.sharething

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

object CommandDispatcher {

    var engine = P2PEngine()
        private set
    private val json = Json { ignoreUnknownKeys = true }

    fun dispatch(input: String): String {

        return try {
            val command = json.decodeFromString<EngineCommand>(input)


            val result = when (command) {
                is EngineCommand.StartNode -> engine.startNode(command.port)
                is EngineCommand.StopNode -> engine.stopNode()
                is EngineCommand.GetId -> engine.getPeerId()
                is EngineCommand.GetPort -> engine.getPort()
            }

            json.encodeToString(
                EngineResponse(
                    requestId = command.requestId,
                    type = "response",
                    data = result
                )
            )
        } catch (e: Exception) {
            json.encodeToString(EngineResponse(null, "error", error = e.message))
        }

    }
}