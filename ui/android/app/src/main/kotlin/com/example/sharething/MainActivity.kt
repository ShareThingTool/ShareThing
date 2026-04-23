package com.example.sharething

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    companion object {
        private var eventSink: EventChannel.EventSink? = null

        fun emitEvent(payload: Map<String, Any?>) {
            eventSink?.success(payload)
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

                val intent = Intent(this, EngineService::class.java).apply {
                    putExtra("nickname", json.optString("nickname"))
                    putExtra("discoveryServers", json.optJSONArray("discoveryServers")?.toString())
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

            "SEND_FILE",
            "ACCEPT_FILE",
            "REJECT_FILE" -> {
                result.error(
                    "UNSUPPORTED",
                    "${json.optString("type")} is not implemented in the Android bridge yet",
                    null
                )
            }

            else -> result.error("UNKNOWN_COMMAND", json.optString("type"), null)
        }
    }
}
