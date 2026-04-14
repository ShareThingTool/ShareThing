class DiscoveredPeer {
  const DiscoveredPeer({
    required this.peerId,
    required this.nickname,
    required this.shareAddress,
    required this.hostAddress,
    required this.fileTransferPort,
    required this.platform,
    required this.capabilities,
    required this.lastSeen,
  });

  final String peerId;
  final String nickname;
  final String shareAddress;
  final String hostAddress;
  final int? fileTransferPort;
  final String platform;
  final List<String> capabilities;
  final DateTime lastSeen;

  DiscoveredPeer copyWith({
    String? peerId,
    String? nickname,
    String? shareAddress,
    String? hostAddress,
    int? fileTransferPort,
    String? platform,
    List<String>? capabilities,
    DateTime? lastSeen,
  }) {
    return DiscoveredPeer(
      peerId: peerId ?? this.peerId,
      nickname: nickname ?? this.nickname,
      shareAddress: shareAddress ?? this.shareAddress,
      hostAddress: hostAddress ?? this.hostAddress,
      fileTransferPort: fileTransferPort ?? this.fileTransferPort,
      platform: platform ?? this.platform,
      capabilities: capabilities ?? this.capabilities,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }
}
