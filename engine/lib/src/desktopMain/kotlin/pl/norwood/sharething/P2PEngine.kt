package pl.norwood.sharething

import io.libp2p.core.*
import io.libp2p.core.crypto.*
import io.libp2p.core.dsl.HostBuilder
import io.libp2p.core.multiformats.Multiaddr
import io.libp2p.core.multiformats.Protocol
import io.libp2p.core.multistream.ProtocolBinding
import io.libp2p.discovery.MDnsDiscovery
import io.libp2p.protocol.Identify
import io.libp2p.protocol.ProtocolMessageHandler
import io.libp2p.protocol.ProtocolMessageHandlerAdapter
import io.netty.buffer.ByteBuf
import io.netty.buffer.Unpooled
import io.netty.channel.ChannelHandlerContext
import io.netty.channel.ChannelInboundHandlerAdapter
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.future.await
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import pl.norwood.sharething.data.FileTransferControl
import pl.norwood.sharething.data.KnownPeer
import pl.norwood.sharething.data.OutgoingTransfer
import pl.norwood.sharething.data.PendingIncomingTransfer
import pl.norwood.sharething.data.StoredIdentity
import java.io.File
import java.net.Inet4Address
import java.net.NetworkInterface
import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.time.Duration
import java.util.*
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import kotlin.time.Duration.Companion.milliseconds

