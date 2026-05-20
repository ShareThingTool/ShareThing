import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/storage/app_storage_paths.dart';
import 'file_transfer_entry.dart';

const _maxHistoryEntries = 200;

abstract class TransferHistoryRepository {
  Future<List<FileTransferEntry>> loadHistory();

  Future<void> saveHistory(List<FileTransferEntry> entries);
}

class JsonTransferHistoryRepository implements TransferHistoryRepository {
  JsonTransferHistoryRepository({AppStoragePaths? storagePaths})
    : _storagePaths = storagePaths ?? const AppStoragePaths();

  final AppStoragePaths _storagePaths;
  final JsonEncoder _encoder = const JsonEncoder.withIndent('  ');

  Future<File> _historyFile() async {
    final directory = await _storagePaths.dataDirectory();
    return File(p.join(directory.path, 'transfer_history.json'));
  }

  @override
  Future<List<FileTransferEntry>> loadHistory() async {
    final file = await _historyFile();
    if (!await file.exists()) return const [];

    try {
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return const [];

      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .map(
            (entry) => FileTransferEntry.fromJson(
              Map<String, dynamic>.from(entry as Map),
            ),
          )
          .where((entry) => entry.id.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> saveHistory(List<FileTransferEntry> entries) async {
    final file = await _historyFile();
    await file.parent.create(recursive: true);
    final capped = entries.length > _maxHistoryEntries
        ? entries.sublist(entries.length - _maxHistoryEntries)
        : entries;
    final payload = capped.map((e) => e.toJson()).toList(growable: false);
    await file.writeAsString(_encoder.convert(payload), flush: true);
  }
}
