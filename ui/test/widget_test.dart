import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharething/core/engine_manager.dart';
import 'package:sharething/features/discovery/discovered_peer.dart';
import 'package:sharething/features/discovery/local_discovery_service.dart';
import 'package:sharething/features/file_transfer/file_transfer_entry.dart';
import 'package:sharething/features/file_transfer/local_file_transfer_service.dart';
import 'package:sharething/features/friends/friend.dart';
import 'package:sharething/features/friends/friends_repository.dart';
import 'package:sharething/features/settings/app_settings.dart';
import 'package:sharething/features/settings/settings_repository.dart';
import 'package:sharething/main.dart';

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
        'data': '/ip4/192.168.1.20/tcp/4101/p2p/fake-peer-id',
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

class InMemoryFriendsRepository implements FriendsRepository {
  InMemoryFriendsRepository([List<FriendEntry>? friends])
    : _friends = [...?friends];

  List<FriendEntry> _friends;

  @override
  Future<List<FriendEntry>> loadFriends() async =>
      List<FriendEntry>.from(_friends);

  @override
  Future<void> saveFriends(List<FriendEntry> friends) async {
    _friends = List<FriendEntry>.from(friends);
  }
}

class InMemorySettingsRepository implements SettingsRepository {
  InMemorySettingsRepository([AppSettings? settings])
    : _settings = settings ?? const AppSettings(nickname: 'Local Tester');

  AppSettings _settings;

  @override
  Future<AppSettings> loadSettings() async => _settings;

  @override
  Future<void> saveSettings(AppSettings settings) async {
    _settings = settings;
  }
}

class FakeLocalDiscoveryService implements LocalDiscoveryService {
  final _controller = StreamController<List<DiscoveredPeer>>.broadcast();

  String? lastStartedPeerId;
  String? lastStartedNickname;
  String? lastStartedShareAddress;

  @override
  Stream<List<DiscoveredPeer>> get peers => _controller.stream;

  @override
  Future<void> start({
    required String peerId,
    required String nickname,
    required String shareAddress,
    required int? fileTransferPort,
    required List<String> capabilities,
  }) async {
    lastStartedPeerId = peerId;
    lastStartedNickname = nickname;
    lastStartedShareAddress = shareAddress;
  }

  @override
  Future<void> stop() async {}

  void emit(List<DiscoveredPeer> peers) {
    _controller.add(peers);
  }
}

class FakeLocalFileTransferService implements LocalFileTransferService {
  final _controller = StreamController<List<FileTransferEntry>>.broadcast();

  String? lastPeerId;
  String? lastPeerLabel;
  String? lastHostAddress;
  int? lastPort;
  String? lastFilePath;

  @override
  Stream<List<FileTransferEntry>> get transfers => _controller.stream;

  @override
  int? get listeningPort => 47290;

  @override
  Future<void> start({
    required String peerId,
    required String nickname,
  }) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> sendFile({
    required String peerId,
    required String peerLabel,
    required String hostAddress,
    required int port,
    required String filePath,
  }) async {
    lastPeerId = peerId;
    lastPeerLabel = peerLabel;
    lastHostAddress = hostAddress;
    lastPort = port;
    lastFilePath = filePath;
  }
}

void _setLargeSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 2200);
  tester.view.devicePixelRatio = 1;
}

ShareThingApp _buildApp({
  required FakeEngineManager engine,
  FriendsRepository? friendsRepository,
  SettingsRepository? settingsRepository,
  FakeLocalDiscoveryService? discoveryService,
  FakeLocalFileTransferService? fileTransferService,
}) {
  return ShareThingApp(
    engine: engine,
    friendsRepository: friendsRepository ?? InMemoryFriendsRepository(),
    settingsRepository: settingsRepository ?? InMemorySettingsRepository(),
    discoveryService: discoveryService ?? FakeLocalDiscoveryService(),
    fileTransferService: fileTransferService ?? FakeLocalFileTransferService(),
  );
}