actual class P2PEngine actual constructor() {
    private var host: Host? = null
    private var port: Int = 0
    private var nickname: String = ""
    private var mndsService: MDnsDiscovery? = null
    private var discoveryServers: List<String> = emptyList()

    private val identityJson = Json {
        ignoreUnknownKeys = true
        prettyPrint = true
    }
    private val networkJson = Json {
        ignoreUnknownKeys = true
    }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val httpClient = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build()

    private var heartbeatJob: Job? = null
    private var discoveryJob: Job? = null
    private var peerSweepJob: Job? = null

    private val knownPeers = ConcurrentHashMap<String, KnownPeer>()
    private val incomingTransfers = ConcurrentHashMap<String, PendingIncomingTransfer>()

    private val inboundFileBinding: ProtocolBinding<FileTransferMessageHandler> =
        createFileTransferBinding(outboundTransfer = null)

    actual fun startNode(
        nickname: String, discoveryServers: List<String>
    ): EngineEvent.NodeStarted {
        this.nickname = nickname
        this.discoveryServers = discoveryServers.map(::normalizeDiscoveryServer)

        if (host != null) {
            return EngineEvent.NodeStarted(
                peerId = host!!.peerId.toBase58(), listenAddresses = currentListenAddresses()
            )
        }

        val candidatePorts = listOf(DEFAULT_PORT, 0)
        var lastError: Exception? = null

        for (candidatePort in candidatePorts) {
            try {
                val privKey = loadOrCreatePrivateKey()
                val node = buildHost(privKey, candidatePort)
                node.addProtocolHandler(inboundFileBinding as ProtocolBinding<Any>)
                node.start().get()
                host = node
                port = currentPort(node)
                startDiscoveryLoops()

                return EngineEvent.NodeStarted(
                    peerId = node.peerId.toBase58(), listenAddresses = currentListenAddresses()
                )
            } catch (e: Exception) {
                lastError = e
                host = null
            }
        }

        throw lastError ?: IllegalStateException("Desktop node failed to start")
    }

    actual fun stopNode() {
        runBlocking {
            heartbeatJob?.cancelAndJoin()
            heartbeatJob = null
            discoveryJob?.cancelAndJoin()
            discoveryJob = null
            peerSweepJob?.cancelAndJoin()
            peerSweepJob = null
        }

        mndsService?.stop()
        mndsService = null

        knownPeers.clear()
        incomingTransfers.clear()
        unregisterFromDiscoveryServers()

        host?.stop()?.get()
        host = null
        port = 0
        CommandDispatcher.emit(EngineEvent.NodeStopped)
    }

    actual fun sendFile(targetPeerId: String, filePath: String): EngineEvent {
        val node = host ?: return EngineEvent.Error("Desktop node is not running")
        val target = knownPeers[targetPeerId] ?: return EngineEvent.Error("Unknown peer: $targetPeerId")
        val file = File(filePath)
        if (!file.exists() || !file.isFile) {
            return EngineEvent.Error("File does not exist: $filePath")
        }

        val transferId = UUID.randomUUID().toString()
        val transfer = OutgoingTransfer(
            transferId = transferId, targetPeerId = targetPeerId, targetNickname = target.nickname, file = file
        )

        emitTransferUpdate(
            transferId = transferId,
            direction = "OUTGOING",
            bytesTransferred = 0,
            totalBytes = file.length(),
            speedBps = 0,
            status = "QUEUED",
            peerId = targetPeerId,
            filename = file.name
        )

        scope.launch {
            try {
                val binding = createFileTransferBinding(outboundTransfer = transfer)
                val peerId = PeerId.fromBase58(target.peerId)
                val addresses = target.addresses.map { Multiaddr(it) }.toTypedArray()

                println("Dialing ${target.peerId} on addresses: ${target.addresses}")

                // .await() fixes the Netty thread deadlock caused by .get()
                binding.dial(node, peerId, *addresses).controller.await()

                println("Stream established successfully to ${target.peerId}")
            } catch (e: Exception) {
                println("Dial failed: ${e.message}")
                emitTransferUpdate(
                    transferId = transferId,
                    direction = "OUTGOING",
                    bytesTransferred = 0,
                    totalBytes = file.length(),
                    speedBps = 0,
                    status = "FAILED",
                    peerId = targetPeerId,
                    filename = file.name,
                    message = e.message
                )
            }
        }

        return EngineEvent.TransferUpdate(
            transferId = transferId,
            direction = "OUTGOING",
            bytesTransferred = 0,
            totalBytes = file.length(),
            speedBps = 0,
            status = "QUEUED",
            peerId = targetPeerId,
            filename = file.name
        )
    }

    actual fun acceptFile(transferId: String, savePath: String): EngineEvent {
        val pending = incomingTransfers[transferId] ?: return EngineEvent.Error("Unknown transfer: $transferId")

        return try {
            pending.handler.accept(savePath)
            EngineEvent.TransferUpdate(
                transferId = transferId,
                direction = "INCOMING",
                bytesTransferred = 0,
                totalBytes = pending.totalBytes,
                speedBps = 0,
                status = "IN_PROGRESS",
                peerId = pending.peerId,
                filename = pending.fileName
            )
        } catch (e: Exception) {
            EngineEvent.Error(e.message ?: "Failed to accept transfer")
        }
    }

    actual fun rejectFile(transferId: String): EngineEvent {
        val pending = incomingTransfers.remove(transferId) ?: return EngineEvent.Error("Unknown transfer: $transferId")

        return try {
            pending.handler.reject()
            emitTransferUpdate(
                transferId = transferId,
                direction = "INCOMING",
                bytesTransferred = 0,
                totalBytes = pending.totalBytes,
                speedBps = 0,
                status = "FAILED",
                peerId = pending.peerId,
                filename = pending.fileName,
                message = "Rejected by user"
            )
            EngineEvent.TransferUpdate(
                transferId = transferId,
                direction = "INCOMING",
                bytesTransferred = 0,
                totalBytes = pending.totalBytes,
                speedBps = 0,
                status = "FAILED",
                peerId = pending.peerId,
                filename = pending.fileName,
                message = "Rejected by user"
            )
        } catch (e: Exception) {
            EngineEvent.Error(e.message ?: "Failed to reject transfer")
        }
    }

    private fun startDiscoveryLoops() {
        heartbeatJob?.cancel()
        discoveryJob?.cancel()
        peerSweepJob?.cancel()

        val currentNode = host ?: return
        println("Starting mDNS discovery with service tag: _sharething._tcp.local.")
        val mdns = MDnsDiscovery(
            host = currentNode,
            serviceTag = "_sharething._tcp.local.",
            queryInterval = 120,
            address = getLocalIpv4AddressObject()
        )
        mdns.addHandler { peerInfo ->
            println("Raw mDNS payload received for peer: ${peerInfo.peerId.toBase58()}")
            handleMdnsPeerFound(peerInfo)
        }

        mdns.start()
        mndsService = mdns

        peerSweepJob = scope.launch {
            while (isActive && host != null) {
                delay(10_000)
                sweepStalePeers()
            }
        }

        if (discoveryServers.isEmpty()) {
            return
        }

        registerWithDiscoveryServers()

        heartbeatJob = scope.launch {
            while (isActive && host != null) {
                heartbeatDiscoveryServers()
                delay(15_000)
            }
        }

        discoveryJob = scope.launch {
            while (isActive && host != null) {
                pollDiscoveryServers()
                delay(5_000)
            }
        }
    }

    private suspend fun sweepStalePeers() {
        val now = System.currentTimeMillis()
        val staleThreshold = 25_000L

        for ((peerId, peer) in knownPeers.toList()) {
            if (now - peer.lastSeenMillis < staleThreshold) {
                continue
            }

            val isReachable = verifyPeerReachability(peer)

            if (isReachable) {
                peer.lastSeenMillis = System.currentTimeMillis()
            } else {
                knownPeers.remove(peerId)
                CommandDispatcher.emit(EngineEvent.PeerOffline(peerId))
            }
        }
    }

    private suspend fun verifyPeerReachability(peer: KnownPeer): Boolean = withContext(Dispatchers.IO) {
        val node = host ?: return@withContext false
        try {
            val peerIdObj = PeerId.fromBase58(peer.peerId)
            val multiaddrs = peer.addresses.map { Multiaddr(it) }.toTypedArray()

            node.network.connect(peerIdObj, *multiaddrs).get(5, TimeUnit.SECONDS)
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun registerWithDiscoveryServers() {
        val node = host ?: return
        val request = DiscoveryRegisterRequest(
            peerId = node.peerId.toBase58(), nick = nickname, addresses = currentListenAddresses(), platform = "desktop"
        )

        for (server in discoveryServers) {
            try {
                val httpRequest = HttpRequest.newBuilder(
                    URI.create("$server/api/peers")
                ).header("Content-Type", "application/json")
                    .POST(HttpRequest.BodyPublishers.ofString(networkJson.encodeToString(request))).build()
                httpClient.send(httpRequest, HttpResponse.BodyHandlers.discarding())
            } catch (_: Exception) {
            }
        }
    }

    private fun unregisterFromDiscoveryServers() {
        val node = host ?: return
        for (server in discoveryServers) {
            try {
                val httpRequest = HttpRequest.newBuilder(
                    URI.create("$server/api/peers/${node.peerId.toBase58()}")
                ).DELETE().build()
                httpClient.send(httpRequest, HttpResponse.BodyHandlers.discarding())
            } catch (_: Exception) {
            }
        }
    }

    private fun heartbeatDiscoveryServers() {
        val node = host ?: return
        for (server in discoveryServers) {
            try {
                val heartbeatRequest = HttpRequest.newBuilder(
                    URI.create("$server/api/peers/${node.peerId.toBase58()}/heartbeat")
                ).POST(HttpRequest.BodyPublishers.noBody()).build()
                val response = httpClient.send(heartbeatRequest, HttpResponse.BodyHandlers.discarding())
                if (response.statusCode() == 404) {
                    registerWithDiscoveryServers()
                }
            } catch (_: Exception) {
            }
        }
    }

    private fun pollDiscoveryServers() {
        val node = host ?: return
        val selfPeerId = node.peerId.toBase58()

        for (server in discoveryServers) {
            try {
                val request = HttpRequest.newBuilder(
                    URI.create("$server/api/peers")
                ).GET().build()
                val response = httpClient.send(request, HttpResponse.BodyHandlers.ofString())
                if (response.statusCode() !in 200..299) {
                    continue
                }

                val payload = networkJson.decodeFromString<DiscoveryPeersResponse>(response.body())
                for (peer in payload.peers) {
                    if (peer.peerId == selfPeerId) continue

                    val previous = knownPeers[peer.peerId]
                    val resolvedNickname = peer.nick?.takeIf { it.isNotBlank() } ?: peer.peerId

                    if (previous == null) {
                        val discovered = KnownPeer(
                            peerId = peer.peerId,
                            nickname = resolvedNickname,
                            addresses = peer.addresses,
                            lastSeenMillis = System.currentTimeMillis()
                        )
                        knownPeers[peer.peerId] = discovered
                        CommandDispatcher.emit(
                            EngineEvent.PeerDiscovered(
                                peerId = discovered.peerId,
                                nickname = discovered.nickname,
                                addresses = discovered.addresses
                            )
                        )
                    } else {
                        previous.lastSeenMillis = System.currentTimeMillis()

                        if (previous.nickname != resolvedNickname) {
                            CommandDispatcher.emit(
                                EngineEvent.PeerNicknameChanged(
                                    peerId = peer.peerId, newNickname = resolvedNickname
                                )
                            )
                        }
                        if (previous.addresses != peer.addresses) {
                            val updated = previous.copy(nickname = resolvedNickname, addresses = peer.addresses)
                            knownPeers[peer.peerId] = updated
                            CommandDispatcher.emit(
                                EngineEvent.PeerDiscovered(
                                    peerId = updated.peerId,
                                    nickname = updated.nickname,
                                    addresses = updated.addresses
                                )
                            )
                        }
                    }
                }
                return
            } catch (_: Exception) {
                continue
            }
        }
    }

    private fun handleMdnsPeerFound(peerInfo: PeerInfo) {
        val node = host ?: return
        val selfPeerId = node.peerId.toBase58()
        var peerIdStr = peerInfo.peerId.toBase58()

        if (peerIdStr.length == 53 && peerIdStr.startsWith("412D")) {
            peerIdStr = peerIdStr.substring(1)
        }

        if (peerIdStr == selfPeerId) return

        val previous = knownPeers[peerIdStr]
        val resolvedNickname = previous?.nickname ?: peerIdStr
        val newAddresses = peerInfo.addresses.map { it.toString() }

        if (previous == null) {
            val discovered = KnownPeer(
                peerId = peerIdStr,
                nickname = resolvedNickname,
                addresses = newAddresses,
                lastSeenMillis = System.currentTimeMillis()
            )
            knownPeers[peerIdStr] = discovered
            CommandDispatcher.emit(
                EngineEvent.PeerDiscovered(
                    peerId = discovered.peerId, nickname = discovered.nickname, addresses = discovered.addresses
                )
            )
        } else {
            previous.lastSeenMillis = System.currentTimeMillis()

            if (previous.addresses != newAddresses) {
                val updated = previous.copy(addresses = newAddresses)
                knownPeers[peerIdStr] = updated
                CommandDispatcher.emit(
                    EngineEvent.PeerDiscovered(
                        peerId = updated.peerId, nickname = updated.nickname, addresses = updated.addresses
                    )
                )
            }
        }
    }

    private fun buildHost(privKey: PrivKey, port: Int): Host {
        return HostBuilder().builderModifier { b ->
            b.identity.factory = { privKey }
            b.protocols.add(Identify())
        }.listen("/ip4/0.0.0.0/tcp/$port")
            .build()
    }

    private fun currentListenAddresses(): List<String> {
        val node = host ?: return emptyList()
        val peerId = node.peerId.toBase58()
        val synthesizedIpv4 = localIpv4Address()?.let {
            "/ip4/$it/tcp/$port/p2p/$peerId"
        }

        val advertised = node.listenAddresses().map { address ->
            if (address.getPeerId() == null) {
                address.withP2P(node.peerId).toString()
            } else {
                address.toString()
            }
        }.sorted()

        return linkedSetOf<String>().apply {
            synthesizedIpv4?.let { add(it) }
            addAll(advertised)
        }.toList()
    }

    private fun currentPort(node: Host): Int {
        val tcpAddress = node.listenAddresses().firstOrNull { it.has(Protocol.TCP) && it.has(Protocol.IP4) }
            ?: node.listenAddresses().firstOrNull { it.has(Protocol.TCP) }

        val tcpComponent = tcpAddress?.getFirstComponent(Protocol.TCP)
        return tcpComponent?.stringValue?.toIntOrNull() ?: DEFAULT_PORT
    }

    private fun localIpv4Address(): String? {
        return Collections.list(NetworkInterface.getNetworkInterfaces()).asSequence()
            .filter { it.isUp && !it.isLoopback }.flatMap { Collections.list(it.inetAddresses).asSequence() }
            .filterIsInstance<Inet4Address>().firstOrNull()?.hostAddress
    }

    private fun getLocalIpv4AddressObject(): Inet4Address? {
        return NetworkInterface.getNetworkInterfaces().asSequence().filter { it.isUp && !it.isLoopback }
            .flatMap { it.inetAddresses.asSequence() }.filterIsInstance<Inet4Address>().firstOrNull()
    }

    private fun loadOrCreatePrivateKey(): PrivKey {
        val file = identityFile()
        if (file.exists()) {
            try {
                val stored = identityJson.decodeFromString<StoredIdentity>(file.readText())
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
        file.writeText(identityJson.encodeToString(stored))
    }

    private fun identityFile(): File {
        val userHome = System.getProperty("user.home")
        val osName = System.getProperty("os.name").lowercase()

        val directory = when {
            osName.contains("win") -> {
                val base = System.getenv("LOCALAPPDATA") ?: System.getenv("APPDATA") ?: "$userHome\\AppData\\Local"
                File(base, "ShareThing")
            }

            osName.contains("mac") -> File(
                userHome, "Library/Application Support/ShareThing/data"
            )

            else -> {
                val base = System.getenv("XDG_DATA_HOME") ?: "$userHome/.local/share"
                File(base, "sharething")
            }
        }

        return File(directory, "identity.json")
    }

    private fun normalizeDiscoveryServer(server: String): String {
        val trimmed = server.trim().removeSuffix("/")
        return when {
            trimmed.startsWith("wss://") -> "https://${trimmed.removePrefix("wss://")}"
            trimmed.startsWith("ws://") -> "http://${trimmed.removePrefix("ws://")}"
            else -> trimmed
        }
    }

    private fun emitTransferUpdate(
        transferId: String,
        direction: String,
        bytesTransferred: Long,
        totalBytes: Long,
        speedBps: Long,
        status: String,
        peerId: String? = null,
        filename: String? = null,
        message: String? = null
    ) {
        CommandDispatcher.emit(
            EngineEvent.TransferUpdate(
                transferId = transferId,
                direction = direction,
                bytesTransferred = bytesTransferred,
                totalBytes = totalBytes,
                speedBps = speedBps,
                status = status,
                peerId = peerId,
                filename = filename,
                message = message
            )
        )
    }

    private fun createFileTransferBinding(
        outboundTransfer: OutgoingTransfer?
    ): ProtocolBinding<FileTransferMessageHandler> {
        return ProtocolBinding.createSimple(FILE_PROTOCOL_ID, P2PChannelHandler { ch ->
            val stream = ch as Stream
            val handler = FileTransferMessageHandler(outboundTransfer)
            stream.pushHandler(ProtocolMessageHandlerAdapter(stream, handler))
            if (outboundTransfer == null) {
                CompletableFuture.completedFuture(handler)
            } else {
                handler.activeFuture
            }
        })
    }

    inner class FileTransferMessageHandler(
        private val outboundTransfer: OutgoingTransfer?
    ) : ProtocolMessageHandler<ByteBuf> {
        private val transferJson = Json { ignoreUnknownKeys = true }
        val activeFuture = CompletableFuture<FileTransferMessageHandler>()

        private var state = StreamState.READING_CONTROL
        private var expectedControlLength = -1
        private var controlHeaderBytesRead = 0
        private val controlHeaderBuffer = ByteArray(4)
        private var controlPayloadBuffer = ByteArray(0)
        private var controlPayloadBytesRead = 0

        private var transferId: String = outboundTransfer?.transferId ?: UUID.randomUUID().toString()
        private var remotePeerId: String = outboundTransfer?.targetPeerId ?: ""
        private var fileName: String = outboundTransfer?.file?.name ?: ""
        private var totalBytes: Long = outboundTransfer?.file?.length() ?: 0L
        private var bytesTransferred: Long = 0L
        private var transferStartMillis: Long = 0L

        private lateinit var stream: Stream
        private var nettyChannel: io.netty.channel.Channel? = null

        private val diskWriteChannel = Channel<ByteArray>(Channel.UNLIMITED)
        private var diskWriteJob: Job? = null

        override fun onActivated(stream: Stream) {
            this.stream = stream
            stream.pushHandler(object : ChannelInboundHandlerAdapter() {
                override fun handlerAdded(ctx: ChannelHandlerContext) {
                    nettyChannel = ctx.channel()
                }
            })

            activeFuture.complete(this)



            if (outboundTransfer != null) {
                val offer = FileTransferControl.Offer(
                    transferId = outboundTransfer.transferId,
                    peerId = host?.peerId?.toBase58() ?: "",
                    nickname = nickname,
                    filename = outboundTransfer.file.name,
                    totalBytes = outboundTransfer.file.length()
                )
                writeControl(offer)
                state = StreamState.WAITING_FOR_RESPONSE
            }
        }

        override fun onMessage(stream: Stream, msg: ByteBuf) {
            println("DEBUG: onMessage received ${msg.readableBytes()} bytes in state: $state")
            when (state) {
                StreamState.READING_CONTROL, StreamState.WAITING_FOR_RESPONSE -> readControl(msg)
                StreamState.RECEIVING_FILE -> readFileBytes(msg)
                StreamState.SENDING_FILE, StreamState.CLOSED -> {}
            }
        }

        // Signal the coroutine to finish writing buffered bytes and close
        override fun onClosed(stream: Stream) {
            diskWriteChannel.close()
            incomingTransfers.remove(transferId)
            state = StreamState.CLOSED
        }

        override fun onException(cause: Throwable?) {
            println("DEBUG FATAL: Stream exception caught! ${cause?.message}")
            cause?.printStackTrace()
            emitTransferUpdate(
                transferId = transferId,
                direction = if (outboundTransfer != null) "OUTGOING" else "INCOMING",
                bytesTransferred = bytesTransferred,
                totalBytes = totalBytes,
                speedBps = calculateSpeed(bytesTransferred, transferStartMillis),
                status = "FAILED",
                peerId = remotePeerId.ifBlank { null },
                filename = fileName.ifBlank { null },
                message = cause?.message
            )
        }

        fun accept(savePath: String) {
            val destination = File(savePath)
            destination.parentFile?.mkdirs()
            transferStartMillis = System.currentTimeMillis()
            state = StreamState.RECEIVING_FILE

            // Decoupled disk writing coroutine
            diskWriteJob = scope.launch(Dispatchers.IO) {
                try {
                    destination.outputStream().use { output ->
                        for (chunk in diskWriteChannel) {
                            output.write(chunk)
                            bytesTransferred += chunk.size

                            emitTransferUpdate(
                                transferId = transferId,
                                direction = "INCOMING",
                                bytesTransferred = bytesTransferred,
                                totalBytes = totalBytes,
                                speedBps = calculateSpeed(bytesTransferred, transferStartMillis),
                                status = "IN_PROGRESS",
                                peerId = remotePeerId,
                                filename = fileName
                            )
                        }
                    }

                    // Final success emit once the stream completes and channel closes
                    val finalStatus = if (bytesTransferred >= totalBytes) "COMPLETED" else "FAILED"
                    emitTransferUpdate(
                        transferId = transferId,
                        direction = "INCOMING",
                        bytesTransferred = bytesTransferred,
                        totalBytes = totalBytes,
                        speedBps = calculateSpeed(bytesTransferred, transferStartMillis),
                        status = finalStatus,
                        peerId = remotePeerId,
                        filename = fileName
                    )
                } catch (e: Exception) {
                    emitTransferUpdate(
                        transferId = transferId,
                        direction = "INCOMING",
                        bytesTransferred = bytesTransferred,
                        totalBytes = totalBytes,
                        speedBps = calculateSpeed(bytesTransferred, transferStartMillis),
                        status = "FAILED",
                        peerId = remotePeerId,
                        filename = fileName,
                        message = e.message
                    )
                }
            }

            writeControl(FileTransferControl.Response(transferId = transferId, accepted = true))
        }

        fun reject() {
            writeControl(
                FileTransferControl.Response(
                    transferId = transferId, accepted = false, message = "Rejected by user"
                )
            )
            stream.close()
        }

        private fun readControl(msg: ByteBuf) {
            while (msg.isReadable) {
                if (expectedControlLength < 0) {
                    while (msg.isReadable && controlHeaderBytesRead < 4) {
                        controlHeaderBuffer[controlHeaderBytesRead++] = msg.readByte()
                    }
                    if (controlHeaderBytesRead < 4) {
                        return
                    }
                    expectedControlLength = ByteBuffer.wrap(controlHeaderBuffer).int
                    controlPayloadBuffer = ByteArray(expectedControlLength)
                    controlPayloadBytesRead = 0
                }

                val remaining = expectedControlLength - controlPayloadBytesRead
                val readable = minOf(msg.readableBytes(), remaining)
                msg.readBytes(controlPayloadBuffer, controlPayloadBytesRead, readable)
                controlPayloadBytesRead += readable

                if (controlPayloadBytesRead == expectedControlLength) {
                    val payload = String(controlPayloadBuffer, StandardCharsets.UTF_8)
                    handleControl(payload)
                    expectedControlLength = -1
                    controlHeaderBytesRead = 0
                    controlPayloadBytesRead = 0
                }
            }
        }

        private fun handleControl(payload: String) {
            println("DEBUG: Attempting to decode payload: $payload")
            try {
                when (val control = transferJson.decodeFromString<FileTransferControl>(payload)) {
                    is FileTransferControl.Offer -> {
                        transferId = control.transferId
                        remotePeerId = control.peerId
                        fileName = control.filename
                        totalBytes = control.totalBytes
                        incomingTransfers[transferId] = PendingIncomingTransfer(
                            transferId = transferId,
                            peerId = remotePeerId,
                            fileName = fileName,
                            totalBytes = totalBytes,
                            handler = this
                        )
                        CommandDispatcher.emit(
                            EngineEvent.IncomingFileRequest(
                                transferId = transferId,
                                peerId = remotePeerId,
                                filename = fileName,
                                totalBytes = totalBytes
                            )
                        )
                    }

                    is FileTransferControl.Response -> {
                        if (!control.accepted) {
                            emitTransferUpdate(
                                transferId = transferId,
                                direction = "OUTGOING",
                                bytesTransferred = 0,
                                totalBytes = totalBytes,
                                speedBps = 0,
                                status = "FAILED",
                                peerId = remotePeerId,
                                filename = fileName,
                                message = control.message ?: "Rejected"
                            )
                            stream.close()
                            return
                        }

                        transferStartMillis = System.currentTimeMillis()
                        state = StreamState.SENDING_FILE
                        scope.launch {
                            sendFileBytes()
                        }
                    }
                }
            } catch (e: Exception){
                println("DEBUG FATAL: JSON Parsing crashed! ${e.message}")
                e.printStackTrace()
            }
        }

        private suspend fun sendFileBytes() = withContext(Dispatchers.IO) {
            val transfer = outboundTransfer ?: return@withContext
            try {
                transfer.file.inputStream().use { input ->
                    val buffer = ByteArray(FILE_CHUNK_SIZE)
                    while (isActive) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        val bytes = buffer.copyOf(read)
                        val buf = Unpooled.wrappedBuffer(bytes)

                        val channel = nettyChannel
                        if (channel != null) {
                            channel.writeAndFlush(buf).awaitNetty()
                        } else {
                            stream.writeAndFlush(buf)
                            delay(5.milliseconds)
                        }

                        bytesTransferred += read
                        emitTransferUpdate(
                            transferId = transfer.transferId,
                            direction = "OUTGOING",
                            bytesTransferred = bytesTransferred,
                            totalBytes = transfer.file.length(),
                            speedBps = calculateSpeed(bytesTransferred, transferStartMillis),
                            status = "IN_PROGRESS",
                            peerId = transfer.targetPeerId,
                            filename = transfer.file.name
                        )
                    }
                }

                stream.closeWrite().await()

                emitTransferUpdate(
                    transferId = transfer.transferId,
                    direction = "OUTGOING",
                    bytesTransferred = bytesTransferred,
                    totalBytes = transfer.file.length(),
                    speedBps = calculateSpeed(bytesTransferred, transferStartMillis),
                    status = "COMPLETED",
                    peerId = transfer.targetPeerId,
                    filename = transfer.file.name
                )
            } catch (e: Exception) {
                emitTransferUpdate(
                    transferId = transfer.transferId,
                    direction = "OUTGOING",
                    bytesTransferred = bytesTransferred,
                    totalBytes = transfer.file.length(),
                    speedBps = calculateSpeed(bytesTransferred, transferStartMillis),
                    status = "FAILED",
                    peerId = transfer.targetPeerId,
                    filename = transfer.file.name,
                    message = e.message
                )
            }
        }

        private fun readFileBytes(msg: ByteBuf) {
            val readable = msg.readableBytes()
            if (readable <= 0) return

            val bytes = ByteArray(readable)
            msg.readBytes(bytes)

            diskWriteChannel.trySend(bytes)
        }

        private fun writeControl(control: FileTransferControl) {
            val encoded = transferJson.encodeToString(control).toByteArray(StandardCharsets.UTF_8)
            val frame = ByteBuffer.allocate(4 + encoded.size).putInt(encoded.size).put(encoded).array()
            stream.writeAndFlush(Unpooled.wrappedBuffer(frame))
        }
    }

    private fun calculateSpeed(bytesTransferred: Long, startMillis: Long): Long {
        if (startMillis <= 0L) return 0L
        val elapsedMillis = (System.currentTimeMillis() - startMillis).coerceAtLeast(1L)
        return bytesTransferred * 1000L / elapsedMillis
    }

    private enum class StreamState {
        READING_CONTROL, WAITING_FOR_RESPONSE, SENDING_FILE, RECEIVING_FILE, CLOSED
    }

    private companion object {
        const val DEFAULT_PORT = 4101
        const val FILE_PROTOCOL_ID = "/sharething/files/1.0.0"
        const val FILE_CHUNK_SIZE = 64 * 1024
    }
}
