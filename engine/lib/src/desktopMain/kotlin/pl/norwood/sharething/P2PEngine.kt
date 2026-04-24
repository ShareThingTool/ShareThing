package pl.norwood.sharething

import co.touchlab.kermit.Logger
import dorkbox.notify.Notify
import io.libp2p.core.Host
import io.libp2p.core.PeerId
import io.libp2p.core.PeerInfo
import io.libp2p.core.Stream
import io.libp2p.core.crypto.*
import io.libp2p.core.dsl.HostBuilder
import io.libp2p.core.multiformats.Multiaddr
import io.libp2p.core.multiformats.Protocol
import io.libp2p.core.multistream.ProtocolBinding
import io.libp2p.discovery.MDnsDiscovery
import io.libp2p.protocol.Identify
import io.libp2p.protocol.ProtocolMessageHandler
import io.libp2p.protocol.ProtocolMessageHandlerAdapter
import io.libp2p.protocol.autonat.AutonatProtocol
import io.libp2p.protocol.autonat.pb.Autonat
import io.libp2p.protocol.circuit.CircuitHopProtocol
import io.libp2p.protocol.circuit.CircuitStopProtocol
import io.libp2p.protocol.circuit.RelayTransport
import io.netty.buffer.ByteBuf
import io.netty.buffer.Unpooled
import io.netty.channel.ChannelHandlerContext
import io.netty.channel.ChannelInboundHandlerAdapter
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.future.await
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import pl.norwood.sharething.data.*
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface
import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.time.Duration
import java.util.*
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
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
    private val log = Logger.withTag("P2PEngine")

    private var heartbeatJob: Job? = null
    private var discoveryJob: Job? = null
    private var peerSweepJob: Job? = null
    private var autoNatJob: Job? = null
    private var autoNatBinding: AutonatProtocol.Binding? = null
    private var relayTransport: RelayTransport? = null
    private var relayScheduler: ScheduledExecutorService? = null
    private var bootstrapRelays: List<BootstrapRelay> = emptyList()
    private var observedPublicAddress: Multiaddr? = null
    private var natReachability: NatReachability = NatReachability.UNKNOWN
    private var lastAdvertisedAddresses: List<String> = emptyList()

    private val knownPeers = ConcurrentHashMap<String, KnownPeer>()
    private val incomingTransfers = ConcurrentHashMap<String, PendingIncomingTransfer>()
    private val transferNotificationDedup = ConcurrentHashMap<String, Boolean>()
    private val fileBinding: ProtocolBinding<FileTransferMessageHandler> = createFileTransferBinding()

    actual fun startNode(
        nickname: String, discoveryServers: List<String>
    ): EngineEvent.NodeStarted {
        log.i {
            "start_node requested nickname=$nickname discoveryServers=${discoveryServers.size}"
        }
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
                log.d { "start_node attempting port=$candidatePort" }
                val privKey = loadOrCreatePrivateKey()
                val node = buildHost(privKey, candidatePort)
                node.addProtocolHandler(fileBinding as ProtocolBinding<Any>)
                node.start().get()
                host = node
                relayTransport?.setHost(node)
                relayTransport?.initialize()
                port = currentPort(node)
                connectToBootstrapRelays()
                startAutoNatMonitor()
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
            autoNatJob?.cancelAndJoin()
            autoNatJob = null
        }

        mndsService?.stop()
        mndsService = null

        knownPeers.clear()
        incomingTransfers.clear()
        transferNotificationDedup.clear()
        unregisterFromDiscoveryServers()

        host?.stop()?.get()
        relayScheduler?.shutdownNow()
        relayScheduler = null
        relayTransport = null
        autoNatBinding = null
        bootstrapRelays = emptyList()
        observedPublicAddress = null
        natReachability = NatReachability.UNKNOWN
        lastAdvertisedAddresses = emptyList()
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
            transferId = transferId, targetPeerId = targetPeerId, file = file
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
                val addresses = prioritizeDialAddresses(
                    nodeRef, target.addresses.map { Multiaddr(it) }
                ).toTypedArray()

                if (addresses.isEmpty()) {
                    throw IllegalStateException("No supported dial addresses for peer $targetPeerId")
                }

                log.d {
                    "send_file dial_start id=$transferId target=$targetPeerId addrs=${addresses.size} prioritized=${addresses.joinToString()}"
                }
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

        val currentNode = host ?: return
        log.i { "mdns_start serviceTag=_sharething._tcp.local." }
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
                syncDiscoveryRegistrationIfNeeded()
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
            val multiaddrs = prioritizeDialAddresses(
                node, peer.addresses.map { Multiaddr(it) }
            ).toTypedArray()

            if (multiaddrs.isEmpty()) {
                return@withContext false
            }

            node.network.connect(peerIdObj, *multiaddrs).get(5, TimeUnit.SECONDS)
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun registerWithDiscoveryServers() {
        val node = host ?: return
        val addresses = currentListenAddresses()
        val request = DiscoveryRegisterRequest(
            peerId = node.peerId.toBase58(), nick = nickname, addresses = addresses, platform = "desktop"
        )
        lastAdvertisedAddresses = addresses

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

    private fun syncDiscoveryRegistrationIfNeeded() {
        if (discoveryServers.isEmpty()) {
            return
        }

        val currentAddresses = currentListenAddresses()
        if (currentAddresses != lastAdvertisedAddresses) {
            log.i {
                "discovery_addresses_changed direct=${currentAddresses.count { !it.contains("/p2p-circuit") }} relay=${currentAddresses.count { it.contains("/p2p-circuit") }}"
            }
            registerWithDiscoveryServers()
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

                    val resolvedNickname = peer.nick?.takeIf { it.isNotBlank() } ?: peer.peerId
                    upsertKnownPeer(
                        source = "discovery",
                        peerId = peer.peerId,
                        nickname = resolvedNickname,
                        addresses = peer.addresses
                    )
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

        //Upstream bug: Length prefix is not stripped
        if (peerIdStr.length == 53 && peerIdStr.startsWith("412D")) {
            peerIdStr = peerIdStr.substring(1)
        }

        if (peerIdStr == selfPeerId) return

        val resolvedNickname = knownPeers[peerIdStr]?.nickname ?: peerIdStr
        upsertKnownPeer(
            source = "mdns",
            peerId = peerIdStr,
            nickname = resolvedNickname,
            addresses = peerInfo.addresses.map { it.toString() }
        )
    }

    private fun buildHost(privKey: PrivKey, port: Int): Host {
        val autoNatBinding = AutonatProtocol.Binding()
        val circuitStopBinding = CircuitStopProtocol.Binding(CircuitStopProtocol())
        val circuitHopBinding = CircuitHopProtocol.Binding(NoRelayManager, circuitStopBinding)
        val bootstrapRelays = loadBootstrapRelays()
        val relayScheduler = Executors.newSingleThreadScheduledExecutor { runnable ->
            Thread(runnable, "sharething-relay").apply { isDaemon = true }
        }
        var relayTransport: RelayTransport? = null

        val host = HostBuilder().builderModifier { b ->
            b.identity.factory = { privKey }
            b.protocols.add(Identify())
            b.protocols.add(autoNatBinding)
            b.protocols.add(circuitHopBinding)
            b.protocols.add(circuitStopBinding)
            b.transports.add { upgrader ->
                RelayTransport(
                    circuitHopBinding,
                    circuitStopBinding,
                    upgrader,
                    { bootstrapRelays.map(BootstrapRelay::toCandidateRelay) },
                    relayScheduler
                ).also { relay ->
                    relay.setRelayCount(if (bootstrapRelays.isEmpty()) 0 else DEFAULT_RELAY_RESERVATIONS.coerceAtMost(bootstrapRelays.size))
                    relayTransport = relay
                }
            }
        }.listen("/ip4/0.0.0.0/tcp/$port").build()

        this.autoNatBinding = autoNatBinding
        this.bootstrapRelays = bootstrapRelays
        this.relayScheduler = relayScheduler
        this.relayTransport = relayTransport
        this.observedPublicAddress = null
        this.natReachability = NatReachability.UNKNOWN
        this.lastAdvertisedAddresses = emptyList()

        log.w {
            "wan_transport_partial using TCP + circuit-relay + AutoNAT; current jvm-libp2p release does not expose desktop QUIC transport or DCUtR"
        }

        if (bootstrapRelays.isEmpty()) {
            log.w { "relay_bootstrap_empty relay reservations disabled until SHARETHING_BOOTSTRAP_RELAYS or -Dsharething.bootstrapRelays is configured" }
        }

        return host
    }

    private fun currentListenAddresses(): List<String> {
        val node = host ?: return emptyList()
        return currentListenMultiaddrs(node).map { it.toString() }
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

    private fun currentListenMultiaddrs(node: Host, includeRelay: Boolean = true): List<Multiaddr> {
        val addresses = linkedMapOf<String, Multiaddr>()

        fun add(address: Multiaddr?) {
            if (address == null) {
                return
            }

            val normalized = if (address.getPeerId() == null) {
                address.withP2P(node.peerId)
            } else {
                address
            }

            if (!includeRelay && normalized.has(Protocol.P2PCIRCUIT)) {
                return
            }

            addresses.putIfAbsent(normalized.toString(), normalized)
        }

        localIpv4Address()?.let { add(Multiaddr("/ip4/$it/tcp/$port")) }
        observedPublicAddress?.let { add(it) }
        node.listenAddresses().forEach(::add)

        return addresses.values.sortedBy(Multiaddr::toString)
    }

    private fun connectToBootstrapRelays() {
        if (bootstrapRelays.isEmpty()) {
            return
        }

        scope.launch {
            val node = host ?: return@launch
            for (relay in bootstrapRelays) {
                try {
                    node.addressBook.addAddrs(relay.peerId, RELAY_ADDRESS_TTL_MILLIS, *relay.dialAddresses.toTypedArray()).get()
                    node.network.connect(relay.peerId, *relay.dialAddresses.toTypedArray()).get(10, TimeUnit.SECONDS)
                    log.i {
                        "relay_bootstrap_connected peer=${relay.peerId.toBase58()} addrs=${relay.dialAddresses.size}"
                    }
                } catch (e: Exception) {
                    log.w(e) { "relay_bootstrap_failed peer=${relay.peerId.toBase58()}" }
                }
            }
        }
    }

    private fun startAutoNatMonitor() {
        autoNatJob?.cancel()

        if (bootstrapRelays.isEmpty()) {
            return
        }

        autoNatJob = scope.launch {
            while (isActive && host != null) {
                probeAutoNatStatus()
                delay(AUTONAT_POLL_INTERVAL_MILLIS.milliseconds)
            }
        }
    }

    private suspend fun probeAutoNatStatus() {
        val node = host ?: return
        val binding = autoNatBinding ?: return
        val directAddresses = currentListenMultiaddrs(node, includeRelay = false)
            .filterNot { it.has(Protocol.P2PCIRCUIT) }
            .map { if (it.getPeerId() == null) it.withP2P(node.peerId) else it }

        if (directAddresses.isEmpty()) {
            updateNatStatus(NatReachability.UNKNOWN, null, null, "no direct listen addresses")
            return
        }

        for (relay in bootstrapRelays) {
            try {
                val controller = binding.dial(node, relay.peerId, *relay.dialAddresses.toTypedArray()).controller.await()
                val response = controller.requestDial(node.peerId, directAddresses).await()
                val observedAddress = if (response.hasAddr()) {
                    Multiaddr.deserialize(response.addr.toByteArray())
                } else {
                    null
                }
                val status = when (response.status) {
                    Autonat.Message.ResponseStatus.OK -> NatReachability.PUBLIC
                    Autonat.Message.ResponseStatus.E_DIAL_ERROR,
                    Autonat.Message.ResponseStatus.E_DIAL_REFUSED -> NatReachability.PRIVATE
                    else -> NatReachability.UNKNOWN
                }
                updateNatStatus(status, observedAddress, relay.peerId.toBase58(), response.statusText.takeIf { response.hasStatusText() })
                return
            } catch (e: Exception) {
                log.w(e) { "autonat_probe_failed peer=${relay.peerId.toBase58()}" }
            }
        }

        updateNatStatus(NatReachability.UNKNOWN, null, null, "all bootstrap relays failed")
    }

    private fun updateNatStatus(
        newStatus: NatReachability,
        observedAddress: Multiaddr?,
        viaPeerId: String?,
        detail: String?
    ) {
        val normalizedObserved = observedAddress?.let {
            if (it.getPeerId() == null) it else stripTrailingPeerId(it)
        }
        val changed = natReachability != newStatus || observedPublicAddress?.toString() != normalizedObserved?.toString()
        natReachability = newStatus
        observedPublicAddress = if (newStatus == NatReachability.PUBLIC) normalizedObserved else null

        if (changed) {
            log.i {
                "autonat_status status=$newStatus observed=${this.observedPublicAddress?.toString() ?: "-"} via=${viaPeerId ?: "-"} detail=${detail ?: "-"}"
            }
            syncDiscoveryRegistrationIfNeeded()
        }
    }

    private fun prioritizeDialAddresses(node: Host, addresses: List<Multiaddr>): List<Multiaddr> {
        return addresses.distinctBy(Multiaddr::toString)
            .filter { supportsDialAddress(node, it) }
            .sortedWith(compareBy<Multiaddr> { dialPriority(it) }.thenBy { it.toString() })
    }

    private fun supportsDialAddress(node: Host, address: Multiaddr): Boolean {
        return node.network.transports.any { transport ->
            runCatching { transport.handles(address) }.getOrDefault(false)
        }
    }

    private fun dialPriority(address: Multiaddr): Int {
        return when {
            address.has(Protocol.P2PCIRCUIT) -> 2
            isLanAddress(address) -> 0
            else -> 1
        }
    }

    private fun isLanAddress(address: Multiaddr): Boolean {
        if (address.hasAny(Protocol.DNS, Protocol.DNS4, Protocol.DNS6, Protocol.DNSADDR)) {
            return false
        }

        val ip = address.getFirstComponent(Protocol.IP4)?.stringValue ?: address.getFirstComponent(Protocol.IP6)?.stringValue
        if (ip.isNullOrBlank()) {
            return false
        }

        return runCatching {
            val inetAddress = InetAddress.getByName(ip)
            inetAddress.isSiteLocalAddress || inetAddress.isLinkLocalAddress || inetAddress.isLoopbackAddress
        }.getOrDefault(false)
    }

    private fun loadBootstrapRelays(): List<BootstrapRelay> {
        val configuredRelays = sequenceOf(
            System.getProperty("sharething.bootstrapRelays"),
            System.getenv("SHARETHING_BOOTSTRAP_RELAYS")
        ).filterNotNull().flatMap { raw ->
            raw.split(',', ';', '\n').asSequence().map(String::trim).filter(String::isNotBlank)
        }

        return (DEFAULT_BOOTSTRAP_RELAYS.asSequence() + configuredRelays)
            .mapNotNull(::parseBootstrapRelay)
            .groupBy(BootstrapRelayEndpoint::peerId)
            .values
            .map { entries ->
                BootstrapRelay(
                    peerId = entries.first().peerId,
                    dialAddresses = entries.flatMap { it.dialAddresses }.distinctBy(Multiaddr::toString)
                )
            }
    }

    private fun parseBootstrapRelay(raw: String): BootstrapRelayEndpoint? {
        return try {
            val address = Multiaddr(raw)
            val peerId = address.getPeerId()
            if (peerId == null) {
                log.w { "relay_bootstrap_invalid missing_peer_id=$raw" }
                null
            } else if (address.has(Protocol.P2PCIRCUIT)) {
                log.w { "relay_bootstrap_invalid nested_relay=$raw" }
                null
            } else {
                BootstrapRelayEndpoint(
                    peerId = peerId,
                    dialAddresses = listOf(stripTrailingPeerId(address))
                )
            }
        } catch (e: Exception) {
            log.w(e) { "relay_bootstrap_invalid value=$raw" }
            null
        }
    }

    private fun stripTrailingPeerId(address: Multiaddr): Multiaddr {
        val components = address.components
        val lastProtocol = components.lastOrNull()?.protocol
        return if (lastProtocol == Protocol.P2P || lastProtocol == Protocol.IPFS) {
            Multiaddr(components.dropLast(1))
        } else {
            address
        }
    }

    private fun upsertKnownPeer(source: String, peerId: String, nickname: String, addresses: List<String>) {
        val normalizedAddresses = mergePeerAddresses(knownPeers[peerId]?.addresses.orEmpty(), addresses)
        val now = System.currentTimeMillis()
        val previous = knownPeers[peerId]

        if (previous == null) {
            val discovered = KnownPeer(
                peerId = peerId,
                nickname = nickname,
                addresses = normalizedAddresses,
                lastSeenMillis = now
            )
            knownPeers[peerId] = discovered
            log.i {
                "peer_discovered source=$source peer=${discovered.peerId} nick=${discovered.nickname} addrs=${discovered.addresses.size}"
            }
            CommandDispatcher.emit(
                EngineEvent.PeerDiscovered(
                    peerId = discovered.peerId,
                    nickname = discovered.nickname,
                    addresses = discovered.addresses
                )
            )
            return
        }

        previous.lastSeenMillis = now

        if (previous.nickname != nickname) {
            log.i {
                "peer_nick_changed source=$source peer=$peerId newNick=$nickname"
            }
            CommandDispatcher.emit(
                EngineEvent.PeerNicknameChanged(
                    peerId = peerId,
                    newNickname = nickname
                )
            )
        }

        if (previous.nickname != nickname || previous.addresses != normalizedAddresses) {
            val updated = previous.copy(nickname = nickname, addresses = normalizedAddresses, lastSeenMillis = now)
            knownPeers[peerId] = updated
            log.d {
                "peer_addresses_changed source=$source peer=${updated.peerId} addrs=${updated.addresses.size}"
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

    private fun mergePeerAddresses(existing: List<String>, incoming: List<String>): List<String> {
        return linkedSetOf<String>().apply {
            addAll(existing)
            addAll(incoming)
        }.sortedWith(compareBy<String>({ address ->
            runCatching { dialPriority(Multiaddr(address)) }.getOrDefault(Int.MAX_VALUE)
        }, { it }))
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
        log.d {
            "transfer_update id=$transferId direction=$direction status=$status " + "bytes=$bytesTransferred/$totalBytes speedBps=$speedBps " + "peer=${peerId ?: "unknown"} file=${filename ?: "unknown"} message=${message ?: "-"}"
        }

        if (status == "COMPLETED" || status == "FAILED") {
            val dedupKey = "$transferId:$direction:$status"
            if (transferNotificationDedup.putIfAbsent(dedupKey, true) == null) {
                notifyTransferTerminal(
                    direction = direction, status = status, peerId = peerId, filename = filename, message = message
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
        direction: String, status: String, peerId: String?, filename: String?, message: String?
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
        title: String, text: String, level: DesktopNotificationLevel
    ) {
        try {
            val notify = Notify.create().title(title).text(text)

            when (level) {
                DesktopNotificationLevel.INFO -> notify.showInformation()
                DesktopNotificationLevel.ERROR -> notify.showError()
            }
        } catch (t: Throwable) {
            log.w(t) { "desktop_notification_failed title=$title text=$text" }
        }
    }

    private fun logControl(control: FileTransferControl, scope: String) {
        when (control) {
            is FileTransferControl.Offer -> log.d {
                "control[$scope] OFFER id=${control.transferId} peer=${control.peerId} " + "file=${control.filename} bytes=${control.totalBytes}"
            }

            is FileTransferControl.Response -> log.d {
                "control[$scope] RESPONSE id=${control.transferId} accepted=${control.accepted} " + "msg=${control.message ?: "-"}"
            }

            is FileTransferControl.Completion -> log.d {
                "control[$scope] COMPLETION id=${control.transferId} completed=${control.completed} " + "msg=${control.message ?: "-"}"
            }
        }
    }

    private fun createFileTransferBinding(): ProtocolBinding<FileTransferMessageHandler> {
        return ProtocolBinding.createSimple(FILE_PROTOCOL_ID) { ch ->
            val stream = ch as Stream
            val handler = FileTransferMessageHandler()
            stream.pushHandler(ProtocolMessageHandlerAdapter(stream, handler))
            CompletableFuture.completedFuture(handler)
        }
    }

    inner class FileTransferMessageHandler : ProtocolMessageHandler<ByteBuf> {
        private var outboundTransfer: OutgoingTransfer? = null
        private val transferJson = Json { ignoreUnknownKeys = true }
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

        private lateinit var stream: Stream
        private var nettyChannel: io.netty.channel.Channel? = null

        private val diskWriteChannel = Channel<ByteArray>(Channel.UNLIMITED)

        override fun onActivated(stream: Stream) {
            this.stream = stream
            stream.pushHandler(object : ChannelInboundHandlerAdapter() {
                override fun handlerAdded(ctx: ChannelHandlerContext) {
                    nettyChannel = ctx.channel()
                }
            })
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
                        transferId = transferId, completed = false, message = cause?.message ?: "Stream error"
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
            val partFile = File("$savePath.part")
            destination.parentFile?.mkdirs()
            partFile.parentFile?.mkdirs()
            if (partFile.exists() && !partFile.delete()) {
                log.w { "data_accept could_not_delete_existing_part_file path=${partFile.path}" }
            }

            transferStartMillis = System.currentTimeMillis()
            receivedFileBytes = 0L
            bytesTransferred = 0L
            state = StreamState.RECEIVING_FILE

            scope.launch(Dispatchers.IO) {
                try {
                    FileOutputStream(partFile).use { output ->
                        val fileLock = output.channel.tryLock()
                            ?: throw IOException("Failed to acquire file lock for ${partFile.path}")
                        try {
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
                            output.flush()
                            output.fd.sync()
                        } finally {
                            fileLock.release()
                        }
                    }

                    if (bytesTransferred != totalBytes) {
                        throw IOException("Byte count mismatch: $bytesTransferred/$totalBytes")
                    }

                    try {
                        Files.move(
                            partFile.toPath(),
                            destination.toPath(),
                            StandardCopyOption.ATOMIC_MOVE,
                            StandardCopyOption.REPLACE_EXISTING
                        )
                    } catch (_: Exception) {
                        Files.move(
                            partFile.toPath(), destination.toPath(), StandardCopyOption.REPLACE_EXISTING
                        )
                    }

                    log.i { "data_commit_success id=$transferId path=${destination.path}" }
                    emitTransferUpdate(
                        transferId = transferId,
                        direction = "INCOMING",
                        bytesTransferred = bytesTransferred,
                        totalBytes = totalBytes,
                        speedBps = calculateSpeed(bytesTransferred, transferStartMillis),
                        status = "COMPLETED",
                        peerId = remotePeerId,
                        filename = fileName
                    )
                    incomingTransfers.remove(transferId)
                    if (sendCompletion(completed = true)) {
                        delay(50.milliseconds)
                    }
                    stream.close()
                } catch (e: Exception) {
                    log.e(e) { "data_write_failed id=$transferId partPath=${partFile.path}" }
                    if (partFile.exists() && !partFile.delete()) {
                        log.w { "data_write_failed could_not_delete_part_file path=${partFile.path}" }
                    }
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
                            peerId = remotePeerId, fileName = fileName, totalBytes = totalBytes
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
            completed: Boolean, message: String? = null
        ): Boolean {
            if (completionSent || streamClosed) return false
            completionSent = true
            writeControl(
                FileTransferControl.Completion(
                    transferId = transferId, completed = completed, message = message
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
        INFO, ERROR
    }

    private enum class NatReachability {
        UNKNOWN, PRIVATE, PUBLIC
    }

    private enum class StreamState {
        READING_CONTROL, WAITING_FOR_RESPONSE, SENDING_FILE, WAITING_FOR_COMPLETION, RECEIVING_FILE, CLOSED
    }

    private data class BootstrapRelayEndpoint(
        val peerId: PeerId,
        val dialAddresses: List<Multiaddr>
    )

    private data class BootstrapRelay(
        val peerId: PeerId,
        val dialAddresses: List<Multiaddr>
    ) {
        fun toCandidateRelay(): RelayTransport.CandidateRelay {
            return RelayTransport.CandidateRelay(peerId, dialAddresses)
        }
    }

    private companion object {
        private val NoRelayManager = object : CircuitHopProtocol.RelayManager {
            override fun hasReservation(peerId: PeerId): Boolean = false

            override fun createReservation(peerId: PeerId, observedAddress: Multiaddr): Optional<CircuitHopProtocol.Reservation> {
                return Optional.empty()
            }

            override fun allowConnection(source: PeerId, destination: PeerId): Optional<CircuitHopProtocol.Reservation> {
                return Optional.empty()
            }
        }

        const val DEFAULT_PORT = 4101
        const val FILE_PROTOCOL_ID = "/sharething/files/1.0.0"
        const val FILE_CHUNK_SIZE = 64 * 1024
        const val TRANSFER_COMPLETION_TIMEOUT_MILLIS = 15_000L
        const val MAX_CONTROL_FRAME_BYTES = 1 * 1024 * 1024
        const val AUTONAT_POLL_INTERVAL_MILLIS = 30_000L
        const val RELAY_ADDRESS_TTL_MILLIS = 10 * 60 * 1000L
        const val DEFAULT_RELAY_RESERVATIONS = 1
        val DEFAULT_BOOTSTRAP_RELAYS: List<String> = emptyList()
    }
}
