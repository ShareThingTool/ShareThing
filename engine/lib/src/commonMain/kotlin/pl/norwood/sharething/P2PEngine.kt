package pl.norwood.sharething

expect class P2PEngine() {
    /**
     * Starts the libp2p node on the specified port.
     * Returns the PeerID or an error message.
     */
    fun startNode(port: Int): String

    /**
     * Returns the local PeerID in Base58 format.
     */
    fun getPeerId(): String

    /**
     * Returns the p2p port.
     */
    fun getPort(): String

    /**
     * Returns a shareable multiaddr for the running node when available.
     */
    fun getListenAddress(): String

    /**
     * Connects to another peer by multiaddr.
     */
    fun connect(multiaddr: String): String

    /**
     * Cleanly stops the node and releases resources.
     */
    fun stopNode(): String
}
