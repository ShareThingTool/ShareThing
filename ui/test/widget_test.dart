import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharething/core/engine_manager.dart';
import 'package:sharething/main.dart';

class FakeEngineManager extends EngineManager {
  final StreamController<Map<String, dynamic>> _updatesController =
      StreamController<Map<String, dynamic>>.broadcast();

  bool _started = false;

  @override
  Stream<Map<String, dynamic>> get updates => _updatesController.stream;

  @override
  bool get supportsPeerConnections => false;

  @override
  bool get supportsFileTransfers => false;

  @override
  String get endpointLabel => 'Listen port';

  @override
  Future<void> start() async {
    _started = true;
    _updatesController.add({'type': 'event', 'event': 'node_started'});
  }

  @override
  Future<Map<String, dynamic>> sendCommand(
    String type, [
    Map<String, dynamic>? params,
  ]) async {
    return switch (type) {
      'get_id' => {'data': 'fake-peer-id'},
      'get_port' => {'data': '4001'},
      'stop_node' => {'data': 'Stopped'},
      _ => {'data': params},
    };
  }

  @override
  Future<void> stop() async {
    if (_started) {
      _started = false;
      _updatesController.add({'type': 'event', 'event': 'node_stopped'});
    }
  }
}

void main() {
  testWidgets('renders current engine state', (tester) async {
    await tester.pumpWidget(ShareThingApp(engine: FakeEngineManager()));
    await tester.pumpAndSettle();

    expect(find.text('Node Online'), findsOneWidget);
    expect(find.textContaining('fake-peer-id'), findsOneWidget);
    expect(find.textContaining('4001'), findsOneWidget);
    expect(
      find.text(
        'Peer connect and file transfer controls are not wired for the desktop engine yet.',
      ),
      findsOneWidget,
    );
  });
}
