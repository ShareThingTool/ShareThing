package pl.norwood.sharething

import co.touchlab.kermit.Logger
import dorkbox.notify.Notify
import io.libp2p.core.*
import io.libp2p.core.crypto.*
import io.libp2p.core.dsl.HostBuilder
import io.libp2p.core.multiformats.Multiaddr
import io.libp2p.core.multiformats.Protocol
import io.libp2p.core.multistream.ProtocolBinding
import io.libp2p.core.mux.StreamMuxerProtocol
import io.libp2p.discovery.MDnsDiscovery
import io.libp2p.protocol.Identify
import io.libp2p.protocol.ProtocolMessageHandler
import io.libp2p.protocol.ProtocolMessageHandlerAdapter
import io.libp2p.protocol.circuit.CircuitHopProtocol
import io.libp2p.protocol.circuit.CircuitStopProtocol
import io.libp2p.protocol.circuit.RelayTransport
import io.netty.buffer.ByteBuf
import io.netty.buffer.Unpooled
import io.netty.channel.ChannelHandlerContext
import io.netty.channel.ChannelInboundHandlerAdapter
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.future.await
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import pl.norwood.sharething.data.FileTransferControl
import pl.norwood.sharething.data.KnownPeer
import pl.norwood.sharething.data.OutgoingTransfer
import pl.norwood.sharething.data.PendingIncomingTransfer
import pl.norwood.sharething.data.StoredIdentity
import java.io.File
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.MulticastSocket
import java.net.NetworkInterface
import java.net.SocketTimeoutException
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
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.time.Duration.Companion.milliseconds
import java.util.Optional

