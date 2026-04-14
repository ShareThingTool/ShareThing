import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/storage/app_storage_paths.dart';
import 'app_settings.dart';

abstract class SettingsRepository {
  Future<AppSettings> loadSettings();

  Future<void> saveSettings(AppSettings settings);
}

class JsonSettingsRepository implements SettingsRepository {
  JsonSettingsRepository({AppStoragePaths? storagePaths})
    : _storagePaths = storagePaths ?? const AppStoragePaths();

  final AppStoragePaths _storagePaths;
  final JsonEncoder _encoder = const JsonEncoder.withIndent('  ');

  Future<File> _settingsFile() async {
    final directory = await _storagePaths.configDirectory();
    return File(p.join(directory.path, 'settings.json'));
  }

  @override
  Future<AppSettings> loadSettings() async {
    final file = await _settingsFile();
    if (!await file.exists()) {
      final defaults = AppSettings.defaults();
      await saveSettings(defaults);
      return defaults;
    }

    try {
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        final defaults = AppSettings.defaults();
        await saveSettings(defaults);
        return defaults;
      }

      return AppSettings.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (_) {
      final defaults = AppSettings.defaults();
      await saveSettings(defaults);
      return defaults;
    }
  }

  @override
  Future<void> saveSettings(AppSettings settings) async {
    final file = await _settingsFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(_encoder.convert(settings.toJson()), flush: true);
  }
}
