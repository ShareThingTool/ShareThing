class FriendEntry {
  const FriendEntry({
    required this.id,
    required this.nickname,
    required this.multiaddr,
  });

  final String id;
  final String nickname;
  final String multiaddr;

  factory FriendEntry.fromJson(Map<String, dynamic> json) {
    return FriendEntry(
      id: json['id']?.toString() ?? '',
      nickname: json['nickname']?.toString() ?? '',
      multiaddr: json['multiaddr']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {'id': id, 'nickname': nickname, 'multiaddr': multiaddr};
  }

  FriendEntry copyWith({String? id, String? nickname, String? multiaddr}) {
    return FriendEntry(
      id: id ?? this.id,
      nickname: nickname ?? this.nickname,
      multiaddr: multiaddr ?? this.multiaddr,
    );
  }
}