void main() {
  testWidgets(
    'renders current engine state, nickname, and empty friends list',
    (tester) async {
      _setLargeSurface(tester);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final engine = FakeEngineManager();
      final discovery = FakeLocalDiscoveryService();

      await tester.pumpWidget(
        _buildApp(engine: engine, discoveryService: discovery),
      );
      await tester.pumpAndSettle();

      expect(find.text('Node Online'), findsOneWidget);
      expect(find.text('Nickname: Local Tester'), findsOneWidget);
      expect(find.text('Peer ID: fake-peer-id'), findsOneWidget);
      expect(
        find.text('Share address: /ip4/192.168.1.20/tcp/4101/p2p/fake-peer-id'),
        findsOneWidget,
      );
      expect(find.text('No friends saved yet.'), findsOneWidget);
      expect(find.text('No LAN peers discovered yet.'), findsOneWidget);
      expect(discovery.lastStartedPeerId, 'fake-peer-id');
      expect(discovery.lastStartedNickname, 'Local Tester');
    },
  );

  testWidgets('manual connect sends the entered multiaddr to the engine', (
    tester,
  ) async {
    _setLargeSurface(tester);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final engine = FakeEngineManager();

    await tester.pumpWidget(_buildApp(engine: engine));
    await tester.pumpAndSettle();

    const remoteAddress = '/ip4/192.168.1.30/tcp/4101/p2p/remote-peer';

    await tester.enterText(
      find.byKey(const ValueKey('manual-peer-field')),
      remoteAddress,
    );
    await tester.tap(find.byKey(const ValueKey('manual-connect-button')));
    await tester.pumpAndSettle();

    expect(engine.lastConnectedAddress, remoteAddress);
    expect(find.text('Connected to $remoteAddress'), findsOneWidget);
  });

  testWidgets('loads a saved friend and connects using the cached route', (
    tester,
  ) async {
    _setLargeSurface(tester);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final engine = FakeEngineManager();
    final repository = InMemoryFriendsRepository([
      const FriendEntry(
        peerId: 'alice-peer',
        nickname: 'Alice',
        lastKnownShareAddress: '/ip4/192.168.1.44/tcp/4101/p2p/alice-peer',
      ),
    ]);

    await tester.pumpWidget(
      _buildApp(engine: engine, friendsRepository: repository),
    );
    await tester.pumpAndSettle();

    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Peer ID: alice-peer'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('friend-connect-alice-peer')));
    await tester.pumpAndSettle();

    expect(
      engine.lastConnectedAddress,
      '/ip4/192.168.1.44/tcp/4101/p2p/alice-peer',
    );
    expect(
      find.text('Connected to /ip4/192.168.1.44/tcp/4101/p2p/alice-peer'),
      findsOneWidget,
    );
  });

  testWidgets('shows discovered peers and allows direct connect', (
    tester,
  ) async {
    _setLargeSurface(tester);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final engine = FakeEngineManager();
    final discovery = FakeLocalDiscoveryService();

    await tester.pumpWidget(
      _buildApp(engine: engine, discoveryService: discovery),
    );
    await tester.pumpAndSettle();

    discovery.emit([
      DiscoveredPeer(
        peerId: 'bob-peer',
        nickname: 'Bob',
        shareAddress: '/ip4/192.168.1.55/tcp/4101/p2p/bob-peer',
        hostAddress: '192.168.1.55',
        fileTransferPort: 47290,
        platform: 'linux',
        capabilities: const ['tcp-connect', 'lan-announcement'],
        lastSeen: DateTime.now(),
      ),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('Bob'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('discovered-connect-bob-peer')));
    await tester.pumpAndSettle();

    expect(
      engine.lastConnectedAddress,
      '/ip4/192.168.1.55/tcp/4101/p2p/bob-peer',
    );
  });
}
