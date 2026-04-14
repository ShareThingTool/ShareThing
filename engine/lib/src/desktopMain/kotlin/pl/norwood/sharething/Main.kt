package pl.norwood.sharething

import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.runBlocking
import java.util.Scanner
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.system.exitProcess

fun main(args: Array<String>): Unit = runBlocking {
    val running = AtomicBoolean(true)

    EngineRuntime.emitEvent = { event ->
        println(CommandDispatcher.encodeEvent(event))
    }

    println(CommandDispatcher.encodeEvent(EngineEvent.Ready))
    val scanner = Scanner(System.`in`)

    while (currentCoroutineContext().isActive && running.get()) {
        if (scanner.hasNextLine()) {
            val line = scanner.nextLine()
            val result = CommandDispatcher.dispatch(line)
            if (result.eventJson != null) {
                println(result.eventJson)
            }
            if (result.shouldTerminate) {
                running.set(false)
            }
        } else {
            delay(10)
        }
    }

    exitProcess(0)
}
