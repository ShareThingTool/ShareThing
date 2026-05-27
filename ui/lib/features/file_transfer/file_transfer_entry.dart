import 'virustotal_service.dart';

export 'virustotal_service.dart' show VtScanResult, VtScanStatus;

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
    this.startedAt,
    this.completedAt,
    this.vtScanResult,
    this.blake3Hash,
    this.textContent,
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
  final DateTime? startedAt;
  final DateTime? completedAt;
  final VtScanResult? vtScanResult;
  final String? blake3Hash;
  final String? textContent;

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
    DateTime? startedAt,
    DateTime? completedAt,
    VtScanResult? vtScanResult,
    String? blake3Hash,
    String? textContent,
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
      startedAt: startedAt ?? this.startedAt,
      completedAt: completedAt ?? this.completedAt,
      vtScanResult: vtScanResult ?? this.vtScanResult,
      blake3Hash: blake3Hash ?? this.blake3Hash,
      textContent: textContent ?? this.textContent,
    );
  }

  factory FileTransferEntry.fromJson(Map<String, dynamic> json) {
    final direction = json['direction']?.toString() == 'incoming'
        ? FileTransferDirection.incoming
        : FileTransferDirection.outgoing;
    final status = switch (json['status']?.toString()) {
      'inProgress' => FileTransferStatus.inProgress,
      'completed' => FileTransferStatus.completed,
      'failed' => FileTransferStatus.failed,
      _ => FileTransferStatus.queued,
    };
    return FileTransferEntry(
      id: json['id']?.toString() ?? '',
      direction: direction,
      peerId: json['peerId']?.toString() ?? '',
      peerLabel: json['peerLabel']?.toString() ?? '',
      fileName: json['fileName']?.toString() ?? '',
      bytesTransferred: (json['bytesTransferred'] as num?)?.toInt() ?? 0,
      totalBytes: (json['totalBytes'] as num?)?.toInt() ?? 0,
      status: status,
      localPath: json['localPath']?.toString(),
      error: json['error']?.toString(),
      startedAt: json['startedAt'] != null
          ? DateTime.tryParse(json['startedAt'].toString())
          : null,
      completedAt: json['completedAt'] != null
          ? DateTime.tryParse(json['completedAt'].toString())
          : null,
      vtScanResult: json['vtScanResult'] != null
          ? VtScanResult.fromJson(
              Map<String, dynamic>.from(json['vtScanResult'] as Map),
            )
          : null,
      blake3Hash: json['blake3Hash']?.toString(),
      textContent: json['textContent']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'direction': direction.name,
      'peerId': peerId,
      'peerLabel': peerLabel,
      'fileName': fileName,
      'bytesTransferred': bytesTransferred,
      'totalBytes': totalBytes,
      'status': status.name,
      if (localPath != null) 'localPath': localPath,
      if (error != null) 'error': error,
      if (startedAt != null) 'startedAt': startedAt!.toIso8601String(),
      if (completedAt != null) 'completedAt': completedAt!.toIso8601String(),
      if (vtScanResult != null &&
          vtScanResult!.status != VtScanStatus.scanning)
        'vtScanResult': vtScanResult!.toJson(),
      if (blake3Hash != null) 'blake3Hash': blake3Hash,
      if (textContent != null) 'textContent': textContent,
    };
  }
}
