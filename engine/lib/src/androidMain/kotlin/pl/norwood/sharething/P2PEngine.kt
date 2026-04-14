package pl.norwood.sharething

actual class P2PEngine actual constructor() {
    private var port: Int = 0

    actual fun startNode(port: Int): String {
        this.port = port
        return "Android engine is provided by the Go bridge in the Flutter app."
    }

    actual fun getPeerId(): String = "Android engine is managed by the Flutter bridge."

    actual fun getPort(): String = port.toString()

    actual fun getListenAddress(): String = "Android engine is managed by the Flutter bridge."

    actual fun connect(multiaddr: String): String =
        "Android engine is managed by the Flutter bridge."

    actual fun stopNode(): String = "Stopped"
}
