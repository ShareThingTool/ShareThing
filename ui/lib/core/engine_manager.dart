import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:flutter/services.dart';

class EngineManager {

  static const String red = '\u001b[31m';
  static const String green = '\u001b[32m';
  static const String blue = '\u001b[34m';
  static const String yellow = '\u001b[33m';
  static const String reset = '\u001b[0m';

  Process? _engineProcess;
  Socket? _socket;
  StreamSubscription? _socketSub;
  final Map<String, Completer<Map<String, dynamic>>> _pendingRequests = {};

  final _eventController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get updates => _eventController.stream;

  bool get isAlive => _engineProcess != null;

  Future<String> _prepareJar() async {
    final bytes = await rootBundle.load('assets/engine/p2p_engine.jar');
    final file = File('${Directory.systemTemp.path}/p2p_engine.jar');
    await file.writeAsBytes(bytes.buffer.asUint8List());
    return file.path;
  }

  Future<void> start() async {
    if (isAlive) {
      print("$blue DEBUG: [Engine] Start requested, but engine is already alive.");
      return;
    }

    if (Platform.isAndroid) {
      await _startViaPlatformChannel();
      return;
    }

    final String jarPath = await _prepareJar();

    Future<String?> findSystemJava() async {
      try {
        final javaHome = Platform.environment['JAVA_HOME'];
        if (javaHome != null && javaHome.isNotEmpty) {
          final candidate = p.join(javaHome, 'bin', 'java');
          if (await File(candidate).exists()) {
            return candidate;
          }
        }

        if (Platform.isMacOS) {
          var result = await Process.run('/usr/libexec/java_home', ['-v', '17']);
          var javaHome = (result.stdout as String).trim();

          if (javaHome.isEmpty) {
            result = await Process.run('/usr/libexec/java_home', []);
            javaHome = (result.stdout as String).trim();
          }

          if (javaHome.isNotEmpty) {
            final candidate = p.join(javaHome, 'bin', 'java');
            return candidate;
          }
        }

        final result = await Process.run('/usr/bin/java', ['-version']);
        final output = (result.stderr as String);
        if (output.contains('17')) return '/usr/bin/java';
      } catch (_) {}

      return null;
    }

    final String? systemJava = await findSystemJava();
    print("SYSTEM JAVA DETECTED: $systemJava");

    if (systemJava == null) {
      throw Exception("Java 17 not found on system. Aborting instead of using broken bundled JRE.");
    }

    final String javaBin = systemJava;

    print("$blue DEBUG:$reset [Engine] Booting JAR at: $jarPath");
    print("$blue DEBUG:$reset [Engine] Using JRE at: $javaBin");

    try {
      _engineProcess = await Process.start(javaBin, ['-jar', jarPath]);
      print("$blue DEBUG: $reset [Engine] Process started. PID: ${_engineProcess!.pid}");

      _engineProcess!.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        print("$green INCOMING $reset: $line");
        _handleIncomingMessage(line);
      });

      _engineProcess!.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        print("$red KOTLIN STDERR $reset: $line");
      });

      _engineProcess!.exitCode.then((code) {
        print("$blue DEBUG: $reset [Engine] Process exited with code: $code");
        _engineProcess = null;
        _eventController.add({'type': 'engine_stopped', 'exitCode': code});
      });
    } catch (e) {
      print("$blue DEBUG: $reset [Engine] Failed to start process: $e");
      _eventController.add({'type': 'error', 'message': e.toString()});
    }
  }

  void _handleIncomingMessage(String line) {
    if (line.trim().isEmpty) return;

    try {
      final Map<String, dynamic> msg = jsonDecode(line);
      final String? id = msg['requestId'];

      if (id != null) {
        if (_pendingRequests.containsKey(id)) {
          print("$blue DEBUG: $reset [Bridge] Completing request ID: $id");
          _pendingRequests[id]!.complete(msg);
          _pendingRequests.remove(id);
        } else {
          print("$blue DEBUG: $reset [Bridge] Received response for unknown/expired ID: $id");
        }
      } else {
        print("$blue DEBUG: $reset [Bridge] Processing spontaneous event: ${msg['type']}");
        _eventController.add(msg);
      }
    } catch (e) {
      print("$blue DEBUG: $reset [Bridge] Non-JSON or Malformed output: $line");
    }
  }

  Future<Map<String, dynamic>> sendCommand(String type, [Map<String, dynamic>? params]) async {
    print("SENDING COMMAND: $type with $params");
    if (Platform.isAndroid) {
      if (_socket == null) {
        _socket = await Socket.connect('127.0.0.1', 4001);

        _socketSub = _socket!
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
              try {
                final msg = jsonDecode(line);
                if (msg is Map<String, dynamic>) {
                  if (msg.containsKey("requestId")) {
                    final id = msg["requestId"];
                    if (_pendingRequests.containsKey(id)) {
                      _pendingRequests[id]!.complete(msg);
                      _pendingRequests.remove(id);
                    }
                  } else {
                    _eventController.add(msg);
                  }
                }
              } catch (e) {
                print("Socket parse error: $e");
              }
            });
      }

      final id = DateTime.now().microsecondsSinceEpoch.toString();
      final completer = Completer<Map<String, dynamic>>();
      _pendingRequests[id] = completer;

      final payload = {
        "requestId": id,
        "type": type,
        if (params != null) ...params,
      };

      _socket!.writeln(jsonEncode(payload));

      return completer.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          _pendingRequests.remove(id);
          throw TimeoutException("Engine failed to respond to $type");
        },
      );
    }

    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final completer = Completer<Map<String, dynamic>>();
    _pendingRequests[id] = completer;

    final request = {'requestId': id, 'type': type, ...?params};
    final rawJson = jsonEncode(request);

    print("OUTGOING (ID: $id): $rawJson");

    if (_engineProcess != null) {
      _engineProcess!.stdin.writeln(rawJson);
    } else {
      print("$blue DEBUG: $reset [Bridge] Attempted to send command while engine was null.");
      completer.completeError("Engine not running");
    }

    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        print("$blue DEBUG: [Bridge] $reset TIMEOUT waiting for response to ID: $id");
        _pendingRequests.remove(id);
        throw TimeoutException("Engine failed to respond to $type in 10s");
      },
    );
  }

  Future<void> sendFile(String path, String peerAddr) async {
    final file = File(path);
    final bytes = await file.readAsBytes();

    final encoded = base64Encode(bytes);
    final name = file.uri.pathSegments.last;

    await sendCommand("connect", {
      "multiaddr": peerAddr,
      "type": "send_file",
      "filename": name,
      "data": encoded,
    });
  }

  void stop() {
    if (_engineProcess != null) {
      print("$blue DEBUG: $reset [Engine]  Stopping process...");
      _engineProcess!.kill();
      _engineProcess = null;
      _socketSub?.cancel();
      _socket?.destroy();
      _socket = null;
    }
  }

  Future<void> _startViaPlatformChannel() async {
    final platform = MethodChannel('engine');

    try {
      final result = await platform.invokeMethod('startEngine');
      print("Engine result: $result");
    } catch (e) {
      print("Platform channel error: $e");
    }
  }
}
