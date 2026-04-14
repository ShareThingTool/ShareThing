import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'friend.dart';

class FriendsRepository {
  static const storageKey = 'friends_v1';

  Future<List<FriendEntry>> loadFriends() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(storageKey);
    if (raw == null || raw.isEmpty) {
      return const [];
    }

    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .map(
            (entry) =>
                FriendEntry.fromJson(Map<String, dynamic>.from(entry as Map)),
          )
          .where(
            (entry) =>
                entry.id.isNotEmpty &&
                entry.nickname.isNotEmpty &&
                entry.multiaddr.isNotEmpty,
          )
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveFriends(List<FriendEntry> friends) async {
    final preferences = await SharedPreferences.getInstance();
    final encoded = jsonEncode(
      friends.map((friend) => friend.toJson()).toList(growable: false),
    );
    await preferences.setString(storageKey, encoded);
  }
}
