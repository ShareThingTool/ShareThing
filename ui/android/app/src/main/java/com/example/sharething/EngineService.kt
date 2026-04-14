package com.example.sharething

import android.app.*
import android.content.Intent
import android.os.IBinder
import p2p.P2p

class EngineService : Service() {

    companion object {
        var multiaddr: String = ""
        var peerId: String = ""
    }

    override fun onCreate() {
        super.onCreate()
        println("EngineService onCreate fired")
        startForegroundNotification()

        Thread {
            try {
                val addr = P2p.start()
                multiaddr = addr
                peerId = addr.substringAfterLast("/")
                println("libp2p node started: $addr")
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }.start()
    }

    override fun onDestroy() {
        super.onDestroy()
        P2p.stop()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun startForegroundNotification() {
        val channelId = "engine_channel"
        val channel = NotificationChannel(
            channelId,
            "Engine Service",
            NotificationManager.IMPORTANCE_LOW
        )
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)

        val notification = Notification.Builder(this, channelId)
            .setContentTitle("ShareThing running")
            .setContentText("P2P node active")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .build()

        startForeground(1, notification)
    }
}
