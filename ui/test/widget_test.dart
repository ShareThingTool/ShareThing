import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:sharething/core/engine_manager.dart';
import 'package:sharething/features/file_transfer/file_transfer_entry.dart';
import 'package:sharething/features/friends/friend.dart';
import 'package:sharething/features/friends/friends_repository.dart';
import 'package:sharething/features/settings/app_settings.dart';
import 'package:sharething/features/settings/settings_repository.dart';
import 'package:sharething/features/file_transfer/transfer_history_repository.dart';
import 'package:sharething/main.dart';

class FakeEngineManager extends EngineManager {
  final _controller = StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<Map<String, dynamic>> get updates => _controller.stream;

  @override
  Future<void> start({
    required String nickname,
    required List<String> discoveryServers,
    List<String> relayAddrs = const [],
  }) async {}

  @override
  Future<void> stop() async {}
}

class FakeFriendsRepository implements FriendsRepository {
  @override
  Future<List<FriendEntry>> loadFriends() async => const [];

  @override
  Future<void> saveFriends(List<FriendEntry> friends) async {}
}

class FakeSettingsRepository implements SettingsRepository {
  @override
  Future<AppSettings> loadSettings() async => AppSettings.defaults();

  @override
  Future<void> saveSettings(AppSettings settings) async {}
}

class FakeTransferHistoryRepository implements TransferHistoryRepository {
  @override
  Future<List<FileTransferEntry>> loadHistory() async => const [];

  @override
  Future<void> saveHistory(List<FileTransferEntry> entries) async {}
}

void main() {
  testWidgets('ShareThing home page renders identity card', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ShareThingApp(
        engine: FakeEngineManager(),
        friendsRepository: FakeFriendsRepository(),
        settingsRepository: FakeSettingsRepository(),
        transferHistoryRepository: FakeTransferHistoryRepository(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('ShareThing'), findsOneWidget);
    expect(find.text('Copy Peer ID'), findsOneWidget);
    expect(find.text('Friends'), findsOneWidget);
  });
}
