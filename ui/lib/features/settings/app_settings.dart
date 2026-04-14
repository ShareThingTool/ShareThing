import 'dart:io';

class AppSettings {
  const AppSettings({required this.nickname});

  final String nickname;

  factory AppSettings.defaults() {
    final hostname = _sanitizeHostname(Platform.localHostname);
    return AppSettings(
      nickname: hostname.isEmpty ? 'ShareThing User' : hostname,
    );
  }

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final nickname = json['nickname']?.toString().trim();
    return AppSettings(
      nickname: (nickname == null || nickname.isEmpty)
          ? AppSettings.defaults().nickname
          : nickname,
    );
  }

  Map<String, dynamic> toJson() {
    return {'nickname': nickname};
  }

  AppSettings copyWith({String? nickname}) {
    return AppSettings(nickname: nickname ?? this.nickname);
  }

  static String _sanitizeHostname(String hostname) {
    return hostname
        .trim()
        .replaceAll(RegExp(r'\.local$'), '')
        .replaceAll(RegExp(r'[^A-Za-z0-9 _.-]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}
