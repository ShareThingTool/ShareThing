import 'package:flutter/material.dart';
import 'dart:ui';
import 'dart:io';
import 'core/engine_manager.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ShareThingApp());
}

class ShareThingApp extends StatefulWidget {
  const ShareThingApp({super.key});

  @override
  State<ShareThingApp> createState() => _ShareThingAppState();
}

class _ShareThingAppState extends State<ShareThingApp> {
  final EngineManager _engineManager = EngineManager();
  late final AppLifecycleListener _lifecycleListener;

  @override
  void initState() {
    super.initState();
    _startEngine();

    _lifecycleListener = AppLifecycleListener(
      onExitRequested: () async {
        _engineManager.stop();
        return AppExitResponse.exit;
      },
    );
  }

  Future<void> _startEngine() async {
    await _engineManager.start();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    _engineManager.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ShareThing',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey),
        useMaterial3: true,
      ),
      home: MyHomePage(engine: _engineManager),
    );
  }
}
class MyHomePage extends StatefulWidget {
  final EngineManager engine;
  const MyHomePage({super.key, required this.engine});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  bool _running = false;
  String _nodeId = "Unknown";
  String _port = "0";
  final TextEditingController _peerController = TextEditingController();
  String _localIp = "Unknown";

  @override
  void initState() {
    super.initState();

    widget.engine.updates.listen((event) {
      if (!mounted) return;

      if (event['type'] == 'event') {
        if (event['event'] == 'node_started') {
          setState(() {
            _running = true;
          });
        }

        if (event['event'] == 'node_stopped') {
          setState(() {
            _running = false;
          });
        }

        if (event['event'] == 'file_received') {
          final name = event['filename'] ?? "unknown";
          print("File received: $name");

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Received file: $name")),
          );
        }
      }
    });

    _init();
    _loadLocalIp();
  }
  Future<void> _loadLocalIp() async {
    try {
      for (var interface in await NetworkInterface.list()) {
        for (var addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            setState(() {
              _localIp = addr.address;
            });
            return;
          }
        }
      }
    } catch (e) {
      print("IP error: $e");
    }
  }

  Future<void> _init() async {
    try {
      await widget.engine.start();

      final id = await widget.engine.sendCommand('get_id');
      final port = await widget.engine.sendCommand('get_port');

      setState(() {
        _nodeId = id['data'];
        _port = port['data'].toString();
      });
    } catch (e) {
      print("ERROR: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ShareThing P2P')),
      body: StreamBuilder<Map<String, dynamic>>(
        stream: widget.engine.updates,
        builder: (context, snapshot) {
          final bool isRunning = _running;

          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  isRunning ? Icons.dns : Icons.portable_wifi_off,
                  size: 64,
                  color: isRunning ? Colors.green : Colors.red,
                ),
                const SizedBox(height: 20),
                Text(
                  isRunning ? "Node Online" : "Node Offline",
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                if (isRunning) ...[
                  const SizedBox(height: 10),
                  Text("Peer ID: $_nodeId"),
                  Text("Listening on Port $_port"),
                ],
                const SizedBox(height: 20),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: TextField(
                    controller: _peerController,
                    decoration: const InputDecoration(
                      labelText: "Peer address (e.g. 192.168.1.23:4001)",
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                ElevatedButton(
                  onPressed: () async {
                    final addr = _peerController.text.trim();
                    if (addr.isEmpty) return;

                    try {
                      final res = await widget.engine.sendCommand("connect", {
                        "multiaddr": addr,
                      });
                      print("Connect result: $res");
                    } catch (e) {
                      print("Connect failed: $e");
                    }
                  },
                  child: const Text("Connect"),
                ),
                ElevatedButton(
                  onPressed: () async {
                    final addr = _peerController.text.trim();
                    if (addr.isEmpty) return;

                    try {
                      final path = "/sdcard/Download/test.txt";
                      await widget.engine.sendFile(path, addr);
                      print("File sent");
                    } catch (e) {
                      print("Send failed: $e");
                    }
                  },
                  child: const Text("Send File"),
                ),
                const SizedBox(height: 10),
                Text("Your IP: $_localIp"),
              ],
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          try {
            if (_running) {
              await widget.engine.sendCommand("stop_node");

              setState(() {
                _nodeId = "Unknown";
                _running = false;
              });
            } else {
              await widget.engine.start();
              await widget.engine.sendCommand('start_node', {'port': 4001});

              final response = await widget.engine.sendCommand('get_id');
              final port = await widget.engine.sendCommand('get_port');

              setState(() {
                _running = true;
                _nodeId = response['data'] ?? "Error";
                _port = port['data']?.toString() ?? "0";
              });
            }
          } catch (e) {
            print("Engine toggle failed: $e");
          }
        },
        label: Text(_running ? "Stop Engine" : "Start Engine"),
        icon: Icon(_running ? Icons.stop : Icons.play_arrow),
      ),
    );
  }
}
