package pl.norwood.sharething

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

object CommandDispatcher {
    data class DispatchResult(
        val eventJson: String?,
        val shouldTerminate: Boolean = false
    )

    private val json = Json {
        classDiscriminator = "type"
        ignoreUnknownKeys = true
    }

    var engine = P2PEngine()
        private set

    fun encodeEvent(event: EngineEvent): String = json.encodeToString(event)

    fun dispatch(input: String): DispatchResult {
        return try {
            when (val command = json.decodeFromString<EngineCommand>(input)) {
                is EngineCommand.StartNode -> DispatchResult(
                    eventJson = encodeEvent(
                        engine.startNode(command.nickname, command.discoveryServers)
                    )
                )

                EngineCommand.StopNode -> {
                    engine.stopNode()
                    DispatchResult(eventJson = null, shouldTerminate = true)
                }

                is EngineCommand.SendFile -> DispatchResult(
                    eventJson = encodeEvent(
                        engine.sendFile(command.targetPeerId, command.filePath)
                    )
                )

                is EngineCommand.AcceptFile -> DispatchResult(
                    eventJson = encodeEvent(
                        engine.acceptFile(command.transferId, command.savePath)
                    )
                )

                is EngineCommand.RejectFile -> DispatchResult(
                    eventJson = encodeEvent(
                        engine.rejectFile(command.transferId)
                    )
                )
            }
        } catch (e: Exception) {
            DispatchResult(
                eventJson = encodeEvent(
                    EngineEvent.Error(e.message ?: e::class.simpleName.orEmpty())
                )
            )
        }
    }

    fun emit(event: EngineEvent) {
        EngineRuntime.emit(event)
    }
}
