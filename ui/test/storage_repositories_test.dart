import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharething/core/storage/app_storage_paths.dart';
import 'package:sharething/features/friends/friend.dart';
import 'package:sharething/features/friends/friends_repository.dart';
import 'package:sharething/features/settings/app_settings.dart';
import 'package:sharething/features/settings/settings_repository.dart';

class FakeStoragePaths extends AppStoragePaths {
  FakeStoragePaths(this._configDirectory, this._dataDirectory);

  final Directory _configDirectory;
  final Directory _dataDirectory;

  @override
  Future<Directory> configDirectory() async {
    await _configDirectory.create(recursive: true);
    return _configDirectory;
  }

  @override
  Future<Directory> dataDirectory() async {
    await _dataDirectory.create(recursive: true);
    return _dataDirectory;
  }
}

void main() {
  test('settings and friends repositories persist json files', () async {
    final root = await Directory.systemTemp.createTemp(
      'sharething-storage-test',
    );
    addTearDown(() => root.delete(recursive: true));

    final storagePaths = FakeStoragePaths(
      Directory('${root.path}/config'),
      Directory('${root.path}/data'),
    );
    final settingsRepository = JsonSettingsRepository(
      storagePaths: storagePaths,
    );
    final friendsRepository = JsonFriendsRepository(storagePaths: storagePaths);

    await settingsRepository.saveSettings(
      const AppSettings(nickname: 'Tester'),
    );
    await friendsRepository.saveFriends(const [
      FriendEntry(
        peerId: 'peer-123',
        nickname: 'Alice',
        lastKnownShareAddress: '/ip4/192.168.1.5/tcp/4101/p2p/peer-123',
      ),
    ]);

    final settingsFile = File('${root.path}/config/settings.json');
    final friendsFile = File('${root.path}/data/friends.json');

    expect(await settingsFile.exists(), isTrue);
    expect(await friendsFile.exists(), isTrue);

    final settingsJson = jsonDecode(await settingsFile.readAsString()) as Map;
    final friendsJson = jsonDecode(await friendsFile.readAsString()) as List;

    expect(settingsJson['nickname'], 'Tester');
    expect((friendsJson.first as Map)['peerId'], 'peer-123');
  });
}
