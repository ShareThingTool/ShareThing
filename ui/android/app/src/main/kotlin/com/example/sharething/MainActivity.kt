package com.example.sharething

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import p2p.P2p

class MainActivity : FlutterActivity() {

    private val CHANNEL = "engine"
    private var started = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {

                    "startEngine" -> {
                        if (started) {
                            result.success(mapOf("status" to "already_started"))
                            return@setMethodCallHandler
                        }
                        startForegroundService(Intent(this, EngineService::class.java))
                        started = true
                        result.success(mapOf("status" to "running"))
                    }

                    "command" -> {
                        val type = call.argument<String>("type")
                        if (type == null) {
                            result.error("INVALID_ARGUMENT", "type is null", null)
                            return@setMethodCallHandler
                        }

                        when (type) {

                            "ping" -> {
                                result.success(mapOf("response" to "pong"))
                            }

                            "get_id" -> {
                                Thread {
                                    var attempts = 0
                                    while (EngineService.peerId.isEmpty() && attempts < 20) {
                                        Thread.sleep(500)
                                        attempts++
                                    }
                                    result.success(mapOf("data" to EngineService.peerId))
                                }.start()
                            }

                            "get_port", "get_listen_address" -> {
                                Thread {
                                    var attempts = 0
                                    while (EngineService.multiaddr.isEmpty() && attempts < 20) {
                                        Thread.sleep(500)
                                        attempts++
                                    }
                                    result.success(mapOf("data" to EngineService.multiaddr))
                                }.start()
                            }

                            "connect" -> {
                                val addr = call.argument<String>("multiaddr")
                                if (addr == null) {
                                    result.error("INVALID_ARGUMENT", "multiaddr is null", null)
                                    return@setMethodCallHandler
                                }
                                Thread {
                                    try {
                                        P2p.connectToPeer(addr)
                                        result.success(mapOf("status" to "connected", "addr" to addr))
                                    } catch (e: Exception) {
                                        result.error("CONNECT_FAILED", e.message, null)
                                    }
                                }.start()
                            }

                            "send_message" -> {
                                val peerId  = call.argument<String>("peerId")!!
                                val message = call.argument<String>("message")!!
                                Thread {
                                    try {
                                        P2p.sendMessage(peerId, message)
                                        result.success(mapOf("status" to "sent"))
                                    } catch (e: Exception) {
                                        result.error("SEND_FAILED", e.message, null)
                                    }
                                }.start()
                            }

                            else -> result.success(mapOf("error" to "unknown_command"))
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }
}
