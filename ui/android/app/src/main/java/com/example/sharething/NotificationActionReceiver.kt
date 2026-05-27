package com.example.sharething

import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import p2p.P2p
import java.io.File

class NotificationActionReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION_ACCEPT = "com.example.sharething.ACCEPT_FILE"
        const val ACTION_REJECT = "com.example.sharething.REJECT_FILE"
        const val EXTRA_TRANSFER_ID = "transferId"
        const val EXTRA_FILE_NAME = "fileName"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val transferId = intent.getStringExtra(EXTRA_TRANSFER_ID) ?: return
        val notifId = transferId.hashCode()

        when (intent.action) {
            ACTION_ACCEPT -> {
                val fileName = intent.getStringExtra(EXTRA_FILE_NAME) ?: "received_file"
                val savePath = resolveSavePath(fileName)
                EngineService.backgroundSavePaths[transferId] = savePath
                Thread {
                    try {
                        P2p.acceptFile(transferId, savePath)
                    } catch (e: Exception) {
                        Log.e("ShareThing", "acceptFile failed: ${e.message}")
                    }
                }.start()
                dismiss(context, notifId)
            }
            ACTION_REJECT -> {
                Thread {
                    try {
                        P2p.rejectFile(transferId)
                    } catch (e: Exception) {
                        Log.e("ShareThing", "rejectFile failed: ${e.message}")
                    }
                }.start()
                dismiss(context, notifId)
            }
        }
    }

    private fun resolveSavePath(fileName: String): String {
        val dir = File("/storage/emulated/0/Download")
        dir.mkdirs()
        val target = File(dir, fileName)
        if (!target.exists()) return target.absolutePath
        val dot = fileName.lastIndexOf('.')
        val base = if (dot >= 0) fileName.substring(0, dot) else fileName
        val ext = if (dot >= 0) fileName.substring(dot) else ""
        var n = 1
        while (true) {
            val candidate = File(dir, "$base ($n)$ext")
            if (!candidate.exists()) return candidate.absolutePath
            n++
        }
    }

    private fun dismiss(context: Context, id: Int) {
        (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(id)
    }
}
