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
import java.util.concurrent.ConcurrentHashMap

class EngineService : Service() {

    companion object {
        val backgroundSavePaths = ConcurrentHashMap<String, String>()
    }

    private var multicastLock: WifiManager.MulticastLock? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        createNotificationChannels()
        startForeground(1, buildForegroundNotification())

        val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        multicastLock = wm?.createMulticastLock("sharething_lan")?.apply {
            setReferenceCounted(false)
            acquire()
        }

        val nickname = intent?.getStringExtra("nickname") ?: ""
        val discoveryServers = intent?.getStringExtra("discoveryServers") ?: ""
        val relayAddrs = intent?.getStringExtra("relayAddrs") ?: ""

        P2p.setDataDir(filesDir.absolutePath)

        P2p.setEventListener(object : p2p.EventListener {
            override fun onEvent(eventJson: String) {
                try {
                    val json = JSONObject(eventJson)
                    if (json.optString("type") == "NODE_STARTED") return
                    handleTransferEvent(json)
                    MainActivity.emitEvent(jsonObjectToMap(json))
                } catch (_: Exception) {}
            }
        })

        Thread {
            try {
                val deviceIP = detectDeviceIP()
                P2p.start(nickname, discoveryServers, relayAddrs, deviceIP)

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

    private fun handleTransferEvent(json: JSONObject) {
        val nm = getSystemService(NotificationManager::class.java)
        when (json.optString("type")) {
            "INCOMING_FILE_REQUEST" -> {
                val transferId = json.optString("transferId").ifEmpty { return }
                val fileName = json.optString("filename").ifEmpty { return }
                val totalBytes = json.optLong("totalBytes", 0L)
                postIncomingFileNotification(nm, transferId, fileName, totalBytes)
            }
            "TRANSFER_UPDATE" -> {
                val status = json.optString("status")
                val direction = json.optString("direction")
                val transferId = json.optString("transferId").ifEmpty { return }
                val fileName = json.optString("filename")
                when (status) {
                    "COMPLETED" -> {
                        nm.cancel(transferId.hashCode())
                        val savedPath = backgroundSavePaths.remove(transferId)
                        if (savedPath != null) {
                            json.put("localPath", savedPath)
                        }
                        if (direction == "INCOMING") {
                            postTransferCompletedNotification(nm, transferId, fileName)
                        }
                    }
                    "FAILED" -> nm.cancel(transferId.hashCode())
                }
            }
        }
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

    private fun createNotificationChannels() {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel("engine_channel", "Engine Service", NotificationManager.IMPORTANCE_LOW)
        )
        nm.createNotificationChannel(
            NotificationChannel("transfer_channel", "File Transfers", NotificationManager.IMPORTANCE_HIGH)
        )
    }

    private fun buildForegroundNotification(): Notification {
        val openPi = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).apply { addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP) },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return Notification.Builder(this, "engine_channel")
            .setContentTitle("ShareThing running")
            .setContentText("P2P node active")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentIntent(openPi)
            .setOngoing(true)
            .build()
    }

    private fun postIncomingFileNotification(
        nm: NotificationManager,
        transferId: String,
        fileName: String,
        totalBytes: Long
    ) {
        val notifId = transferId.hashCode()

        val openPi = PendingIntent.getActivity(
            this, notifId,
            Intent(this, MainActivity::class.java).apply { addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP) },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val acceptPi = PendingIntent.getBroadcast(
            this, notifId,
            Intent(this, NotificationActionReceiver::class.java).apply {
                action = NotificationActionReceiver.ACTION_ACCEPT
                putExtra(NotificationActionReceiver.EXTRA_TRANSFER_ID, transferId)
                putExtra(NotificationActionReceiver.EXTRA_FILE_NAME, fileName)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val rejectPi = PendingIntent.getBroadcast(
            this, notifId xor Int.MIN_VALUE,
            Intent(this, NotificationActionReceiver::class.java).apply {
                action = NotificationActionReceiver.ACTION_REJECT
                putExtra(NotificationActionReceiver.EXTRA_TRANSFER_ID, transferId)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        @Suppress("DEPRECATION")
        val notification = Notification.Builder(this, "transfer_channel")
            .setContentTitle("Incoming file: $fileName")
            .setContentText(formatBytes(totalBytes))
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentIntent(openPi)
            .setAutoCancel(false)
            .addAction(Notification.Action.Builder(0, "Accept", acceptPi).build())
            .addAction(Notification.Action.Builder(0, "Reject", rejectPi).build())
            .build()

        nm.notify(notifId, notification)
    }

    private fun postTransferCompletedNotification(
        nm: NotificationManager,
        transferId: String,
        fileName: String
    ) {
        val notifId = "done_$transferId".hashCode()

        val openPi = PendingIntent.getActivity(
            this, notifId,
            Intent(this, MainActivity::class.java).apply { addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP) },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = Notification.Builder(this, "transfer_channel")
            .setContentTitle("Transfer complete")
            .setContentText(fileName)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentIntent(openPi)
            .setAutoCancel(true)
            .build()

        nm.notify(notifId, notification)
    }

    private fun formatBytes(bytes: Long): String {
        if (bytes <= 0) return "0 B"
        if (bytes < 1024) return "$bytes B"
        if (bytes < 1024 * 1024) return "%.1f KB".format(bytes / 1024.0)
        if (bytes < 1024L * 1024 * 1024) return "%.1f MB".format(bytes / (1024.0 * 1024))
        return "%.2f GB".format(bytes / (1024.0 * 1024 * 1024))
    }
}
