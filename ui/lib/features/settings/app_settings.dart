import 'dart:io';

class AppSettings {
  const AppSettings({
    required this.nickname,
    this.virusTotalApiKey,
    this.showBlakeHash = false,
  });

  final String nickname;
  final String? virusTotalApiKey;
  final bool showBlakeHash;

  factory AppSettings.defaults() {
    final hostname = _sanitizeHostname(Platform.localHostname);
    return AppSettings(
      nickname: hostname.isEmpty ? 'ShareThing User' : hostname,
    );
  }

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final nickname = json['nickname']?.toString().trim();
    final vtKey = json['virusTotalApiKey']?.toString().trim();
    return AppSettings(
      nickname: (nickname == null || nickname.isEmpty)
          ? AppSettings.defaults().nickname
          : nickname,
      virusTotalApiKey: (vtKey == null || vtKey.isEmpty) ? null : vtKey,
      showBlakeHash: json['showBlakeHash'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'nickname': nickname,
      if (virusTotalApiKey != null) 'virusTotalApiKey': virusTotalApiKey,
      'showBlakeHash': showBlakeHash,
    };
  }

  AppSettings copyWith({
    String? nickname,
    Object? virusTotalApiKey = _sentinel,
    bool? showBlakeHash,
  }) {
    return AppSettings(
      nickname: nickname ?? this.nickname,
      virusTotalApiKey: virusTotalApiKey == _sentinel
          ? this.virusTotalApiKey
          : virusTotalApiKey as String?,
      showBlakeHash: showBlakeHash ?? this.showBlakeHash,
    );
  }

  static const Object _sentinel = Object();

  static String _sanitizeHostname(String hostname) {
    return hostname
        .trim()
        .replaceAll(RegExp(r'\.local$'), '')
        .replaceAll(RegExp(r'[^A-Za-z0-9 _.-]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}
