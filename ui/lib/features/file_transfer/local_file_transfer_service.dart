import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

import '../../core/storage/app_storage_paths.dart';
import 'file_transfer_entry.dart';

abstract class LocalFileTransferService {
  Stream<List<FileTransferEntry>> get transfers;

  int? get listeningPort;

  Future<void> start({required String peerId, required String nickname});

  Future<void> stop();

  Future<void> sendFile({
    required String peerId,
    required String peerLabel,
    required String hostAddress,
    required int port,
    required String filePath,
  });
}

class HttpLocalFileTransferService implements LocalFileTransferService {
  HttpLocalFileTransferService({AppStoragePaths? storagePaths})
    : _storagePaths = storagePaths ?? const AppStoragePaths();

  static const _defaultPort = 47290;

  final AppStoragePaths _storagePaths;
  final _controller = StreamController<List<FileTransferEntry>>.broadcast();
  final Map<String, FileTransferEntry> _transfers = {};

  HttpServer? _server;
  String? _selfPeerId;
  String? _selfNickname;

  @override
  Stream<List<FileTransferEntry>> get transfers => _controller.stream;

  @override
  int? get listeningPort => _server?.port;

  @override
  Future<void> start({required String peerId, required String nickname}) async {
    _selfPeerId = peerId;
    _selfNickname = nickname;
    if (_server != null) {
      return;
    }

    final candidatePorts = <int>[_defaultPort, 0];
    for (final port in candidatePorts) {
      try {
        final server = await HttpServer.bind(
          InternetAddress.anyIPv4,
          port,
          shared: true,
        );
        _server = server;
        server.listen(_handleRequest);
        return;
      } catch (_) {
        continue;
      }
    }
  }

  @override
  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  @override
  Future<void> sendFile({
    required String peerId,
    required String peerLabel,
    required String hostAddress,
    required int port,
    required String filePath,
  }) async {
    final file = File(filePath);
    final fileName = p.basename(file.path);
    final totalBytes = await file.length();
    final transferId = DateTime.now().microsecondsSinceEpoch.toString();

    _updateTransfer(
      FileTransferEntry(
        id: transferId,
        direction: FileTransferDirection.outgoing,
        peerId: peerId,
        peerLabel: peerLabel,
        fileName: fileName,
        bytesTransferred: 0,
        totalBytes: totalBytes,
        status: FileTransferStatus.queued,
        localPath: file.path,
      ),
    );

    final client = HttpClient();
    try {
      final uri = Uri.parse('http://$hostAddress:$port/v1/files');
      final request = await client.postUrl(uri);
      request.headers.set('x-sharething-peer-id', _selfPeerId ?? '');
      request.headers.set('x-sharething-nickname', _selfNickname ?? '');
      request.headers.set('x-sharething-filename', fileName);
      request.headers.set('x-sharething-filesize', totalBytes.toString());
      request.contentLength = totalBytes;

      _updateTransfer(
        _transfers[transferId]!.copyWith(status: FileTransferStatus.inProgress),
      );

      var sent = 0;
      await for (final chunk in file.openRead()) {
        request.add(chunk);
        sent += chunk.length;
        _updateTransfer(
          _transfers[transferId]!.copyWith(
            bytesTransferred: sent,
            status: FileTransferStatus.inProgress,
          ),
        );
      }

      final response = await request.close();
      final responseBody = await utf8.decoder.bind(response).join();
      if (response.statusCode >= 400) {
        throw HttpException(
          'Receiver returned ${response.statusCode}: $responseBody',
          uri: uri,
        );
      }

      _updateTransfer(
        _transfers[transferId]!.copyWith(
          bytesTransferred: totalBytes,
          status: FileTransferStatus.completed,
        ),
      );
    } catch (error) {
      _updateTransfer(
        _transfers[transferId]!.copyWith(
          status: FileTransferStatus.failed,
          error: '$error',
        ),
      );
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (request.method != 'POST' || request.uri.path != '/v1/files') {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    final fileName =
        request.headers.value('x-sharething-filename') ?? 'received.bin';
    final peerId =
        request.headers.value('x-sharething-peer-id') ?? 'unknown-peer';
    final peerLabel = request.headers.value('x-sharething-nickname') ?? peerId;
    final totalBytes =
        int.tryParse(request.headers.value('x-sharething-filesize') ?? '') ?? 0;
    final transferId = DateTime.now().microsecondsSinceEpoch.toString();

    final receivedDirectory = await _storagePaths.receivedFilesDirectory();
    final safeFileName = _safeFileName(fileName);
    final destination = await _nextAvailableDestination(
      receivedDirectory,
      safeFileName,
    );
    final sink = destination.openWrite();

    _updateTransfer(
      FileTransferEntry(
        id: transferId,
        direction: FileTransferDirection.incoming,
        peerId: peerId,
        peerLabel: peerLabel,
        fileName: safeFileName,
        bytesTransferred: 0,
        totalBytes: totalBytes,
        status: FileTransferStatus.inProgress,
        localPath: destination.path,
      ),
    );

    var received = 0;
    try {
      await for (final chunk in request) {
        sink.add(chunk);
        received += chunk.length;
        _updateTransfer(
          _transfers[transferId]!.copyWith(
            bytesTransferred: received,
            status: FileTransferStatus.inProgress,
          ),
        );
      }

      await sink.flush();
      await sink.close();

      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({'status': 'ok', 'path': destination.path}),
      );
      await request.response.close();

      _updateTransfer(
        _transfers[transferId]!.copyWith(
          bytesTransferred: received,
          status: FileTransferStatus.completed,
        ),
      );
    } catch (error) {
      await sink.close();
      if (await destination.exists()) {
        await destination.delete();
      }
      _updateTransfer(
        _transfers[transferId]!.copyWith(
          status: FileTransferStatus.failed,
          error: '$error',
        ),
      );
      request.response.statusCode = HttpStatus.internalServerError;
      await request.response.close();
    }
  }

  Future<File> _nextAvailableDestination(
    Directory directory,
    String fileName,
  ) async {
    final baseName = p.basenameWithoutExtension(fileName);
    final extension = p.extension(fileName);
    var candidate = File(p.join(directory.path, fileName));
    var counter = 1;

    while (await candidate.exists()) {
      candidate = File(p.join(directory.path, '$baseName-$counter$extension'));
      counter++;
    }

    return candidate;
  }

  String _safeFileName(String name) {
    final cleaned = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return cleaned.isEmpty ? 'received.bin' : cleaned;
  }

  void _updateTransfer(FileTransferEntry transfer) {
    _transfers[transfer.id] = transfer;
    if (_controller.isClosed) {
      return;
    }
    final ordered = _transfers.values.toList(growable: false)
      ..sort((left, right) => right.id.compareTo(left.id));
    _controller.add(ordered);
  }
}

Future<String?> pickFileForTransfer() async {
  final result = await FilePicker.platform.pickFiles();
  if (result == null || result.files.isEmpty) {
    return null;
  }
  return result.files.single.path;
}
