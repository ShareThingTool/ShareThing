package com.example.sharething

import android.app.*
import android.content.Intent
import android.os.IBinder
import org.json.JSONObject

class EngineService : Service() {

    override fun onCreate() {
        super.onCreate()
        startForegroundService()
        startEngine()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun startForegroundService() {
        val channelId = "engine_channel"

        val channel = NotificationChannel(
            channelId,
            "Engine Service",
            NotificationManager.IMPORTANCE_LOW
        )

        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(channel)

        val notification = Notification.Builder(this, channelId)
            .setContentTitle("ShareThing running")
            .setContentText("P2P node active")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .build()

        startForeground(1, notification)
    }

    private fun startEngine() {
        Thread {
            try {
                val server = java.net.ServerSocket(4001)
                println("Engine server running on port 4001")

                while (true) {
                    val client = server.accept()
                    val input = client.getInputStream().bufferedReader()
                    val output = client.getOutputStream().bufferedWriter()

                    val line = input.readLine()
                    if (line == null) {
                        client.close()
                        continue
                    }
                    val json = JSONObject(line.trim())
                    val type = json.optString("type")
                    println("Received JSON: $json")

                    val responseJson = JSONObject()

                    when (type) {
                        "ping" -> {
                            responseJson.put("response", "pong")
                        }

                        "start_node" -> {
                            val port = json.optInt("port", 4001)
                            println("Starting node on $port")
                            responseJson.put("status", "started")
                            responseJson.put("port", port)
                        }

                        "get_id" -> {
                            responseJson.put("data", "peer_${System.currentTimeMillis()}")
                        }

                        "get_port" -> {
                            responseJson.put("data", 4001)
                        }

                        "connect" -> {
                            val addr = json.optString("multiaddr")

                            try {
                                val parts = addr.split(":")
                                val host = parts[0]
                                val port = parts[1].toInt()

                                Thread {
                                    try {
                                        val socket = java.net.Socket(host, port)
                                        println("Connected to $addr")

                                        val out = socket.getOutputStream().bufferedWriter()
                                        val input = socket.getInputStream().bufferedReader()

                                        out.write(json.toString() + "\n")
                                        out.flush()

                                        val response = input.readLine()
                                        println("Peer says: $response")

                                        socket.close()
                                    } catch (e: Exception) {
                                        println("Connection failed: ${e.message}")
                                    }
                                }.start()

                                responseJson.put("status", "connecting")
                                responseJson.put("addr", addr)

                            } catch (e: Exception) {
                                responseJson.put("error", "invalid_address")
                            }
                        }

                        else -> {
                            responseJson.put("error", "unknown_command")
                            responseJson.put("type", type)
                        }
                    }

                    output.write(responseJson.toString() + "\n")
                    output.flush()

                    val eventJson = JSONObject()

                    when (type) {
                        "start_node" -> {
                            eventJson.put("type", "event")
                            eventJson.put("event", "node_started")

                        }

                        "connect" -> {
                            eventJson.put("type", "event")
                            eventJson.put("event", "peer_connecting")
                            eventJson.put("addr", json.optString("multiaddr"))
                        }

                        "hello" -> {
                            responseJson.put("type", "hello")
                            responseJson.put("message", "hi from peer")
                        }

                        "send_file" -> {
                            val filename = json.optString("filename")
                            val data = json.optString("data")

                            println("Receiving file: $filename")

                            try {
                                val bytes = android.util.Base64.decode(data, android.util.Base64.DEFAULT)

                                val file = java.io.File(filesDir, filename)
                                file.writeBytes(bytes)

                                responseJson.put("status", "received")
                                responseJson.put("filename", filename)

                                val eventJson = JSONObject()
                                eventJson.put("type", "event")
                                eventJson.put("event", "file_received")
                                eventJson.put("filename", filename)

                                output.write(eventJson.toString() + "\n")
                                output.flush()

                            } catch (e: Exception) {
                                responseJson.put("error", "file_write_failed")
                            }
                        }
                    }

                    if (eventJson.length() > 0) {
                        output.write(eventJson.toString() + "\n")
                        output.flush()
                    }

                    input.close()
                    output.close()
                    client.close()
                }
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }.start()
    }
}