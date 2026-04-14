class FriendEntry {
  const FriendEntry({required this.peerId, required this.nickname});

  final String peerId;
  final String nickname;

  factory FriendEntry.fromJson(Map<String, dynamic> json) {
    return FriendEntry(
      peerId: json['peerId']?.toString() ?? '',
      nickname: json['nickname']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {'peerId': peerId, 'nickname': nickname};
  }

  FriendEntry copyWith({String? peerId, String? nickname}) {
    return FriendEntry(
      peerId: peerId ?? this.peerId,
      nickname: nickname ?? this.nickname,
    );
  }
}
