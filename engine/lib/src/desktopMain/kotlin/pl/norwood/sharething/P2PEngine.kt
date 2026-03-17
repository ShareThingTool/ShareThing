package pl.norwood.sharething

import io.libp2p.core.Host
import io.libp2p.core.crypto.KeyType
import io.libp2p.core.crypto.generateKeyPair
import io.libp2p.core.dsl.HostBuilder

actual class P2PEngine actual constructor() {
    private var host: Host? = null
    private var port: Int = 0

    actual fun startNode(port: Int): String {
        return try {
            val (privKey, pubKey) = generateKeyPair(KeyType.RSA, 2048)

            val node = HostBuilder()
                .builderModifier { b -> b.identity.factory = { privKey } }
                .listen("/ip4/0.0.0.0/tcp/$port")
                .build()

            this.port = port;
            node.start()?.get()
            this.host = node

            "Success: Node started with ID ${node.peerId.toBase58()}"
        } catch (e: Exception) {
            "Error: ${e.message}"
        }
    }

    actual fun getPeerId(): String = host?.peerId?.toBase58() ?: "Not Started"

    actual fun stopNode(): String {
        host?.stop()?.get()
        host = null
        return "Stopped"
    }

    actual fun getPort(): String {
        return port.toString();

    }
}
