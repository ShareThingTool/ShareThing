import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/storage/app_storage_paths.dart';
import 'friend.dart';

abstract class FriendsRepository {
  Future<List<FriendEntry>> loadFriends();

  Future<void> saveFriends(List<FriendEntry> friends);
}

class JsonFriendsRepository implements FriendsRepository {
  JsonFriendsRepository({AppStoragePaths? storagePaths})
    : _storagePaths = storagePaths ?? const AppStoragePaths();

  final AppStoragePaths _storagePaths;
  final JsonEncoder _encoder = const JsonEncoder.withIndent('  ');

  Future<File> _friendsFile() async {
    final directory = await _storagePaths.dataDirectory();
    return File(p.join(directory.path, 'friends.json'));
  }

  @override
  Future<List<FriendEntry>> loadFriends() async {
    final file = await _friendsFile();
    if (!await file.exists()) {
      await saveFriends(const []);
      return const [];
    }

    try {
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        await saveFriends(const []);
        return const [];
      }

      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .map(
            (entry) =>
                FriendEntry.fromJson(Map<String, dynamic>.from(entry as Map)),
          )
          .where(
            (entry) => entry.peerId.isNotEmpty && entry.nickname.isNotEmpty,
          )
          .toList(growable: false);
    } catch (_) {
      await saveFriends(const []);
      return const [];
    }
  }

  @override
  Future<void> saveFriends(List<FriendEntry> friends) async {
    final file = await _friendsFile();
    await file.parent.create(recursive: true);
    final payload = friends
        .map((friend) => friend.toJson())
        .toList(growable: false);
    await file.writeAsString(_encoder.convert(payload), flush: true);
  }
}
