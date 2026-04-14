import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class AppStoragePaths {
  const AppStoragePaths();

  static const _linuxAppName = 'sharething';
  static const _desktopAppName = 'ShareThing';

  Future<Directory> configDirectory() async {
    final directory = switch (Platform.operatingSystem) {
      'linux' => Directory(p.join(_xdgConfigHome(), _linuxAppName)),
      'windows' => Directory(
        p.join(
          Platform.environment['APPDATA'] ??
              p.join(_userHome(), 'AppData', 'Roaming'),
          _desktopAppName,
        ),
      ),
      'macos' => Directory(
        p.join(
          _userHome(),
          'Library',
          'Application Support',
          _desktopAppName,
          'config',
        ),
      ),
      'android' || 'ios' => Directory(
        p.join((await getApplicationSupportDirectory()).path, 'config'),
      ),
      _ => Directory(p.join(_userHome(), '.sharething', 'config')),
    };

    await directory.create(recursive: true);
    return directory;
  }

  Future<Directory> dataDirectory() async {
    final directory = switch (Platform.operatingSystem) {
      'linux' => Directory(p.join(_xdgDataHome(), _linuxAppName)),
      'windows' => Directory(
        p.join(
          Platform.environment['LOCALAPPDATA'] ??
              p.join(_userHome(), 'AppData', 'Local'),
          _desktopAppName,
        ),
      ),
      'macos' => Directory(
        p.join(
          _userHome(),
          'Library',
          'Application Support',
          _desktopAppName,
          'data',
        ),
      ),
      'android' || 'ios' => Directory(
        p.join((await getApplicationSupportDirectory()).path, 'data'),
      ),
      _ => Directory(p.join(_userHome(), '.sharething', 'data')),
    };

    await directory.create(recursive: true);
    return directory;
  }

  String _userHome() {
    return Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        Directory.current.path;
  }

  String _xdgConfigHome() {
    return Platform.environment['XDG_CONFIG_HOME'] ??
        p.join(_userHome(), '.config');
  }

  String _xdgDataHome() {
    return Platform.environment['XDG_DATA_HOME'] ??
        p.join(_userHome(), '.local', 'share');
  }
}
