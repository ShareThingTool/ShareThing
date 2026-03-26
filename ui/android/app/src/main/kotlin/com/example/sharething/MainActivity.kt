package com.example.sharething

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {

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
                        startEngine()
                        started = true
                        result.success(mapOf(
                            "status" to "running",
                            "port" to 4001
                        ))
                    }

                    "command" -> {
                        val type = call.argument<String>("type")

                        if (type == null) {
                            result.error("INVALID_ARGUMENT", "type is null", null)
                            return@setMethodCallHandler
                        }

                        when (type) {
                            "ping" -> {
                                val res = sendToEngine("ping")
                                result.success(mapOf("response" to res))
                            }

                            "start_node" -> {
                                val port = call.argument<Int>("port") ?: 4001
                                val res = sendToEngine("start_node $port")
                                result.success(mapOf(
                                    "status" to res,
                                    "port" to port
                                ))
                            }

                            "get_id" -> {
                                val res = sendToEngine("get_id")
                                result.success(mapOf("data" to res))
                            }

                            "get_port" -> {
                                val res = sendToEngine("get_port")
                                result.success(mapOf("data" to res))
                            }

                            "connect" -> {
                                val addr = call.argument<String>("multiaddr")

                                if (addr == null) {
                                    result.error("INVALID_ARGUMENT", "multiaddr is null", null)
                                    return@setMethodCallHandler
                                }

                                val res = sendToEngine("connect $addr")
                                result.success(mapOf("status" to res, "addr" to addr))
                            }

                            else -> {
                                result.success(mapOf("error" to "unknown_command", "type" to type))
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun startEngine() {
        val intent = Intent(this, EngineService::class.java)
        startForegroundService(intent)
        println("Engine service started")
    }

    private fun sendToEngine(message: String): String {
        return try {
            val socket = java.net.Socket("127.0.0.1", 4001)
            val writer = socket.getOutputStream().bufferedWriter()
            val reader = socket.getInputStream().bufferedReader()

            writer.write(message + "\n")
            writer.flush()

            val response = reader.readLine()
            socket.close()

            response ?: "no_response"
        } catch (e: Exception) {
            e.printStackTrace()
            "error"
        }
    }
}