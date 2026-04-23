package pl.norwood.sharething

import co.touchlab.kermit.Logger
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.runBlocking
import java.util.Scanner
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.system.exitProcess

fun main(args: Array<String>): Unit = runBlocking {
    val log = Logger.withTag("EngineMain")
    val running = AtomicBoolean(true)

    EngineRuntime.emitEvent = { event ->
        println(CommandDispatcher.encodeEvent(event))
    }

    println(CommandDispatcher.encodeEvent(EngineEvent.Ready))
    val scanner = Scanner(System.`in`)

    while (currentCoroutineContext().isActive && running.get()) {
        if (scanner.hasNextLine()) {
            val line = scanner.nextLine()
            log.v { "stdin_line bytes=${line.length}" }
            val result = CommandDispatcher.dispatch(line)
            if (result.eventJson != null) {
                log.v { "stdout_event bytes=${result.eventJson.length}" }
                println(result.eventJson)
            }
            if (result.shouldTerminate) {
                log.i { "termination requested by STOP_NODE command" }
                running.set(false)
            }
        } else {
            delay(10)
        }
    }

    exitProcess(0)
}
