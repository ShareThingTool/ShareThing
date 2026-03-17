import 'package:flutter/material.dart';
import 'dart:ui';
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
String _nodeId = "Unknown";
String _port = "0";

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ShareThing P2P')),
      body: StreamBuilder<Map<String, dynamic>>(
        stream: widget.engine.updates,
        builder: (context, snapshot) {
          final bool isRunning = widget.engine.isAlive;
          
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
                ]
              ],
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          if (widget.engine.isAlive) {
      widget.engine.stop();
      setState(() { _nodeId = "Unknown"; });
    	} else {
      await widget.engine.start();

      try {
 	await widget.engine.updates
            .firstWhere((msg) => msg['type'] == 'event' && msg['data'] == 'ready')
            .timeout(const Duration(seconds: 5));

        await widget.engine.sendCommand('start_node', {'port': 4001});
        final response = await widget.engine.sendCommand('get_id');
	final port = await widget.engine.sendCommand('get_port');
        setState(() {
          _nodeId = response['data'] ?? "Error";
	  _port = port['data'] ?? "0";
        });
      } catch (e) {
        print("Command failed: $e");
      }
    }
    setState(() {});
        },
        label: Text(widget.engine.isAlive ? "Stop Engine" : "Start Engine"),
        icon: Icon(widget.engine.isAlive ? Icons.stop : Icons.play_arrow),
      ),
    );
  }
}
