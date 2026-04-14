class IncomingFileRequest {
  const IncomingFileRequest({
    required this.transferId,
    required this.peerId,
    required this.fileName,
    required this.totalBytes,
  });

  final String transferId;
  final String peerId;
  final String fileName;
  final int totalBytes;
}
