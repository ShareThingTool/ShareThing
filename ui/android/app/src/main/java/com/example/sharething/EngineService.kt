package com.example.sharething

import android.app.*
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import p2p.P2p
import java.net.Inet4Address
import java.net.NetworkInterface

class EngineService : Service() {

    private var multicastLock: WifiManager.MulticastLock? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForegroundNotification()
        val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        multicastLock = wm?.createMulticastLock("sharething_lan")?.apply {
            setReferenceCounted(false)
            acquire()
        }

        val nickname = intent?.getStringExtra("nickname") ?: ""
        val discoveryServers = intent?.getStringExtra("discoveryServers") ?: ""
        val relayAddrs = intent?.getStringExtra("relayAddrs") ?: ""

        P2p.setDataDir(filesDir.absolutePath)

        // Forward all Go events (peer discovery, file transfers, etc.) to Flutter.
        // NODE_STARTED is emitted from Kotlin below, after start() returns, to
        // avoid any race with the event listener setup.
        P2p.setEventListener(object : p2p.EventListener {
            override fun onEvent(eventJson: String) {
                try {
                    val json = JSONObject(eventJson)
                    if (json.optString("type") == "NODE_STARTED") return
                    MainActivity.emitEvent(jsonObjectToMap(json))
                } catch (_: Exception) {}
            }
        })

        Thread {
            try {
                val deviceIP = detectDeviceIP()
                P2p.start(nickname, discoveryServers, relayAddrs, deviceIP)

                // Emit NODE_STARTED from Kotlin once start() returns successfully.
                val peerId = P2p.getId()
                val multiaddr = P2p.getMultiaddr()
                val addrs = if (multiaddr.isNotEmpty()) listOf(multiaddr) else emptyList()
                MainActivity.emitEvent(
                    mapOf("type" to "NODE_STARTED", "peerId" to peerId, "listenAddresses" to addrs)
                )
            } catch (e: Exception) {
                e.printStackTrace()
                MainActivity.emitEvent(
                    mapOf("type" to "ERROR", "message" to (e.message ?: "node failed to start"))
                )
            }
        }.start()

        return START_NOT_STICKY
    }

    override fun onDestroy() {
        super.onDestroy()
        multicastLock?.release()
        multicastLock = null
        P2p.stop()
        P2p.setEventListener(null)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun jsonObjectToMap(json: JSONObject): Map<String, Any?> =
        json.keys().asSequence().associateWith { key -> jsonValue(json.get(key)) }

    private fun jsonValue(value: Any?): Any? = when (value) {
        is JSONObject -> jsonObjectToMap(value)
        is JSONArray -> (0 until value.length()).map { jsonValue(value.get(it)) }
        else -> value
    }

    private fun detectDeviceIP(): String {
        // 1. ConnectivityManager — preferred on Android M+, needs ACCESS_NETWORK_STATE
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                val lp = cm?.getLinkProperties(cm.activeNetwork)
                val ip = lp?.linkAddresses
                    ?.map { it.address }
                    ?.filterIsInstance<Inet4Address>()
                    ?.firstOrNull { !it.isLoopbackAddress && !it.isLinkLocalAddress }
                    ?.hostAddress
                Log.d("ShareThing", "detectDeviceIP ConnectivityManager=$ip")
                if (!ip.isNullOrEmpty()) return ip
            }
        } catch (e: Exception) { Log.d("ShareThing", "detectDeviceIP ConnectivityManager exception: $e") }

        // 2. WifiManager — needs ACCESS_WIFI_STATE
        try {
            @Suppress("DEPRECATION")
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            val ipInt = wm?.dhcpInfo?.ipAddress ?: 0
            if (ipInt != 0) {
                val ip = String.format("%d.%d.%d.%d",
                    ipInt and 0xff, (ipInt shr 8) and 0xff,
                    (ipInt shr 16) and 0xff, (ipInt shr 24) and 0xff)
                Log.d("ShareThing", "detectDeviceIP WifiManager=$ip")
                return ip
            }
        } catch (e: Exception) { Log.d("ShareThing", "detectDeviceIP WifiManager exception: $e") }

        // 3. NetworkInterface — last resort
        return try {
            val ip = NetworkInterface.getNetworkInterfaces()
                ?.toList()
                ?.flatMap { it.inetAddresses.toList() }
                ?.filterIsInstance<Inet4Address>()
                ?.firstOrNull { !it.isLoopbackAddress && !it.isLinkLocalAddress }
                ?.hostAddress ?: ""
            Log.d("ShareThing", "detectDeviceIP NetworkInterface=$ip")
            ip
        } catch (e: Exception) {
            Log.d("ShareThing", "detectDeviceIP NetworkInterface exception: $e")
            ""
        }
    }

    private fun startForegroundNotification() {
        val channelId = "engine_channel"
        val channel = NotificationChannel(channelId, "Engine Service", NotificationManager.IMPORTANCE_LOW)
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        val notification = Notification.Builder(this, channelId)
            .setContentTitle("ShareThing running")
            .setContentText("P2P node active")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .build()
        startForeground(1, notification)
    }
}
