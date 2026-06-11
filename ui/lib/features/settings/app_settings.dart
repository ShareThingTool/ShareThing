import 'dart:io';

import 'package:flutter/material.dart';

class AppSettings {
  const AppSettings({
    required this.nickname,
    this.virusTotalApiKey,
    this.showBlakeHash = false,
    this.relayAddress,
    this.themeMode = ThemeMode.system,
  });

  final String nickname;
  final String? virusTotalApiKey;
  final bool showBlakeHash;
  final String? relayAddress;
  final ThemeMode themeMode;

  factory AppSettings.defaults() {
    final hostname = _sanitizeHostname(Platform.localHostname);
    return AppSettings(
      nickname: hostname.isEmpty ? 'ShareThing User' : hostname,
    );
  }

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final nickname = json['nickname']?.toString().trim();
    final vtKey = json['virusTotalApiKey']?.toString().trim();
    final relay = json['relayAddress']?.toString().trim();
    final themeMode = switch (json['themeMode']?.toString()) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    return AppSettings(
      nickname: (nickname == null || nickname.isEmpty)
          ? AppSettings.defaults().nickname
          : nickname,
      virusTotalApiKey: (vtKey == null || vtKey.isEmpty) ? null : vtKey,
      showBlakeHash: json['showBlakeHash'] as bool? ?? false,
      relayAddress: (relay == null || relay.isEmpty) ? null : relay,
      themeMode: themeMode,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'nickname': nickname,
      if (virusTotalApiKey != null) 'virusTotalApiKey': virusTotalApiKey,
      'showBlakeHash': showBlakeHash,
      if (relayAddress != null) 'relayAddress': relayAddress,
      'themeMode': switch (themeMode) {
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
        _ => 'system',
      },
    };
  }

  AppSettings copyWith({
    String? nickname,
    Object? virusTotalApiKey = _sentinel,
    bool? showBlakeHash,
    Object? relayAddress = _sentinel,
    ThemeMode? themeMode,
  }) {
    return AppSettings(
      nickname: nickname ?? this.nickname,
      virusTotalApiKey: virusTotalApiKey == _sentinel
          ? this.virusTotalApiKey
          : virusTotalApiKey as String?,
      showBlakeHash: showBlakeHash ?? this.showBlakeHash,
      relayAddress: relayAddress == _sentinel
          ? this.relayAddress
          : relayAddress as String?,
      themeMode: themeMode ?? this.themeMode,
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
