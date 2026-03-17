import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:http/http.dart' as http; 
import 'package:archive/archive_io.dart'; 

void main(List<String> args) async {
  final target = args.isNotEmpty ? args[0] : 'linux-x64';
  final platform = target.split('-')[0];
  final arch = target.contains('-') ? target.split('-')[1] : 'x64';

  print("\nStarting Build Pipeline for: $target");
  print("------------------------------------------");

  final gradleCmd = await resolveGradle("engine");
  await run("Building Engine", gradleCmd, ["lib:syncDesktopJar"], dir: "engine");

  final flutterContext = await resolveFlutter("ui");

  List<String> buildArgs = [];
  
  if (flutterContext.args.contains("flutter")) {
    buildArgs.add("flutter");
  }

  buildArgs.addAll(["build", platform]);


  buildArgs.add("--release");

  await run("Building Flutter UI", flutterContext.executable, buildArgs, dir: "ui");
  await injectJRE(target);
  

  print("\n------------------------------------------");
  print("Build Complete!");
  print("Find your app in: ui/build/$platform/$arch/release/bundle\n");
}

class ToolContext {
  final String executable;
  final List<String> args;
  ToolContext(this.executable, this.args);
}

Future<ToolContext> resolveFlutter(String uiDir) async {
    final fvmPath = await _which('fvm');
    if (fvmPath != null) {
      print("FVM detected. Using: $fvmPath");
      return ToolContext(fvmPath, ["flutter"]);
    }

  final flutterPath = await _which('flutter');
  if (flutterPath != null) {
    print("Flutter detected. Using: $flutterPath");
    return ToolContext(flutterPath, []);
  }

  print("Error: Neither 'fvm' nor 'flutter' found in PATH.");
  exit(1);
}

Future<String> resolveGradle(String engineDir) async {
  final wrapperName = Platform.isWindows ? "gradlew.bat" : "gradlew";
  final wrapper = File(p.join(engineDir, wrapperName));

  if (await wrapper.exists()) {
    print("Local Gradle wrapper detected.");
    //Unix stuff
    if (!Platform.isWindows) await Process.run('chmod', ['+x', wrapper.path]);
    return p.absolute(wrapper.path);
  }

  final systemGradle = await _which('gradle');
  if (systemGradle != null) {
    print("Wrapper not found. Using system 'gradle'.");
    return systemGradle;
  }

  print("Error: Gradle not found.");
  exit(1);
}

Future<String?> _which(String command) async {
  final checkCmd = Platform.isWindows ? 'where' : 'which';
  try {
    final result = await Process.run(checkCmd, [command]);
    if (result.exitCode == 0) {
      return result.stdout.toString().trim().split('\n').first;
    }
  } catch (_) {}
  return null;
}

/// Generic process runner
Future<void> run(String label, String cmd, List<String> args, {String? dir}) async {
  print("\n$label...");
  
  final proc = await Process.start(
    cmd, 
    args, 
    workingDirectory: dir, 
    runInShell: true,
    environment: Platform.environment, 
  );
  
  stdout.addStream(proc.stdout);
  stderr.addStream(proc.stderr);

  final exitCode = await proc.exitCode;
  if (exitCode != 0) {
    print("\n$label failed with code $exitCode!");
    exit(1);
  }
}

Future<void> injectJRE(String target) async {
  final parts = target.split('-');
  final platform = parts[0];
  final arch = parts.length > 1 ? parts[1] : 'x64';
  
  final bundlePath = p.join("ui", "build", platform, arch, "release", "bundle");
  final jreSource = Directory(p.join("vendor", "jres", target));
  
  final jreDest = Directory(p.join(bundlePath, "data", "flutter_assets", "assets", "jre"));
  await jreDest.create(recursive: true);
  await ensureJreExists(target);

  if (await jreSource.exists()) {
    print("\nInjecting JRE for $target...");
    if (await jreDest.exists()) await jreDest.delete(recursive: true);
    await _copyDirectory(jreSource, jreDest);
    
    if (!Platform.isWindows) {
      final javaBin = p.join(jreDest.path, 'bin', 'java');
      await Process.run('chmod', ['+x', javaBin]);
    }
    print("JRE injected successfully.");
  } else {
    print("\nSkip JRE Injection: No source found at ${jreSource.path}");
  }
}

Future<void> ensureJreExists(String target) async {
  final jreDir = Directory(p.join("vendor", "jres", target));
  if(await jreDir.exists()) return;
  await jreDir.create(recursive: true);


  print("JRE for $target not found. Downloading from Adoptium...");
  
  final parts = target.split('-');
  final os = parts[0]; // linux, windows, macos
  final arch = parts[1] == 'x64' ? 'x64' : 'aarch64'; 
  
  final url = "https://api.adoptium.net/v3/binary/latest/21/ga/$os/$arch/jre/hotspot/normal/eclipse";
  
  final response = await http.get(Uri.parse(url));
  if (response.statusCode != 200) {
    print("Failed to download JRE: ${response.statusCode}");
    exit(1);
  }

  final tempFile = File(p.join("vendor", "temp_jre.tar.gz"));
  await tempFile.parent.create(recursive: true);
  await tempFile.writeAsBytes(response.bodyBytes);
  print("Extracting JRE...");
  if (os == 'windows') {
    final bytes = await tempFile.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    extractArchiveToDisk(archive, jreDir.path);
  } else {
    await Process.run('tar', ['-xzf', tempFile.path, '-C', jreDir.path, '--strip-components=1']);
  }

  await tempFile.delete();
  print("JRE prepared at ${jreDir.path}");
}

Future<void> _copyDirectory(Directory source, Directory destination) async {
  await destination.create(recursive: true);
  await for (var entity in source.list(recursive: false)) {
    final newPath = p.join(destination.path, p.basename(entity.path));
    if (entity is Directory) {
      await _copyDirectory(entity, Directory(newPath));
    } else if (entity is File) {
      await entity.copy(newPath);
    }
  }
}
