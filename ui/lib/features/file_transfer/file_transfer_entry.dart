enum FileTransferDirection { incoming, outgoing }

enum FileTransferStatus { queued, inProgress, completed, failed }

class FileTransferEntry {
  const FileTransferEntry({
    required this.id,
    required this.direction,
    required this.peerId,
    required this.peerLabel,
    required this.fileName,
    required this.bytesTransferred,
    required this.totalBytes,
    required this.status,
    this.localPath,
    this.error,
  });

  final String id;
  final FileTransferDirection direction;
  final String peerId;
  final String peerLabel;
  final String fileName;
  final int bytesTransferred;
  final int totalBytes;
  final FileTransferStatus status;
  final String? localPath;
  final String? error;

  double get progress {
    if (totalBytes <= 0) {
      return status == FileTransferStatus.completed ? 1 : 0;
    }
    return bytesTransferred / totalBytes;
  }

  FileTransferEntry copyWith({
    String? id,
    FileTransferDirection? direction,
    String? peerId,
    String? peerLabel,
    String? fileName,
    int? bytesTransferred,
    int? totalBytes,
    FileTransferStatus? status,
    String? localPath,
    String? error,
  }) {
    return FileTransferEntry(
      id: id ?? this.id,
      direction: direction ?? this.direction,
      peerId: peerId ?? this.peerId,
      peerLabel: peerLabel ?? this.peerLabel,
      fileName: fileName ?? this.fileName,
      bytesTransferred: bytesTransferred ?? this.bytesTransferred,
      totalBytes: totalBytes ?? this.totalBytes,
      status: status ?? this.status,
      localPath: localPath ?? this.localPath,
      error: error ?? this.error,
    );
  }
}
