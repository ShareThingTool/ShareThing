import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:flutter/services.dart';

class EngineManager {

  static const _channel = MethodChannel('engine');

  // Desktop only
  Process? _engineProcess;
  final Map<String, Completer<Map<String, dynamic>>> _pendingRequests = {};

  final _eventController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get updates => _eventController.stream;

  bool get isAlive => Platform.isAndroid ? _androidStarted : _engineProcess != null;
  bool _androidStarted = false;

  // ─── Start ────────────────────────────────────────────────────────────────

  Future<void> start() async {
    if (Platform.isAndroid) {
      if (_androidStarted) return;
      final result = await _channel.invokeMethod<Map>('startEngine');
      print("Engine result: $result");
      _androidStarted = true;

      await Future.delayed(const Duration(seconds: 2));
      _eventController.add({'type': 'event', 'event': 'node_started'});
      return;
    }

    if (_engineProcess != null) return;
    await _startDesktopProcess();
  }

  Future<Map<String, dynamic>> sendCommand(String type, [Map<String, dynamic>? params]) async {
    print("SENDING COMMAND: $type with $params");

    if (Platform.isAndroid) {
      // All commands go through the MethodChannel — no sockets
      final args = <String, dynamic>{'type': type, ...?params};
      final result = await _channel.invokeMethod<Map>('command', args);
      return Map<String, dynamic>.from(result ?? {});
    }

    // Desktop: send JSON over stdin
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final completer = Completer<Map<String, dynamic>>();
    _pendingRequests[id] = completer;

    final request = {'requestId': id, 'type': type, ...?params};
    _engineProcess?.stdin.writeln(jsonEncode(request));

    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _pendingRequests.remove(id);
        throw TimeoutException("Engine failed to respond to $type in 10s");
      },
    );
  }

  // ─── Send file ────────────────────────────────────────────────────────────

  Future<void> sendFile(String path, String peerAddr) async {
    final file = File(path);
    final bytes = await file.readAsBytes();
    final encoded = base64Encode(bytes);
    final name = file.uri.pathSegments.last;

    await sendCommand("send_file", {
      "multiaddr": peerAddr,
      "filename": name,
      "data": encoded,
    });
  }

  // ─── Stop ─────────────────────────────────────────────────────────────────

  void stop() {
    if (Platform.isAndroid) {
      _androidStarted = false;
      return;
    }
    _engineProcess?.kill();
    _engineProcess = null;
  }

  // ─── Desktop process (macOS/Linux) ────────────────────────────────────────

  Future<void> _startDesktopProcess() async {
    final bytes = await rootBundle.load('assets/engine/p2p_engine.jar');
    final file = File('${Directory.systemTemp.path}/p2p_engine.jar');
    await file.writeAsBytes(bytes.buffer.asUint8List());

    final javaBin = await _findJava();
    if (javaBin == null) throw Exception("Java 17 not found");

    _engineProcess = await Process.start(javaBin, ['-jar', file.path]);

    _engineProcess!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleDesktopMessage);

    _engineProcess!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => print("ENGINE STDERR: $line"));

    _engineProcess!.exitCode.then((code) {
      _engineProcess = null;
      _eventController.add({'type': 'engine_stopped', 'exitCode': code});
    });
  }

  void _handleDesktopMessage(String line) {
    if (line.trim().isEmpty) return;
    try {
      final msg = jsonDecode(line) as Map<String, dynamic>;
      final id = msg['requestId'] as String?;
      if (id != null && _pendingRequests.containsKey(id)) {
        _pendingRequests[id]!.complete(msg);
        _pendingRequests.remove(id);
      } else {
        _eventController.add(msg);
      }
    } catch (_) {
      print("ENGINE: $line");
    }
  }

  Future<String?> _findJava() async {
    try {
      final home = Platform.environment['JAVA_HOME'];
      if (home != null) {
        final candidate = p.join(home, 'bin', 'java');
        if (await File(candidate).exists()) return candidate;
      }
      if (Platform.isMacOS) {
        final r = await Process.run('/usr/libexec/java_home', ['-v', '17']);
        final home = (r.stdout as String).trim();
        if (home.isNotEmpty) return p.join(home, 'bin', 'java');
      }
    } catch (_) {}
    return null;
  }
}