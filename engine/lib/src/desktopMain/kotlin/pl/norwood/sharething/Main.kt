package pl.norwood.sharething

import kotlinx.coroutines.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.util.*

fun main() = runBlocking {
    val scope = CoroutineScope(Dispatchers.Default + SupervisorJob())

    val readyMsg = EngineResponse(requestId = null, type = "event", data = "ready")
    println(Json.encodeToString(readyMsg))
    val scanner = Scanner(System.`in`)

    while (currentCoroutineContext().isActive) {
        if (scanner.hasNextLine()) {
            val line = scanner.nextLine()

            scope.launch {
                val responseJson = CommandDispatcher.dispatch(line)
                println(responseJson)
            }
        } else {
            delay(10)
        }
    }
}
