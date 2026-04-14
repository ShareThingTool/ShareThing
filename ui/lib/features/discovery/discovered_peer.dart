class DiscoveredPeer {
  const DiscoveredPeer({
    required this.peerId,
    required this.nickname,
    required this.shareAddress,
    required this.platform,
    required this.capabilities,
    required this.lastSeen,
  });

  final String peerId;
  final String nickname;
  final String shareAddress;
  final String platform;
  final List<String> capabilities;
  final DateTime lastSeen;

  DiscoveredPeer copyWith({
    String? peerId,
    String? nickname,
    String? shareAddress,
    String? platform,
    List<String>? capabilities,
    DateTime? lastSeen,
  }) {
    return DiscoveredPeer(
      peerId: peerId ?? this.peerId,
      nickname: nickname ?? this.nickname,
      shareAddress: shareAddress ?? this.shareAddress,
      platform: platform ?? this.platform,
      capabilities: capabilities ?? this.capabilities,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }
}
