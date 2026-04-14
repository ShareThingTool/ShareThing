class AppSettings {
  const AppSettings({required this.nickname});

  final String nickname;

  factory AppSettings.defaults() =>
      const AppSettings(nickname: 'ShareThing User');

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
}
