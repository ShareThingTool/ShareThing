package com.example.sharething

import android.app.DownloadManager
import android.content.Intent
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import p2p.P2p

class MainActivity : FlutterActivity() {
    companion object {
        private var eventSink: EventChannel.EventSink? = null
        private val mainHandler = Handler(Looper.getMainLooper())

        fun emitEvent(payload: Map<String, Any?>) {
            mainHandler.post { eventSink?.success(payload) }
        }
    }

    private val commandChannel = "engine/commands"
    private val eventChannel = "engine/events"
    private var started = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, commandChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "commandJson" -> {
                        val payload = call.arguments as? String
                        if (payload == null) {
                            result.error("INVALID_ARGUMENT", "payload is null", null)
                            return@setMethodCallHandler
                        }
                        handleJsonCommand(payload, result)
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, eventChannel)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                    eventSink = sink
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })
    }

    private fun handleJsonCommand(
        payload: String,
        result: MethodChannel.Result
    ) {
        val json = try {
            JSONObject(payload)
        } catch (e: Exception) {
            result.error("INVALID_JSON", e.message, null)
            return
        }

        when (json.optString("type")) {
            "START_NODE" -> {
                if (started) {
                    result.success(null)
                    return
                }

                val nickname = json.optString("nickname")
                val discoveryServers = json.optJSONArray("discoveryServers")
                    ?.let { arr -> (0 until arr.length()).joinToString(";") { arr.getString(it) } }
                    ?: ""
                val relayAddrs = json.optJSONArray("relayAddrs")
                    ?.let { arr -> (0 until arr.length()).joinToString(";") { arr.getString(it) } }
                    ?: ""

                val intent = Intent(this, EngineService::class.java).apply {
                    putExtra("nickname", nickname)
                    putExtra("discoveryServers", discoveryServers)
                    putExtra("relayAddrs", relayAddrs)
                }
                startForegroundService(intent)
                started = true
                result.success(null)
            }

            "STOP_NODE" -> {
                stopService(Intent(this, EngineService::class.java))
                started = false
                result.success(null)
            }

            "SEND_FILE" -> {
                val targetPeerId = json.optString("targetPeerId")
                val filePath = json.optString("filePath")
                val addrsArray = json.optJSONArray("knownAddresses")
                val knownAddresses = if (addrsArray != null)
                    (0 until addrsArray.length()).joinToString(";") { addrsArray.getString(it) }
                else ""
                Thread {
                    try {
                        P2p.sendFile(targetPeerId, filePath, knownAddresses)
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("SEND_FILE_FAILED", e.message, null)
                    }
                }.start()
            }

            "ACCEPT_FILE" -> {
                val transferId = json.optString("transferId")
                val savePath = json.optString("savePath")
                Thread {
                    try {
                        P2p.acceptFile(transferId, savePath)
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("ACCEPT_FILE_FAILED", e.message, null)
                    }
                }.start()
            }

            "REJECT_FILE" -> {
                val transferId = json.optString("transferId")
                Thread {
                    try {
                        P2p.rejectFile(transferId)
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("REJECT_FILE_FAILED", e.message, null)
                    }
                }.start()
            }

            "OPEN_FILE_LOCATION" -> {
                try {
                    val intent = Intent(DownloadManager.ACTION_VIEW_DOWNLOADS).apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    startActivity(Intent.createChooser(intent, "Open with"))
                    result.success(null)
                } catch (e: Exception) {
                    result.error("OPEN_FAILED", e.message, null)
                }
            }

            else -> result.error("UNKNOWN_COMMAND", json.optString("type"), null)
        }
    }
}
