import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'app_logger.dart';

class EngineManager {
  static const _commandChannel = MethodChannel('engine/commands');
  static const _eventChannel = EventChannel('engine/events');
  static const _desktopJarAsset = 'assets/engine/p2p_engine.jar';

  Process? _engineProcess;
  Completer<void>? _desktopReady;
  StreamSubscription<dynamic>? _androidEventSubscription;
  final _eventController = StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get updates => _eventController.stream;
  bool get isAlive =>
      Platform.isAndroid ? _androidStarted : _engineProcess != null;
  bool get supportsFileTransfers => true;

  bool _androidStarted = false;

  Future<void> start({
    required String nickname,
    required List<String> discoveryServers,
  }) async {
    appLogger.i(
      'engine.start requested platform=${Platform.operatingSystem} '
      'nickname=$nickname discoveryServers=$discoveryServers',
    );
    if (Platform.isAndroid) {
      if (_androidStarted) return;
      await _listenForAndroidEvents();
      final started = _waitForEventTypes({'NODE_STARTED', 'ERROR'});
      await _sendAndroidCommand({
        'type': 'START_NODE',
        'nickname': nickname,
        'discoveryServers': discoveryServers,
      });
      _androidStarted = true;
      await started;
      appLogger.i('engine.start success (android)');
      return;
    }

    if (_engineProcess != null) return;
    await _startDesktopProcess();
    final started = _waitForEventTypes({'NODE_STARTED', 'ERROR'});
    await _sendDesktopCommand({
      'type': 'START_NODE',
      'nickname': nickname,
      'discoveryServers': discoveryServers,
    });
    await started;
    appLogger.i('engine.start success (desktop)');
  }

  Future<void> stop() async {
    appLogger.i('engine.stop requested');
    if (Platform.isAndroid) {
      if (_androidStarted) {
        await _sendAndroidCommand({'type': 'STOP_NODE'});
        _androidStarted = false;
      }
      await _androidEventSubscription?.cancel();
      _androidEventSubscription = null;
      return;
    }

    if (_engineProcess == null) return;
    final process = _engineProcess!;

    try {
      await _sendDesktopCommand({'type': 'STOP_NODE'});
    } catch (_) {
      // Best effort shutdown.
    }

    try {
      await process.stdin.close();
    } catch (_) {
      // Ignore shutdown races.
    }

    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
    } catch (_) {
      process.kill();
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {
        // Ignore forced shutdown races.
      }
    }

    _engineProcess = null;
    _desktopReady = null;
    appLogger.i('engine.stop completed');
  }

  Future<void> sendFile({
    required String targetPeerId,
    required String filePath,
  }) async {
    appLogger.i(
      'engine.sendFile targetPeerId=$targetPeerId filePath=$filePath',
    );
    final payload = {
      'type': 'SEND_FILE',
      'targetPeerId': targetPeerId,
      'filePath': filePath,
    };

    if (Platform.isAndroid) {
      await _sendAndroidCommand(payload);
      return;
    }

    await _sendDesktopCommand(payload);
  }

  Future<void> acceptFile({
    required String transferId,
    required String savePath,
  }) async {
    appLogger.i('engine.acceptFile transferId=$transferId savePath=$savePath');
    final payload = {
      'type': 'ACCEPT_FILE',
      'transferId': transferId,
      'savePath': savePath,
    };

    if (Platform.isAndroid) {
      await _sendAndroidCommand(payload);
      return;
    }

    await _sendDesktopCommand(payload);
  }

  Future<void> rejectFile({required String transferId}) async {
    appLogger.i('engine.rejectFile transferId=$transferId');
    final payload = {'type': 'REJECT_FILE', 'transferId': transferId};

    if (Platform.isAndroid) {
      await _sendAndroidCommand(payload);
      return;
    }

    await _sendDesktopCommand(payload);
  }

  Future<void> _listenForAndroidEvents() async {
    if (_androidEventSubscription != null) return;

    _androidEventSubscription = _eventChannel.receiveBroadcastStream().listen(
      (event) {
        final message = _decodeMessage(event);
        if (message == null) return;
        appLogger.d('engine.event.android $message');
        _eventController.add(message);
      },
      onError: (error) {
        appLogger.e('engine.event.android.error', error: error);
        _eventController.add({'type': 'ERROR', 'message': '$error'});
      },
    );
  }

  Future<void> _sendAndroidCommand(Map<String, dynamic> payload) async {
    appLogger.d('engine.command.android $payload');
    await _commandChannel.invokeMethod<void>(
      'commandJson',
      jsonEncode(payload),
    );
  }

  Future<void> _startDesktopProcess() async {
    final jarPath = await _resolveDesktopJarPath();
    final javaBin = await _findJava();
    if (javaBin == null) {
      throw StateError(
        'Java 17+ was not found. Set JAVA_HOME before starting ShareThing.',
      );
    }

    _desktopReady = Completer<void>();
    _engineProcess = await Process.start(javaBin, ['-jar', jarPath]);
    appLogger.i('engine.desktop.process.started jarPath=$jarPath');

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
      _eventController.add({'type': 'NODE_STOPPED', 'exitCode': code});
      appLogger.w('engine.desktop.process.exited exitCode=$code');
    });

    await _desktopReady!.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw TimeoutException(
        'Desktop engine did not report readiness in time.',
      ),
    );
  }

  Future<void> _sendDesktopCommand(Map<String, dynamic> payload) async {
    if (_engineProcess == null) {
      throw StateError('Desktop engine is not running.');
    }
    appLogger.d('engine.command.desktop $payload');
    _engineProcess!.stdin.writeln(jsonEncode(payload));
  }

  void _handleDesktopMessage(String line) {
    final message = _decodeMessage(line);
    if (message == null) {
      debugPrint('ENGINE: $line');
      return;
    }

    if (message['type'] == 'READY') {
      appLogger.i('engine.desktop.ready');
      _desktopReady?.complete();
      return;
    }

    appLogger.d('engine.event.desktop $message');
    _eventController.add(message);
  }

  Map<String, dynamic>? _decodeMessage(dynamic rawMessage) {
    try {
      if (rawMessage is Map) {
        return Map<String, dynamic>.from(rawMessage);
      }
      if (rawMessage is String) {
        return Map<String, dynamic>.from(jsonDecode(rawMessage) as Map);
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  Future<void> _waitForEventTypes(Set<String> types) async {
    appLogger.d('engine.waitForEventTypes types=${types.toList()}');
    final event = await updates
        .firstWhere((message) => types.contains(message['type']))
        .timeout(const Duration(seconds: 10));
    appLogger.d('engine.waitForEventTypes.done $event');

    if (event['type'] == 'ERROR') {
      throw StateError(event['message']?.toString() ?? 'Node error');
    }
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

  Future<String?> _findJava() async {
    try {
      final home = Platform.environment['JAVA_HOME'];
      if (home != null) {
        final candidate = p.join(home, 'bin', 'java');
        if (await File(candidate).exists()) return candidate;
      }

      if (Platform.isMacOS) {
        final result = await Process.run('/usr/libexec/java_home', [
          '-v',
          '17',
        ]);
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
