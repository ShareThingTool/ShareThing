import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharething/core/engine_manager.dart';
import 'package:sharething/features/friends/friend.dart';
import 'package:sharething/features/friends/friends_repository.dart';
import 'package:sharething/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeEngineManager extends EngineManager {
  final StreamController<Map<String, dynamic>> _updatesController =
      StreamController<Map<String, dynamic>>.broadcast();

  bool _started = false;
  String? lastConnectedAddress;

  @override
  Stream<Map<String, dynamic>> get updates => _updatesController.stream;

  @override
  bool get supportsPeerConnections => true;

  @override
  bool get supportsFileTransfers => false;

  @override
  String get endpointLabel => 'Share address';

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
      'get_listen_address' => {
        'data': '/ip4/192.168.1.20/tcp/4001/p2p/fake-peer-id',
      },
      'connect' => {
        'status': 'connected',
        'addr': lastConnectedAddress = params?['multiaddr'] as String?,
      },
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

void _setLargeSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 2000);
  tester.view.devicePixelRatio = 1;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('renders current engine state and empty friends list', (
    tester,
  ) async {
    _setLargeSurface(tester);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(ShareThingApp(engine: FakeEngineManager()));
    await tester.pumpAndSettle();

    expect(find.text('Node Online'), findsOneWidget);
    expect(find.text('Peer ID: fake-peer-id'), findsOneWidget);
    expect(
      find.text('Share address: /ip4/192.168.1.20/tcp/4001/p2p/fake-peer-id'),
      findsOneWidget,
    );
    expect(find.text('Friends'), findsOneWidget);
    expect(find.text('No friends saved yet.'), findsOneWidget);
    expect(find.byKey(const ValueKey('manual-peer-field')), findsOneWidget);
    expect(find.byKey(const ValueKey('manual-connect-button')), findsOneWidget);
  });

  testWidgets('manual connect sends the entered multiaddr to the engine', (
    tester,
  ) async {
    _setLargeSurface(tester);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final engine = FakeEngineManager();

    await tester.pumpWidget(ShareThingApp(engine: engine));
    await tester.pumpAndSettle();

    const remoteAddress = '/ip4/192.168.1.30/tcp/4001/p2p/remote-peer';

    await tester.enterText(
      find.byKey(const ValueKey('manual-peer-field')),
      remoteAddress,
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('manual-connect-button')),
    );
    await tester.tap(find.byKey(const ValueKey('manual-connect-button')));
    await tester.pumpAndSettle();

    expect(engine.lastConnectedAddress, remoteAddress);
    expect(find.text('Connected to $remoteAddress'), findsOneWidget);
  });

  testWidgets(
    'loads a saved friend and connects using the stored share address',
    (tester) async {
      _setLargeSurface(tester);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const alice = FriendEntry(
        id: 'alice',
        nickname: 'Alice',
        multiaddr: '/ip4/192.168.1.44/tcp/4001/p2p/alice-peer',
      );
      await FriendsRepository().saveFriends(const [alice]);

      final engine = FakeEngineManager();

      await tester.pumpWidget(ShareThingApp(engine: engine));
      await tester.pumpAndSettle();

      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('Unknown'), findsOneWidget);

      await tester.ensureVisible(
        find.byKey(const ValueKey('friend-connect-alice')),
      );
      await tester.tap(find.byKey(const ValueKey('friend-connect-alice')));
      await tester.pumpAndSettle();

      expect(engine.lastConnectedAddress, alice.multiaddr);
      expect(find.text('Online'), findsOneWidget);
    },
  );
}
