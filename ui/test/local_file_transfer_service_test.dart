import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharething/core/storage/app_storage_paths.dart';
import 'package:sharething/features/file_transfer/file_transfer_entry.dart';
import 'package:sharething/features/file_transfer/local_file_transfer_service.dart';

class FakeStoragePaths extends AppStoragePaths {
  FakeStoragePaths(this._configDirectory, this._dataDirectory);

  final Directory _configDirectory;
  final Directory _dataDirectory;

  @override
  Future<Directory> configDirectory() async {
    await _configDirectory.create(recursive: true);
    return _configDirectory;
  }

  @override
  Future<Directory> dataDirectory() async {
    await _dataDirectory.create(recursive: true);
    return _dataDirectory;
  }
}

void main() {
  test('local file transfer service sends and receives a file', () async {
    final senderRoot = await Directory.systemTemp.createTemp(
      'sharething-sender',
    );
    final receiverRoot = await Directory.systemTemp.createTemp(
      'sharething-receiver',
    );
    addTearDown(() => senderRoot.delete(recursive: true));
    addTearDown(() => receiverRoot.delete(recursive: true));

    final senderService = HttpLocalFileTransferService(
      storagePaths: FakeStoragePaths(
        Directory('${senderRoot.path}/config'),
        Directory('${senderRoot.path}/data'),
      ),
    );
    final receiverService = HttpLocalFileTransferService(
      storagePaths: FakeStoragePaths(
        Directory('${receiverRoot.path}/config'),
        Directory('${receiverRoot.path}/data'),
      ),
    );
    addTearDown(senderService.stop);
    addTearDown(receiverService.stop);

    final completedIncoming = Completer<FileTransferEntry>();
    final subscription = receiverService.transfers.listen((transfers) {
      for (final transfer in transfers) {
        if (transfer.direction == FileTransferDirection.incoming &&
            transfer.status == FileTransferStatus.completed &&
            !completedIncoming.isCompleted) {
          completedIncoming.complete(transfer);
        }
      }
    });
    addTearDown(subscription.cancel);

    await receiverService.start(peerId: 'receiver-peer', nickname: 'Receiver');

    final sourceFile = File('${senderRoot.path}/hello.txt');
    await sourceFile.writeAsString('hello sharething');

    await senderService.sendFile(
      peerId: 'receiver-peer',
      peerLabel: 'Receiver',
      hostAddress: '127.0.0.1',
      port: receiverService.listeningPort!,
      filePath: sourceFile.path,
    );

    final incoming = await completedIncoming.future.timeout(
      const Duration(seconds: 5),
    );
    final receivedFile = File(incoming.localPath!);

    expect(await receivedFile.exists(), isTrue);
    expect(await receivedFile.readAsString(), 'hello sharething');
  });
}