actual class P2PEngine actual constructor() {
    private var host: Host? = null
    private var port: Int = 0
    private var nickname: String = ""
    private var mndsService: MDnsDiscovery? = null
    private var discoveryServers: List<String> = emptyList()
    private var relayAddrs: List<String> = emptyList()
    private val relayExecutor = Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "relay-transport").also { it.isDaemon = true }
    }

    private val identityJson = Json {
        ignoreUnknownKeys = true
        prettyPrint = true
    }
    private val networkJson = Json {
        ignoreUnknownKeys = true
    }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val httpClient = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build()
    private val log = Logger.withTag("P2PEngine")

    private var heartbeatJob: Job? = null
    private var discoveryJob: Job? = null
    private var peerSweepJob: Job? = null
    private var lanBroadcastJob: Job? = null

    private val knownPeers = ConcurrentHashMap<String, KnownPeer>()
    private val incomingTransfers = ConcurrentHashMap<String, PendingIncomingTransfer>()
    private val transferNotificationDedup = ConcurrentHashMap<String, Boolean>()
    private val fileBinding: ProtocolBinding<FileTransferMessageHandler> = createFileTransferBinding()

    actual fun startNode(
        nickname: String,
        discoveryServers: List<String>,
        relayAddrs: List<String>
    ): EngineEvent.NodeStarted {
        log.i {
            "start_node requested nickname=$nickname discoveryServers=${discoveryServers.size} relayAddrs=${relayAddrs.size}"
        }
        this.nickname = nickname
        this.discoveryServers = discoveryServers.map(::normalizeDiscoveryServer)
        this.relayAddrs = relayAddrs

        if (host != null) {
            return EngineEvent.NodeStarted(
                peerId = host!!.peerId.toBase58(), listenAddresses = currentListenAddresses()
            )
        }

        val candidatePorts = listOf(DEFAULT_PORT, 0)
        var lastError: Exception? = null

        for (candidatePort in candidatePorts) {
            try {
                log.d { "start_node attempting port=$candidatePort" }
                val privKey = loadOrCreatePrivateKey()
                val node = buildHost(privKey, candidatePort, relayAddrs)
                node.addProtocolHandler(fileBinding as ProtocolBinding<Any>)
                node.start().get()
                host = node
                port = currentPort(node)
                startDiscoveryLoops()
                log.i {
                    "start_node success peerId=${node.peerId.toBase58()} listenAddresses=${currentListenAddresses().size}"
                }

                return EngineEvent.NodeStarted(
                    peerId = node.peerId.toBase58(), listenAddresses = currentListenAddresses()
                )
            } catch (e: Exception) {
                lastError = e
                host = null
                log.w(e) { "start_node failed on port=$candidatePort" }
            }
        }

        throw lastError ?: IllegalStateException("Desktop node failed to start")
    }

    actual fun stopNode() {
        log.i { "stop_node requested" }
        runBlocking {
            heartbeatJob?.cancelAndJoin()
            heartbeatJob = null
            discoveryJob?.cancelAndJoin()
            discoveryJob = null
            peerSweepJob?.cancelAndJoin()
            peerSweepJob = null
            lanBroadcastJob?.cancelAndJoin()
            lanBroadcastJob = null
        }

        mndsService?.stop()
        mndsService = null

        knownPeers.clear()
        incomingTransfers.clear()
        transferNotificationDedup.clear()
        unregisterFromDiscoveryServers()

        host?.stop()?.get()
        host = null
        port = 0
        log.i { "stop_node completed" }
        CommandDispatcher.emit(EngineEvent.NodeStopped)
    }

    actual fun sendFile(targetPeerId: String, filePath: String): EngineEvent {
        host ?: return EngineEvent.Error("Desktop node is not running")
        val target = knownPeers[targetPeerId] ?: return EngineEvent.Error("Unknown peer: $targetPeerId")
        val file = File(filePath)
        if (!file.exists() || !file.isFile) {
            return EngineEvent.Error("File does not exist: $filePath")
        }

        val transferId = UUID.randomUUID().toString()
        val transfer = OutgoingTransfer(
            transferId = transferId,
            targetPeerId = targetPeerId,
            targetNickname = target.nickname,
            file = file
        )
        log.i {
            "send_file queued id=$transferId target=$targetPeerId file=${file.name} bytes=${file.length()} addrs=${target.addresses.size}"
        }

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
                val nodeRef = host ?: throw IllegalStateException("Desktop node is not running")
                val peerIdObj = PeerId.fromBase58(target.peerId)
                val addresses = target.addresses.map { Multiaddr(it) }.toTypedArray()

                log.d { "send_file dial_start id=$transferId target=$targetPeerId addrs=${target.addresses.size}" }
                val handler = fileBinding.dial(nodeRef, peerIdObj, *addresses).controller.await()
                log.i { "send_file stream_established id=$transferId target=$targetPeerId" }
                handler.initiateSend(transfer)
                log.d { "send_file offer_sent id=$transferId target=$targetPeerId" }
            } catch (e: Exception) {
                log.e(e) { "send_file dial_or_offer_failed id=$transferId target=$targetPeerId" }
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
        log.i {
            "accept_file requested id=$transferId peer=${pending.peerId} file=${pending.fileName} savePath=$savePath"
        }

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
        log.i {
            "reject_file requested id=$transferId peer=${pending.peerId} file=${pending.fileName}"
        }

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
        lanBroadcastJob?.cancel()

        val currentNode = host ?: return
        log.i { "mdns_start serviceTag=_sharething._tcp.local." }
        try {
            val mdns = MDnsDiscovery(
                host = currentNode,
                serviceTag = "_sharething._tcp.local.",
                queryInterval = 120,
                address = getLocalIpv4AddressObject()
            )
            mdns.addHandler { peerInfo ->
                log.v { "mdns_payload peer=${peerInfo.peerId.toBase58()}" }
                handleMdnsPeerFound(peerInfo)
            }
            mdns.start()
            mndsService = mdns
        } catch (e: Exception) {
            log.w(e) { "mdns_start_failed discovery continues without mdns" }
        }

        startLANBroadcast(currentNode)

        peerSweepJob = scope.launch {
            while (isActive && host != null) {
                delay(10_000.milliseconds)
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
                delay(15_000.milliseconds)
            }
        }

        discoveryJob = scope.launch {
            while (isActive && host != null) {
                pollDiscoveryServers()
                delay(5_000.milliseconds)
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
                log.i { "peer_offline peerId=$peerId" }
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
                        log.i {
                            "peer_discovered source=discovery peer=${discovered.peerId} nick=${discovered.nickname} addrs=${discovered.addresses.size}"
                        }
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
                            log.i {
                                "peer_nick_changed source=discovery peer=${peer.peerId} newNick=$resolvedNickname"
                            }
                            CommandDispatcher.emit(
                                EngineEvent.PeerNicknameChanged(
                                    peerId = peer.peerId, newNickname = resolvedNickname
                                )
                            )
                        }
                        if (previous.addresses != peer.addresses) {
                            val updated = previous.copy(nickname = resolvedNickname, addresses = peer.addresses)
                            knownPeers[peer.peerId] = updated
                            log.d {
                                "peer_addresses_changed source=discovery peer=${updated.peerId} addrs=${updated.addresses.size}"
                            }
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
            log.i {
                "peer_discovered source=mdns peer=${discovered.peerId} nick=${discovered.nickname} addrs=${discovered.addresses.size}"
            }
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
                log.d { "peer_addresses_changed source=mdns peer=${updated.peerId} addrs=${updated.addresses.size}" }
                CommandDispatcher.emit(
                    EngineEvent.PeerDiscovered(
                        peerId = updated.peerId, nickname = updated.nickname, addresses = updated.addresses
                    )
                )
            }
        }
    }

    private fun buildHost(privKey: PrivKey, port: Int, relayAddrs: List<String> = emptyList()): Host {
        val relayCandidates = buildRelayCandidates(relayAddrs)

        if (relayCandidates.isEmpty()) {
            return HostBuilder().builderModifier { b ->
                b.identity.factory = { privKey }
                b.protocols.add(Identify())
                b.muxers.clear()
                b.muxers.add(StreamMuxerProtocol.getYamux(32 * 1024 * 1024))
                b.muxers.add(StreamMuxerProtocol.Mplex)
            }.listen("/ip4/0.0.0.0/tcp/$port").build()
        }

        log.i { "buildHost relay_transport relays=${relayCandidates.size}" }

        val stopProtocol = CircuitStopProtocol()
        val stopBinding = CircuitStopProtocol.Binding(stopProtocol)

        // Client-only relay manager: this node does NOT serve as a relay.
        val clientManager = object : CircuitHopProtocol.RelayManager {
            override fun hasReservation(peer: PeerId) = false
            override fun createReservation(peer: PeerId, addr: Multiaddr): Optional<CircuitHopProtocol.Reservation> =
                Optional.empty()
            override fun allowConnection(a: PeerId, b: PeerId): Optional<CircuitHopProtocol.Reservation> =
                Optional.empty()
        }
        val hopBinding = CircuitHopProtocol.Binding(clientManager, stopBinding)

        return HostBuilder().builderModifier { b ->
            b.identity.factory = { privKey }
            b.protocols.add(Identify())
            b.muxers.clear()
            b.muxers.add(StreamMuxerProtocol.getYamux(32 * 1024 * 1024))
            b.muxers.add(StreamMuxerProtocol.Mplex)
            @Suppress("UNCHECKED_CAST")
            b.protocols.add(hopBinding as ProtocolBinding<Any>)
            @Suppress("UNCHECKED_CAST")
            b.protocols.add(stopBinding as ProtocolBinding<Any>)
            b.transports.add { upgrader ->
                val relayTransport = RelayTransport(
                    hopBinding,
                    stopBinding,
                    upgrader,
                    { _ -> relayCandidates },
                    relayExecutor
                )
                stopProtocol.setTransport(relayTransport)
                stopBinding.setTransport(relayTransport)
                relayTransport
            }
        }.listen("/ip4/0.0.0.0/tcp/$port").build()
    }

    private fun buildRelayCandidates(relayAddrs: List<String>): List<RelayTransport.CandidateRelay> {
        return relayAddrs.mapNotNull { addrStr ->
            try {
                val ma = Multiaddr(addrStr)
                val peerId = ma.getPeerId() ?: return@mapNotNull null
                val transportAddr = Multiaddr(
                    ma.components.filter { it.protocol != Protocol.P2P }
                )
                RelayTransport.CandidateRelay(peerId, listOf(transportAddr))
            } catch (e: Exception) {
                log.w(e) { "invalid relay addr: $addrStr" }
                null
            }
        }
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

    private fun preferredLocalIpv4(): Pair<NetworkInterface, Inet4Address>? {
        val virtualKeywords = listOf("virtualbox", "vmware", "hyper-v", "vethernet", "vbox", "virtual")
        return NetworkInterface.getNetworkInterfaces()?.asSequence()
            ?.filter { it.isUp && !it.isLoopback && !it.isVirtual }
            ?.filter { iface ->
                val name = (iface.displayName ?: iface.name).lowercase()
                virtualKeywords.none { name.contains(it) }
            }
            ?.flatMap { iface ->
                iface.inetAddresses.asSequence()
                    .filterIsInstance<Inet4Address>()
                    .filter { !it.isLoopbackAddress }
                    .map { iface to it }
            }
            ?.firstOrNull()
            ?: NetworkInterface.getNetworkInterfaces()?.asSequence()
                ?.filter { it.isUp && !it.isLoopback }
                ?.flatMap { iface ->
                    iface.inetAddresses.asSequence()
                        .filterIsInstance<Inet4Address>()
                        .filter { !it.isLoopbackAddress }
                        .map { iface to it }
                }
                ?.firstOrNull()
    }

    private fun localIpv4Address(): String? = preferredLocalIpv4()?.second?.hostAddress

    private fun startLANBroadcast(host: Host) {
        val port = 4102
        val group = InetAddress.getByName("239.255.99.99")
        val selfId = host.peerId.toBase58()
        val iface = preferredLocalIpv4()?.first

        scope.launch(Dispatchers.IO) {
            val socket = try {
                MulticastSocket(port).apply {
                    soTimeout = 1000
                    if (iface != null) {
                        joinGroup(InetSocketAddress(group, port), iface)
                    } else {
                        joinGroup(group)
                    }
                }
            } catch (_: Exception) { return@launch }
            try {
                val buf = ByteArray(4096)
                while (isActive) {
                    try {
                        val packet = DatagramPacket(buf, buf.size)
                        socket.receive(packet)
                        val text = String(packet.data, 0, packet.length, Charsets.UTF_8)
                        val obj = Json.parseToJsonElement(text).jsonObject
                        val peerId = obj["peerId"]?.jsonPrimitive?.content?.takeIf { it.isNotEmpty() } ?: continue
                        if (peerId == selfId) continue
                        val nick = obj["nickname"]?.jsonPrimitive?.content?.takeIf { it.isNotEmpty() } ?: peerId
                        val addrs = obj["addresses"]?.jsonArray?.map { it.jsonPrimitive.content } ?: emptyList()
                        handleDiscoveredPeer(peerId, nick, addrs)
                    } catch (_: SocketTimeoutException) {
                    } catch (_: Exception) { break }
                }
            } finally {
                try {
                    if (iface != null) socket.leaveGroup(InetSocketAddress(group, port), iface)
                    else socket.leaveGroup(group)
                } catch (_: Exception) {}
                socket.close()
            }
        }

        scope.launch(Dispatchers.IO) {
            val sendSocket = try {
                MulticastSocket().apply {
                    if (iface != null) networkInterface = iface
                    timeToLive = 4
                }
            } catch (_: Exception) { return@launch }
            try {
                while (isActive) {
                    try {
                        val addrs = currentListenAddresses()
                        val payload = buildString {
                            append("{")
                            append("\"peerId\":${Json.encodeToString(selfId)},")
                            append("\"nickname\":${Json.encodeToString(nickname)},")
                            append("\"addresses\":${Json.encodeToString(addrs)}")
                            append("}")
                        }.toByteArray(Charsets.UTF_8)
                        sendSocket.send(DatagramPacket(payload, payload.size, group, port))
                    } catch (_: Exception) {}
                    delay(5_000.milliseconds)
                }
            } finally { sendSocket.close() }
        }
    }

    private fun handleDiscoveredPeer(peerId: String, nick: String, addrs: List<String>) {
        val previous = knownPeers[peerId]
        if (previous == null) {
            val discovered = KnownPeer(
                peerId = peerId,
                nickname = nick,
                addresses = addrs,
                lastSeenMillis = System.currentTimeMillis()
            )
            knownPeers[peerId] = discovered
            log.i { "peer_discovered source=lan_broadcast peer=$peerId nick=$nick addrs=${addrs.size}" }
            CommandDispatcher.emit(
                EngineEvent.PeerDiscovered(peerId = peerId, nickname = nick, addresses = addrs)
            )
        } else {
            previous.lastSeenMillis = System.currentTimeMillis()
            if (previous.addresses != addrs && addrs.isNotEmpty()) {
                val updated = previous.copy(addresses = addrs)
                knownPeers[peerId] = updated
                CommandDispatcher.emit(
                    EngineEvent.PeerDiscovered(peerId = peerId, nickname = nick, addresses = addrs)
                )
            }
        }
    }

    private fun getLocalIpv4AddressObject(): Inet4Address? = preferredLocalIpv4()?.second

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
        log.d {
            "transfer_update id=$transferId direction=$direction status=$status " +
                "bytes=$bytesTransferred/$totalBytes speedBps=$speedBps " +
                "peer=${peerId ?: "unknown"} file=${filename ?: "unknown"} message=${message ?: "-"}"
        }

        if (status == "COMPLETED" || status == "FAILED") {
            val dedupKey = "$transferId:$direction:$status"
            if (transferNotificationDedup.putIfAbsent(dedupKey, true) == null) {
                notifyTransferTerminal(
                    direction = direction,
                    status = status,
                    peerId = peerId,
                    filename = filename,
                    message = message
                )
            }
        }
    }

    private fun notifyTransferRequestSent(peerId: String, fileName: String) {
        notifyDesktop(
            title = "ShareThing",
            text = "Transfer request sent to $peerId for $fileName",
            level = DesktopNotificationLevel.INFO
        )
    }

    private fun notifyTransferRequestIncoming(peerId: String, fileName: String, totalBytes: Long) {
        notifyDesktop(
            title = "ShareThing",
            text = "Incoming transfer request from $peerId for $fileName ($totalBytes bytes)",
            level = DesktopNotificationLevel.INFO
        )
    }

    private fun notifyTransferTerminal(
        direction: String,
        status: String,
        peerId: String?,
        filename: String?,
        message: String?
    ) {
        val safePeerId = peerId ?: "unknown peer"
        val safeFileName = filename ?: "file"
        val suffix = if (message.isNullOrBlank()) "" else " ($message)"

        when {
            direction == "OUTGOING" && status == "COMPLETED" -> notifyDesktop(
                title = "ShareThing",
                text = "Transfer complete: sent $safeFileName to $safePeerId",
                level = DesktopNotificationLevel.INFO
            )

            direction == "OUTGOING" && status == "FAILED" -> notifyDesktop(
                title = "ShareThing",
                text = "Transfer failed: could not send $safeFileName to $safePeerId$suffix",
                level = DesktopNotificationLevel.ERROR
            )

            direction == "INCOMING" && status == "COMPLETED" -> notifyDesktop(
                title = "ShareThing",
                text = "Transfer complete: received $safeFileName from $safePeerId",
                level = DesktopNotificationLevel.INFO
            )

            direction == "INCOMING" && status == "FAILED" -> notifyDesktop(
                title = "ShareThing",
                text = "Transfer failed: could not receive $safeFileName from $safePeerId$suffix",
                level = DesktopNotificationLevel.ERROR
            )
        }
    }

    private fun notifyDesktop(
        title: String,
        text: String,
        level: DesktopNotificationLevel
    ) {
        try {
            val notify = Notify.create()
                .title(title)
                .text(text)

            when (level) {
                DesktopNotificationLevel.INFO -> notify.showInformation()
                DesktopNotificationLevel.WARNING -> notify.showWarning()
                DesktopNotificationLevel.ERROR -> notify.showError()
            }
        } catch (t: Throwable) {
            log.w(t) { "desktop_notification_failed title=$title text=$text" }
        }
    }

    private fun logControl(control: FileTransferControl, scope: String) {
        when (control) {
            is FileTransferControl.Offer -> log.d {
                "control[$scope] OFFER id=${control.transferId} peer=${control.peerId} " +
                    "file=${control.filename} bytes=${control.totalBytes}"
            }

            is FileTransferControl.Response -> log.d {
                "control[$scope] RESPONSE id=${control.transferId} accepted=${control.accepted} " +
                    "msg=${control.message ?: "-"}"
            }

            is FileTransferControl.Completion -> log.d {
                "control[$scope] COMPLETION id=${control.transferId} completed=${control.completed} " +
                    "msg=${control.message ?: "-"}"
            }

            is FileTransferControl.DataAck -> log.v {
                "control[$scope] DATA_ACK id=${control.transferId} bytesReceived=${control.bytesReceived}"
            }
        }
    }

    private fun createFileTransferBinding(): ProtocolBinding<FileTransferMessageHandler> {
        return ProtocolBinding.createSimple(FILE_PROTOCOL_ID, P2PChannelHandler { ch ->
            val stream = ch as Stream
            val handler = FileTransferMessageHandler()
            stream.pushHandler(ProtocolMessageHandlerAdapter(stream, handler))
            CompletableFuture.completedFuture(handler)
        })
    }

    inner class FileTransferMessageHandler(
    ) : ProtocolMessageHandler<ByteBuf> {
        private var outboundTransfer: OutgoingTransfer? = null
        private val transferJson = Json { ignoreUnknownKeys = true }
        val activeFuture = CompletableFuture<FileTransferMessageHandler>()

        private var state = StreamState.READING_CONTROL
        private var expectedControlLength = -1
        private var controlHeaderBytesRead = 0
        private val controlHeaderBuffer = ByteArray(4)
        private var controlPayloadBuffer = ByteArray(0)
        private var controlPayloadBytesRead = 0

        private var transferId: String = ""
        private var remotePeerId: String = ""
        private var fileName: String = ""
        private var totalBytes: Long = 0L
        private var bytesTransferred: Long = 0L
        private var receivedFileBytes: Long = 0L
        private var transferStartMillis: Long = 0L
        private var streamClosed: Boolean = false
        private var completionSent: Boolean = false
        private val transferCompletion = CompletableDeferred<FileTransferControl.Completion>()

        private val ackedBytesFlow = MutableStateFlow(0L)
        private var nextAckAt = ACK_INTERVAL_BYTES

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
            log.v { "data_stream_activated outbound=${outboundTransfer != null}" }
        }

        fun initiateSend(transfer: OutgoingTransfer) {
            outboundTransfer = transfer
            transferId = transfer.transferId
            remotePeerId = transfer.targetPeerId
            fileName = transfer.file.name
            totalBytes = transfer.file.length()
            bytesTransferred = 0L
            receivedFileBytes = 0L
            transferStartMillis = 0L
            completionSent = false
            streamClosed = false
            if (transferCompletion.isCompleted) {
                // New handler instances are created per stream, but keep this safe if reused.
                log.w { "data_initiate_send called with pre-completed completion future id=$transferId" }
            }

            val offer = FileTransferControl.Offer(
                transferId = transferId,
                peerId = host?.peerId?.toBase58() ?: "",
                nickname = nickname,
                filename = fileName,
                totalBytes = totalBytes
            )
            logControl(offer, "data-outbound")
            writeControl(offer)
            state = StreamState.WAITING_FOR_RESPONSE
            log.i { "data_offer_sent id=$transferId peer=$remotePeerId file=$fileName bytes=$totalBytes" }
            notifyTransferRequestSent(peerId = remotePeerId, fileName = fileName)
        }

        override fun onMessage(stream: Stream, msg: ByteBuf) {
            log.v {
                "data_stream_message state=$state readable=${msg.readableBytes()} transferId=$transferId"
            }
            when (state) {
                StreamState.READING_CONTROL, StreamState.WAITING_FOR_RESPONSE, StreamState.WAITING_FOR_COMPLETION -> readControl(
                    msg
                )
                StreamState.SENDING_FILE -> readControl(msg)
                StreamState.RECEIVING_FILE -> readFileBytes(msg)
                StreamState.CLOSED -> {}
            }
        }

        // Signal the coroutine to finish writing buffered bytes and close
        override fun onClosed(stream: Stream) {
            streamClosed = true
            diskWriteChannel.close()
            incomingTransfers.remove(transferId)
            log.d { "data_stream_closed transferId=$transferId outbound=${outboundTransfer != null}" }
            if (outboundTransfer != null && !transferCompletion.isCompleted) {
                transferCompletion.complete(
                    FileTransferControl.Completion(
                        transferId = transferId,
                        completed = false,
                        message = "Transfer stream closed before completion acknowledgement"
                    )
                )
            }
            state = StreamState.CLOSED
        }

        override fun onException(cause: Throwable?) {
            log.e(cause) { "data_stream_exception transferId=$transferId outbound=${outboundTransfer != null}" }
            if (outboundTransfer != null && !transferCompletion.isCompleted) {
                transferCompletion.complete(
                    FileTransferControl.Completion(
                        transferId = transferId,
                        completed = false,
                        message = cause?.message ?: "Stream error"
                    )
                )
            }
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
            log.i { "data_accept id=$transferId savePath=$savePath" }
            val destination = File(savePath)
            destination.parentFile?.mkdirs()
            transferStartMillis = System.currentTimeMillis()
            receivedFileBytes = 0L
            state = StreamState.RECEIVING_FILE

            // Decoupled disk writing coroutine
            diskWriteJob = scope.launch(Dispatchers.IO) {
                try {
                    destination.outputStream().use { output ->
                        for (chunk in diskWriteChannel) {
                            output.write(chunk)
                            bytesTransferred += chunk.size

                            if (bytesTransferred >= nextAckAt) {
                                writeControl(FileTransferControl.DataAck(
                                    transferId = transferId,
                                    bytesReceived = bytesTransferred
                                ))
                                nextAckAt = bytesTransferred + ACK_INTERVAL_BYTES
                            }

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

                    val completed = bytesTransferred == totalBytes
                    val failureMessage = if (completed) null else "Received $bytesTransferred/$totalBytes bytes"
                    emitTransferUpdate(
                        transferId = transferId,
                        direction = "INCOMING",
                        bytesTransferred = bytesTransferred,
                        totalBytes = totalBytes,
                        speedBps = calculateSpeed(bytesTransferred, transferStartMillis),
                        status = if (completed) "COMPLETED" else "FAILED",
                        peerId = remotePeerId,
                        filename = fileName,
                        message = failureMessage
                    )
                    incomingTransfers.remove(transferId)
                    if (sendCompletion(completed = completed, message = failureMessage)) {
                        delay(50.milliseconds)
                    }
                    stream.close()
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
                    incomingTransfers.remove(transferId)
                    if (sendCompletion(completed = false, message = e.message ?: "File write failed")) {
                        delay(50.milliseconds)
                    }
                    stream.close()
                }
            }

            writeControl(FileTransferControl.Response(transferId = transferId, accepted = true))
        }

        fun reject() {
            log.i { "data_reject id=$transferId" }
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
                    if (expectedControlLength <= 0 || expectedControlLength > MAX_CONTROL_FRAME_BYTES) {
                        log.w { "data_control_frame_invalid size=$expectedControlLength id=$transferId" }
                        stream.close()
                        return
                    }
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
            try {
                when (val control = transferJson.decodeFromString<FileTransferControl>(payload)) {
                    is FileTransferControl.Offer -> {
                        logControl(control, "data-inbound")
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
                        notifyTransferRequestIncoming(
                            peerId = remotePeerId,
                            fileName = fileName,
                            totalBytes = totalBytes
                        )
                    }

                    is FileTransferControl.Response -> {
                        logControl(control, "data-inbound")
                        if (control.transferId != transferId) {
                            log.w { "data_response_mismatch expected=$transferId got=${control.transferId}" }
                            return
                        }
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
                        log.i { "data_response_accepted id=$transferId; begin send" }
                        scope.launch {
                            sendFileBytes()
                        }
                    }

                    is FileTransferControl.Completion -> {
                        logControl(control, "data-inbound")
                        if (outboundTransfer == null || control.transferId != transferId) {
                            return
                        }
                        if (!transferCompletion.isCompleted) {
                            transferCompletion.complete(control)
                        }
                    }

                    is FileTransferControl.DataAck -> {
                        ackedBytesFlow.update { maxOf(it, control.bytesReceived) }
                    }
                }
            } catch (e: Exception) {
                log.w(e) { "data_control_decode_failed transferId=$transferId payloadSize=${payload.length}" }
            }
        }

        private suspend fun sendFileBytes() = withContext(Dispatchers.IO) {
            val transfer = outboundTransfer ?: return@withContext
            log.i { "data_send_start id=${transfer.transferId} file=${transfer.file.name} bytes=${transfer.file.length()}" }
            try {
                transfer.file.inputStream().use { input ->
                    val buffer = ByteArray(FILE_CHUNK_SIZE)
                    while (isActive) {
                        val unacked = bytesTransferred - ackedBytesFlow.value
                        if (unacked >= MAX_UNACKED_BYTES) {
                            val threshold = bytesTransferred - MAX_UNACKED_BYTES
                            withTimeout(ACK_TIMEOUT_MILLIS) {
                                ackedBytesFlow.first { it >= threshold }
                            }
                        }

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

                state = StreamState.WAITING_FOR_COMPLETION
                val completion = withTimeout(TRANSFER_COMPLETION_TIMEOUT_MILLIS) {
                    transferCompletion.await()
                }

                emitTransferUpdate(
                    transferId = transfer.transferId,
                    direction = "OUTGOING",
                    bytesTransferred = bytesTransferred,
                    totalBytes = transfer.file.length(),
                    speedBps = calculateSpeed(bytesTransferred, transferStartMillis),
                    status = if (completion.completed) "COMPLETED" else "FAILED",
                    peerId = transfer.targetPeerId,
                    filename = transfer.file.name,
                    message = if (completion.completed) null else completion.message
                )
                log.i { "data_send_done id=${transfer.transferId} status=${if (completion.completed) "COMPLETED" else "FAILED"}" }
                stream.close()
            } catch (e: Exception) {
                val errorMessage = if (e is TimeoutCancellationException) {
                    "Timed out waiting for receiver acknowledgement"
                } else {
                    e.message
                }
                emitTransferUpdate(
                    transferId = transfer.transferId,
                    direction = "OUTGOING",
                    bytesTransferred = bytesTransferred,
                    totalBytes = transfer.file.length(),
                    speedBps = calculateSpeed(bytesTransferred, transferStartMillis),
                    status = "FAILED",
                    peerId = transfer.targetPeerId,
                    filename = transfer.file.name,
                    message = errorMessage
                )
                log.w(e) { "data_send_failed id=${transfer.transferId}" }
                stream.close()
            }
        }

        private fun readFileBytes(msg: ByteBuf) {
            val readableBytes = msg.readableBytes()
            if (readableBytes <= 0) return

            val remaining = (totalBytes - receivedFileBytes).coerceAtLeast(0L)
            if (remaining == 0L) {
                msg.skipBytes(readableBytes)
                return
            }

            val toRead = minOf(readableBytes.toLong(), remaining).toInt()
            if (toRead <= 0) return

            val bytes = ByteArray(toRead)
            msg.readBytes(bytes)
            receivedFileBytes += toRead

            val sendResult = diskWriteChannel.trySend(bytes)
            if (sendResult.isFailure) {
                log.w { "data_receive_buffer_overflow id=$transferId" }
                emitTransferUpdate(
                    transferId = transferId,
                    direction = "INCOMING",
                    bytesTransferred = bytesTransferred,
                    totalBytes = totalBytes,
                    speedBps = calculateSpeed(bytesTransferred, transferStartMillis),
                    status = "FAILED",
                    peerId = remotePeerId,
                    filename = fileName,
                    message = "Incoming transfer buffer overflow"
                )
                incomingTransfers.remove(transferId)
                sendCompletion(completed = false, message = "Incoming transfer buffer overflow")
                stream.close()
                return
            }

            if (msg.isReadable) {
                log.w { "data_receive_oversized_payload id=$transferId extra=${msg.readableBytes()}" }
                msg.skipBytes(msg.readableBytes())
                emitTransferUpdate(
                    transferId = transferId,
                    direction = "INCOMING",
                    bytesTransferred = bytesTransferred,
                    totalBytes = totalBytes,
                    speedBps = calculateSpeed(bytesTransferred, transferStartMillis),
                    status = "FAILED",
                    peerId = remotePeerId,
                    filename = fileName,
                    message = "Sender exceeded declared transfer size"
                )
                incomingTransfers.remove(transferId)
                sendCompletion(completed = false, message = "Sender exceeded declared transfer size")
                stream.close()
                return
            }

            if (receivedFileBytes >= totalBytes) {
                log.d { "data_receive_complete_bytes id=$transferId bytes=$receivedFileBytes" }
                diskWriteChannel.close()
            }
        }

        private fun sendCompletion(
            completed: Boolean,
            message: String? = null
        ): Boolean {
            if (completionSent || streamClosed) return false
            completionSent = true
            writeControl(
                FileTransferControl.Completion(
                    transferId = transferId,
                    completed = completed,
                    message = message
                )
            )
            return true
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

    private enum class DesktopNotificationLevel {
        INFO, WARNING, ERROR
    }

    private enum class StreamState {
        READING_CONTROL, WAITING_FOR_RESPONSE, SENDING_FILE, WAITING_FOR_COMPLETION, RECEIVING_FILE, CLOSED
    }

    private companion object {
        const val DEFAULT_PORT = 4101
        const val FILE_PROTOCOL_ID = "/sharething/files/1.0.0"
        const val FILE_CHUNK_SIZE = 64 * 1024
        const val TRANSFER_COMPLETION_TIMEOUT_MILLIS = 15_000L
        const val MAX_CONTROL_FRAME_BYTES = 1 * 1024 * 1024
        const val ACK_INTERVAL_BYTES = 1 * 1024 * 1024L
        const val MAX_UNACKED_BYTES = 4 * 1024 * 1024L
        const val ACK_TIMEOUT_MILLIS = 30_000L
    }
}
