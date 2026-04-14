import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'discovered_peer.dart';

abstract class LocalDiscoveryService {
  Stream<List<DiscoveredPeer>> get peers;

  Future<void> start({
    required String peerId,
    required String nickname,
    required String shareAddress,
    required int? fileTransferPort,
    required List<String> capabilities,
  });

  Future<void> stop();
}

class UdpLocalDiscoveryService implements LocalDiscoveryService {
  static const _port = 47189;
  static const _announcementType = 'sharething.lan.v1';
  static const _broadcastInterval = Duration(seconds: 3);
  static const _peerTtl = Duration(seconds: 10);

  final Map<String, DiscoveredPeer> _peers = {};
  final _controller = StreamController<List<DiscoveredPeer>>.broadcast();

  RawDatagramSocket? _socket;
  Timer? _broadcastTimer;
  Timer? _cleanupTimer;
  Map<String, dynamic>? _announcementPayload;
  String? _selfPeerId;

  @override
  Stream<List<DiscoveredPeer>> get peers => _controller.stream;

  @override
  Future<void> start({
    required String peerId,
    required String nickname,
    required String shareAddress,
    required int? fileTransferPort,
    required List<String> capabilities,
  }) async {
    _selfPeerId = peerId;
    _announcementPayload = {
      'type': _announcementType,
      'peerId': peerId,
      'nickname': nickname,
      'shareAddress': shareAddress,
      'fileTransferPort': fileTransferPort,
      'platform': Platform.operatingSystem,
      'capabilities': capabilities,
    };

    if (_socket == null) {
      try {
        final socket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          _port,
          reuseAddress: true,
          reusePort: true,
        );
        socket.broadcastEnabled = true;
        socket.listen(_handleSocketEvent);
        _socket = socket;
      } catch (_) {
        return;
      }

      _broadcastTimer?.cancel();
      _broadcastTimer = Timer.periodic(_broadcastInterval, (_) {
        _sendAnnouncement();
      });

      _cleanupTimer?.cancel();
      _cleanupTimer = Timer.periodic(_broadcastInterval, (_) {
        _cleanupExpiredPeers();
      });
    }

    _sendAnnouncement();
  }

  @override
  Future<void> stop() async {
    _broadcastTimer?.cancel();
    _broadcastTimer = null;
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    _announcementPayload = null;
    _selfPeerId = null;
    _peers.clear();
    _emitPeers();
    _socket?.close();
    _socket = null;
  }

  void _handleSocketEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;

    while (true) {
      final datagram = _socket?.receive();
      if (datagram == null) {
        break;
      }

      try {
        final payload =
            jsonDecode(utf8.decode(datagram.data)) as Map<String, dynamic>;
        if (payload['type'] != _announcementType) {
          continue;
        }

        final peerId = payload['peerId']?.toString();
        if (peerId == null || peerId.isEmpty || peerId == _selfPeerId) {
          continue;
        }

        final nickname = payload['nickname']?.toString().trim();
        final shareAddress = payload['shareAddress']?.toString().trim();
        if (nickname == null ||
            nickname.isEmpty ||
            shareAddress == null ||
            shareAddress.isEmpty) {
          continue;
        }

        final platform = payload['platform']?.toString() ?? 'unknown';
        final fileTransferPort = switch (payload['fileTransferPort']) {
          int value => value,
          String value => int.tryParse(value),
          _ => null,
        };
        final capabilities =
            (payload['capabilities'] as List<dynamic>? ?? const [])
                .map((capability) => capability.toString())
                .toList(growable: false);

        _peers[peerId] = DiscoveredPeer(
          peerId: peerId,
          nickname: nickname,
          shareAddress: shareAddress,
          hostAddress: datagram.address.address,
          fileTransferPort: fileTransferPort,
          platform: platform,
          capabilities: capabilities,
          lastSeen: DateTime.now(),
        );
        _emitPeers();
      } catch (_) {
        continue;
      }
    }
  }

  void _sendAnnouncement() {
    final socket = _socket;
    final payload = _announcementPayload;
    if (socket == null || payload == null) return;

    try {
      final encoded = utf8.encode(jsonEncode(payload));
      socket.send(encoded, InternetAddress('255.255.255.255'), _port);
    } catch (_) {
      // Best effort LAN discovery.
    }
  }

  void _cleanupExpiredPeers() {
    final cutoff = DateTime.now().subtract(_peerTtl);
    _peers.removeWhere((_, peer) => peer.lastSeen.isBefore(cutoff));
    _emitPeers();
  }

  void _emitPeers() {
    if (_controller.isClosed) return;

    final peers = _peers.values.toList(growable: false)
      ..sort((left, right) {
        final nicknameCompare = left.nickname.toLowerCase().compareTo(
          right.nickname.toLowerCase(),
        );
        if (nicknameCompare != 0) {
          return nicknameCompare;
        }
        return left.peerId.compareTo(right.peerId);
      });
    _controller.add(peers);
  }
}
