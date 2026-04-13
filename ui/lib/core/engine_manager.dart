import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

class EngineManager {
  static const _channel = MethodChannel('engine');
  static const _desktopJarAsset = 'assets/engine/p2p_engine.jar';

  Process? _engineProcess;
  Completer<void>? _desktopReady;
  final Map<String, Completer<Map<String, dynamic>>> _pendingRequests = {};
  final _eventController = StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get updates => _eventController.stream;
  bool get isAlive => Platform.isAndroid ? _androidStarted : _engineProcess != null;
  bool get supportsPeerConnections => Platform.isAndroid;
  bool get supportsFileTransfers => false;
  String get endpointLabel => Platform.isAndroid ? 'Listen address' : 'Listen port';

  bool _androidStarted = false;

  Future<void> start() async {
    if (Platform.isAndroid) {
      if (_androidStarted) return;
      await _channel.invokeMethod<Map>('startEngine');
      _androidStarted = true;
      await Future.delayed(const Duration(seconds: 2));
      _eventController.add({'type': 'event', 'event': 'node_started'});
      return;
    }

    if (_engineProcess != null) return;
    await _startDesktopProcess();

    final port = await _findAvailablePort();
    final response = await sendCommand('start_node', {'port': port});
    _ensureDesktopCommandSucceeded('start_node', response);
    _eventController.add({'type': 'event', 'event': 'node_started'});
  }

  Future<Map<String, dynamic>> sendCommand(
    String type, [
    Map<String, dynamic>? params,
  ]) async {
    if (Platform.isAndroid) {
      final args = <String, dynamic>{'type': type, ...?params};
      final result = await _channel.invokeMethod<Map>('command', args);
      return Map<String, dynamic>.from(result ?? {});
    }

    if (_engineProcess == null) {
      throw StateError('Desktop engine is not running.');
    }

    const supportedDesktopCommands = {
      'start_node',
      'stop_node',
      'get_id',
      'get_port',
    };

    if (!supportedDesktopCommands.contains(type)) {
      throw UnsupportedError(
        'Desktop engine command `$type` is not implemented yet.',
      );
    }

    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final completer = Completer<Map<String, dynamic>>();
    _pendingRequests[id] = completer;

    final request = {'requestId': id, 'type': type, ...?params};
    _engineProcess!.stdin.writeln(jsonEncode(request));

    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _pendingRequests.remove(id);
        throw TimeoutException('Engine failed to respond to $type in 10s');
      },
    );
  }

  Future<void> sendFile(String path, String peerAddr) async {
    throw UnsupportedError(
      'File transfer is not wired into the Flutter bridge yet. Requested `$path` for `$peerAddr`.',
    );
  }

  Future<void> stop() async {
    if (Platform.isAndroid) {
      if (_androidStarted) {
        _androidStarted = false;
        _eventController.add({'type': 'event', 'event': 'node_stopped'});
      }
      return;
    }

    final process = _engineProcess;
    if (process == null) return;

    try {
      final response = await sendCommand('stop_node');
      _ensureDesktopCommandSucceeded('stop_node', response);
    } catch (_) {
      // Best effort shutdown. The process is still terminated below.
    }

    process.kill();
    _engineProcess = null;
    _desktopReady = null;
    _failPendingRequests('Desktop engine stopped.');
    _eventController.add({'type': 'event', 'event': 'node_stopped'});
  }

  Future<void> _startDesktopProcess() async {
    final jarPath = await _resolveDesktopJarPath();
    final javaBin = await _findJava();
    if (javaBin == null) {
      throw StateError('Java 17+ was not found. Set JAVA_HOME before starting ShareThing.');
    }

    _desktopReady = Completer<void>();
    _engineProcess = await Process.start(javaBin, ['-jar', jarPath]);

    _engineProcess!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleDesktopMessage);

    _engineProcess!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => debugPrint('ENGINE STDERR: $line'));

    _engineProcess!.exitCode.then((code) {
      _engineProcess = null;
      _desktopReady ??= Completer<void>();
      if (!_desktopReady!.isCompleted) {
        _desktopReady!.completeError(
          StateError('Desktop engine exited during startup with code $code.'),
        );
      }
      _failPendingRequests('Desktop engine exited with code $code.');
      _eventController.add({'type': 'event', 'event': 'node_stopped', 'exitCode': code});
    });

    await _desktopReady!.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw TimeoutException(
        'Desktop engine did not report readiness in time.',
      ),
    );
  }

  void _handleDesktopMessage(String line) {
    if (line.trim().isEmpty) return;

    try {
      final msg = jsonDecode(line) as Map<String, dynamic>;
      final type = msg['type'] as String?;
      final data = msg['data'];

      if (type == 'event' && data == 'ready') {
        _desktopReady?.complete();
        return;
      }

      final id = msg['requestId'] as String?;
      if (id != null && _pendingRequests.containsKey(id)) {
        _pendingRequests[id]!.complete(msg);
        _pendingRequests.remove(id);
        return;
      }

      if (type == 'event' && data is String) {
        _eventController.add({'type': 'event', 'event': data});
        return;
      }

      _eventController.add(msg);
    } catch (_) {
      debugPrint('ENGINE: $line');
    }
  }

  void _ensureDesktopCommandSucceeded(
    String command,
    Map<String, dynamic> response,
  ) {
    final error = response['error'];
    if (error is String && error.isNotEmpty) {
      throw StateError('Desktop engine failed `$command`: $error');
    }

    final data = response['data'];
    if (data is String && data.startsWith('Error:')) {
      throw StateError('Desktop engine failed `$command`: $data');
    }
  }

  void _failPendingRequests(String message) {
    for (final entry in _pendingRequests.entries) {
      if (!entry.value.isCompleted) {
        entry.value.completeError(StateError(message));
      }
    }
    _pendingRequests.clear();
  }

  Future<String> _resolveDesktopJarPath() async {
    final developmentJar = File(
      p.normalize(
        p.join(
          Directory.current.path,
          '..',
          'engine',
          'lib',
          'build',
          'libs',
          'lib-desktop.jar',
        ),
      ),
    );

    if (await developmentJar.exists()) {
      return developmentJar.path;
    }

    try {
      final bytes = await rootBundle.load(_desktopJarAsset);
      final file = File('${Directory.systemTemp.path}/p2p_engine.jar');
      await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
      return file.path;
    } on FlutterError {
      throw StateError(
        'Desktop engine JAR not found. Build it with `cd ../engine && ./gradlew :lib:desktopJar` '
        'or `:lib:syncDesktopJar` before starting the desktop app.',
      );
    }
  }

  Future<int> _findAvailablePort() async {
    final socket = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  Future<String?> _findJava() async {
    try {
      final home = Platform.environment['JAVA_HOME'];
      if (home != null) {
        final candidate = p.join(home, 'bin', 'java');
        if (await File(candidate).exists()) return candidate;
      }

      if (Platform.isMacOS) {
        final result = await Process.run('/usr/libexec/java_home', ['-v', '17']);
        final resolvedHome = (result.stdout as String).trim();
        if (resolvedHome.isNotEmpty) {
          return p.join(resolvedHome, 'bin', 'java');
        }
      }

      final result = await Process.run('which', ['java']);
      final candidate = (result.stdout as String).trim();
      if (candidate.isNotEmpty) {
        return candidate;
      }
    } catch (_) {
      return null;
    }

    return null;
  }
}
