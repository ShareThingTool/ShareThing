package pl.norwood.sharething

import io.libp2p.core.Host
import io.libp2p.core.crypto.KeyType
import io.libp2p.core.crypto.generateKeyPair
import io.libp2p.core.dsl.HostBuilder
import io.libp2p.core.multiformats.Multiaddr
import io.libp2p.core.multiformats.Protocol
import java.net.Inet4Address
import java.net.NetworkInterface
import java.util.Collections

actual class P2PEngine actual constructor() {
    private var host: Host? = null
    private var port: Int = 0

    actual fun startNode(port: Int): String {
        return try {
            val (privKey, _) = generateKeyPair(KeyType.RSA, 2048)

            val node = HostBuilder()
                .builderModifier { b -> b.identity.factory = { privKey } }
                .listen("/ip4/0.0.0.0/tcp/$port")
                .build()

            this.port = port
            node.start().get()
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
        return port.toString()
    }

    actual fun getListenAddress(): String {
        val node = host ?: return "Not Started"
        val peerId = node.peerId.toBase58()
        val localIpv4 = Collections.list(NetworkInterface.getNetworkInterfaces())
            .asSequence()
            .filter { it.isUp && !it.isLoopback }
            .flatMap { Collections.list(it.inetAddresses).asSequence() }
            .filterIsInstance<Inet4Address>()
            .firstOrNull()
            ?.hostAddress

        if (localIpv4 != null) {
            return "/ip4/$localIpv4/tcp/$port/p2p/$peerId"
        }

        val listenAddresses = node.listenAddresses()
        val preferredAddress = listenAddresses.firstOrNull { it.has(Protocol.IP4) }
            ?: listenAddresses.firstOrNull()

        return preferredAddress?.toString() ?: "Not Started"
    }

    actual fun connect(multiaddr: String): String {
        val node = host ?: return "Error: Node not started"

        return try {
            val remoteAddress = Multiaddr(multiaddr)
            node.network.connect(remoteAddress).get()
            "Connected to $remoteAddress"
        } catch (e: Exception) {
            "Error: ${e.message}"
        }
    }
}
