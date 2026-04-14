class DiscoveredPeer {
  const DiscoveredPeer({
    required this.peerId,
    required this.nickname,
    required this.addresses,
    required this.lastSeen,
  });

  final String peerId;
  final String nickname;
  final List<String> addresses;
  final DateTime lastSeen;

  DiscoveredPeer copyWith({
    String? peerId,
    String? nickname,
    List<String>? addresses,
    DateTime? lastSeen,
  }) {
    return DiscoveredPeer(
      peerId: peerId ?? this.peerId,
      nickname: nickname ?? this.nickname,
      addresses: addresses ?? this.addresses,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }
}
