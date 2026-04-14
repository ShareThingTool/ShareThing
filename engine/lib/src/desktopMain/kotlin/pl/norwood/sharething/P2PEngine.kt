package pl.norwood.sharething

import io.libp2p.core.Host
import io.libp2p.core.crypto.KeyType
import io.libp2p.core.crypto.PrivKey
import io.libp2p.core.crypto.generateKeyPair
import io.libp2p.core.crypto.marshalPrivateKey
import io.libp2p.core.crypto.unmarshalPrivateKey
import io.libp2p.core.dsl.HostBuilder
import io.libp2p.core.multiformats.Multiaddr
import io.libp2p.core.multiformats.Protocol
import java.net.Inet4Address
import java.net.NetworkInterface
import java.io.File
import java.util.Base64
import java.util.Collections
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json

actual class P2PEngine actual constructor() {
    private var host: Host? = null
    private var port: Int = 0
    private val json = Json { ignoreUnknownKeys = true; prettyPrint = true }

    actual fun startNode(port: Int): String {
        return try {
            val privKey = loadOrCreatePrivateKey()

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

    private fun loadOrCreatePrivateKey(): PrivKey {
        val file = identityFile()
        if (file.exists()) {
            try {
                val stored = json.decodeFromString<StoredIdentity>(file.readText())
                val decoded = Base64.getDecoder().decode(stored.privateKey)
                return unmarshalPrivateKey(decoded)
            } catch (_: Exception) {
                file.delete()
            }
        }

        val (privKey, _) = generateKeyPair(KeyType.ED25519)
        persistPrivateKey(privKey)
        return privKey
    }

    private fun persistPrivateKey(privKey: PrivKey) {
        val file = identityFile()
        file.parentFile?.mkdirs()
        val stored = StoredIdentity(
            privateKey = Base64.getEncoder().encodeToString(marshalPrivateKey(privKey))
        )
        file.writeText(json.encodeToString(stored))
    }

    private fun identityFile(): File {
        val appName = "sharething"
        val userHome = System.getProperty("user.home")
        val osName = System.getProperty("os.name").lowercase()

        val directory = when {
            osName.contains("win") -> {
                val base = System.getenv("LOCALAPPDATA")
                    ?: System.getenv("APPDATA")
                    ?: "$userHome\\AppData\\Local"
                File(base, "ShareThing")
            }
            osName.contains("mac") -> File(userHome, "Library/Application Support/ShareThing/data")
            else -> {
                val base = System.getenv("XDG_DATA_HOME") ?: "$userHome/.local/share"
                File(base, appName)
            }
        }

        return File(directory, "identity.json")
    }

    @Serializable
    private data class StoredIdentity(
        val privateKey: String
    )
}
