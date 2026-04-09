import p2pbridge.P2pbridge

actual class P2PEngine : IP2PEngine {
    private var node: p2pbridge.Node? = null

    actual fun start() {
        node = P2pbridge.startNode()
    }

    actual fun stop() {
        node?.stop()
    }

    actual fun getId(): String = node?.getId() ?: ""
}