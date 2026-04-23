package pl.norwood.sharething

import io.netty.channel.ChannelFuture
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

// Transforms Netty's callback-based future into a Kotlin suspend function
suspend fun ChannelFuture.awaitNetty() = suspendCancellableCoroutine { cont ->
    this.addListener { future ->
        if (future.isSuccess) {
            cont.resume(Unit)
        } else {
            cont.resumeWithException(future.cause() ?: Exception("Netty write failed"))
        }
    }
}