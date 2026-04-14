class FriendEntry {
  const FriendEntry({
    required this.peerId,
    required this.nickname,
    this.lastKnownShareAddress,
  });

  final String peerId;
  final String nickname;
  final String? lastKnownShareAddress;

  factory FriendEntry.fromJson(Map<String, dynamic> json) {
    final peerId =
        json['peerId']?.toString() ??
        _peerIdFromAddress(
          json['multiaddr']?.toString() ??
              json['lastKnownShareAddress']?.toString(),
        ) ??
        '';

    return FriendEntry(
      peerId: peerId,
      nickname: json['nickname']?.toString() ?? '',
      lastKnownShareAddress:
          json['lastKnownShareAddress']?.toString() ??
          json['multiaddr']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'peerId': peerId,
      'nickname': nickname,
      'lastKnownShareAddress': lastKnownShareAddress,
    };
  }

  FriendEntry copyWith({
    String? peerId,
    String? nickname,
    String? lastKnownShareAddress,
  }) {
    return FriendEntry(
      peerId: peerId ?? this.peerId,
      nickname: nickname ?? this.nickname,
      lastKnownShareAddress:
          lastKnownShareAddress ?? this.lastKnownShareAddress,
    );
  }

  static String? _peerIdFromAddress(String? address) {
    if (address == null || address.isEmpty) {
      return null;
    }

    final markerIndex = address.lastIndexOf('/p2p/');
    if (markerIndex == -1) {
      return null;
    }
    return address.substring(markerIndex + 5);
  }
}
