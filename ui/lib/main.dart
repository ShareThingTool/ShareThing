import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'core/engine_manager.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(ShareThingApp());
}

class ShareThingApp extends StatelessWidget {
  ShareThingApp({super.key, EngineManager? engine}) : engine = engine ?? EngineManager();

  final EngineManager engine;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ShareThing',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey),
        useMaterial3: true,
      ),
      home: MyHomePage(engine: engine),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.engine});

  final EngineManager engine;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final TextEditingController _peerController = TextEditingController();
  StreamSubscription<Map<String, dynamic>>? _engineSubscription;

  bool _running = false;
  bool _busy = true;
  String _nodeId = 'Unavailable';
  String _endpoint = 'Unavailable';
  String _localIp = 'Unavailable';
  String? _statusMessage = 'Starting engine...';
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _engineSubscription = widget.engine.updates.listen(_handleEngineEvent);
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    _engineSubscription?.cancel();
    _peerController.dispose();
    unawaited(widget.engine.stop());
    super.dispose();
  }

  Future<void> _bootstrap() async {
    unawaited(_loadLocalIp());
    await _startEngine();
  }

  Future<void> _loadLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list();
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (address.type == InternetAddressType.IPv4 && !address.isLoopback) {
            if (!mounted) return;
            setState(() {
              _localIp = address.address;
            });
            return;
          }
        }
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _localIp = 'Unavailable';
      });
    }
  }

  void _handleEngineEvent(Map<String, dynamic> event) {
    if (!mounted || event['type'] != 'event') return;

    switch (event['event']) {
      case 'node_started':
        setState(() {
          _running = true;
          _statusMessage = 'Engine online';
        });
        break;
      case 'node_stopped':
        setState(() {
          _running = false;
          _busy = false;
          _statusMessage = 'Engine stopped';
        });
        break;
      case 'file_received':
        final name = event['filename']?.toString() ?? 'unknown';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Received file: $name')),
        );
        break;
    }
  }

  Future<void> _startEngine() async {
    if (_busy && _running) return;

    setState(() {
      _busy = true;
      _errorMessage = null;
      _statusMessage = 'Starting engine...';
    });

    try {
      await widget.engine.start();
      final id = await widget.engine.sendCommand('get_id');
      final endpoint = await widget.engine.sendCommand('get_port');

      if (!mounted) return;
      setState(() {
        _running = true;
        _nodeId = id['data']?.toString() ?? 'Unavailable';
        _endpoint = endpoint['data']?.toString() ?? 'Unavailable';
        _statusMessage = 'Engine online';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _errorMessage = '$error';
        _statusMessage = 'Engine unavailable';
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _stopEngine() async {
    setState(() {
      _busy = true;
      _errorMessage = null;
      _statusMessage = 'Stopping engine...';
    });

    await widget.engine.stop();

    if (!mounted) return;
    setState(() {
      _busy = false;
      _running = false;
      _nodeId = 'Unavailable';
      _endpoint = 'Unavailable';
      _statusMessage = 'Engine stopped';
    });
  }

  Future<void> _connectToPeer() async {
    final address = _peerController.text.trim();
    if (address.isEmpty) return;

    setState(() {
      _busy = true;
      _errorMessage = null;
    });

    try {
      await widget.engine.sendCommand('connect', {'multiaddr': address});

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Connected to $address')),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = '$error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Widget _buildStatusCard(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _running ? Icons.dns : Icons.portable_wifi_off,
                  color: _running ? Colors.green : theme.colorScheme.error,
                ),
                const SizedBox(width: 12),
                Text(
                  _running ? 'Node Online' : 'Node Offline',
                  style: theme.textTheme.titleLarge,
                ),
              ],
            ),
            const SizedBox(height: 16),
            SelectableText('Peer ID: $_nodeId'),
            const SizedBox(height: 8),
            Text('${widget.engine.endpointLabel}: $_endpoint'),
            const SizedBox(height: 8),
            Text('Local IPv4: $_localIp'),
            if (_statusMessage != null) ...[
              const SizedBox(height: 12),
              Text(_statusMessage!),
            ],
            if (_errorMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                _errorMessage!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPeerActions(BuildContext context) {
    if (!widget.engine.supportsPeerConnections &&
        !widget.engine.supportsFileTransfers) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Text(
            'Peer connect and file transfer controls are not wired for the desktop engine yet.',
          ),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Peer Actions',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            if (widget.engine.supportsPeerConnections) ...[
              TextField(
                controller: _peerController,
                decoration: const InputDecoration(
                  labelText: 'Peer multiaddr',
                  hintText: '/ip4/192.168.1.20/tcp/4001/p2p/...',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _busy || !_running ? null : _connectToPeer,
                child: const Text('Connect'),
              ),
              const SizedBox(height: 12),
            ],
            if (!widget.engine.supportsFileTransfers)
              const Text(
                'File transfer is not connected to the Flutter bridge yet.',
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ShareThing')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _buildStatusCard(context),
            const SizedBox(height: 16),
            _buildPeerActions(context),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : (_running ? _stopEngine : _startEngine),
        label: Text(_running ? 'Stop Engine' : 'Start Engine'),
        icon: Icon(_running ? Icons.stop : Icons.play_arrow),
      ),
    );
  }
}
