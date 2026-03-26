package pl.norwood.sharething

import io.libp2p.core.Host
import io.libp2p.core.crypto.KeyType
import io.libp2p.core.crypto.generateKeyPair
import io.libp2p.core.dsl.HostBuilder

actual class P2PEngine actual constructor() {
    private var host: Host? = null

    actual fun startNode(port: Int): String {
        return try {
            val (privKey, _) = generateKeyPair(KeyType.ECDSA)

            val node = HostBuilder()
                .builderModifier { b -> b.identity.factory = { privKey } }
                .listen("/ip4/0.0.0.0/tcp/$port")
                .build()

            node.start().get()
            this.host = node
            "Android Node Online: ${node.peerId.toBase58()}"
        } catch (e: Exception) {
            "Android Init Failed: ${e.localizedMessage}"
        }
    }

    actual fun getPeerId(): String = host?.peerId?.toBase58() ?: "Offline"

    actual fun stopNode() {
        host?.stop()
    }
}