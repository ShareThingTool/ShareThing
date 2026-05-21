class FriendEntry {
  const FriendEntry({
    required this.peerId,
    required this.nickname,
    this.addresses = const [],
  });

  final String peerId;
  final String nickname;
  final List<String> addresses;

  factory FriendEntry.fromJson(Map<String, dynamic> json) {
    return FriendEntry(
      peerId: json['peerId']?.toString() ?? '',
      nickname: json['nickname']?.toString() ?? '',
      addresses: (json['addresses'] as List<dynamic>? ?? const [])
          .map((a) => a.toString())
          .toList(growable: false),
    );
  }

  Map<String, dynamic> toJson() {
    return {'peerId': peerId, 'nickname': nickname, 'addresses': addresses};
  }

  FriendEntry copyWith({String? peerId, String? nickname, List<String>? addresses}) {
    return FriendEntry(
      peerId: peerId ?? this.peerId,
      nickname: nickname ?? this.nickname,
      addresses: addresses ?? this.addresses,
    );
  }
}
