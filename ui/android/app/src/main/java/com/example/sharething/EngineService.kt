package com.example.sharething

import android.app.*
import android.content.Intent
import android.os.IBinder
import org.json.JSONObject
import p2p.P2p

class EngineService : Service() {

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForegroundNotification()

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
                    val map = mutableMapOf<String, Any?>()
                    for (key in json.keys()) map[key] = json.get(key)
                    MainActivity.emitEvent(map)
                } catch (_: Exception) {}
            }
        })

        Thread {
            try {
                P2p.start(nickname, discoveryServers, relayAddrs)

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
        P2p.stop()
        P2p.setEventListener(null)
    }

    override fun onBind(intent: Intent?): IBinder? = null

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
