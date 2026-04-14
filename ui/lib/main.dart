import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/engine_manager.dart';
import 'features/discovery/discovered_peer.dart';
import 'features/discovery/local_discovery_service.dart';
import 'features/file_transfer/file_transfer_entry.dart';
import 'features/file_transfer/local_file_transfer_service.dart';
import 'features/friends/friend.dart';
import 'features/friends/friends_repository.dart';
import 'features/settings/app_settings.dart';
import 'features/settings/settings_repository.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(ShareThingApp());
}

class ShareThingApp extends StatelessWidget {
  ShareThingApp({
    super.key,
    EngineManager? engine,
    FriendsRepository? friendsRepository,
    SettingsRepository? settingsRepository,
    LocalDiscoveryService? discoveryService,
    LocalFileTransferService? fileTransferService,
  }) : engine = engine ?? EngineManager(),
       friendsRepository = friendsRepository ?? JsonFriendsRepository(),
       settingsRepository = settingsRepository ?? JsonSettingsRepository(),
       discoveryService = discoveryService ?? UdpLocalDiscoveryService(),
       fileTransferService =
           fileTransferService ?? HttpLocalFileTransferService();

  final EngineManager engine;
  final FriendsRepository friendsRepository;
  final SettingsRepository settingsRepository;
  final LocalDiscoveryService discoveryService;
  final LocalFileTransferService fileTransferService;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ShareThing',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey),
        useMaterial3: true,
      ),
      home: MyHomePage(
        engine: engine,
        friendsRepository: friendsRepository,
        settingsRepository: settingsRepository,
        discoveryService: discoveryService,
        fileTransferService: fileTransferService,
      ),
    );
  }
}

enum _FriendPresence { unknown, checking, online, offline }

extension _FriendPresenceUi on _FriendPresence {
  String get label {
    return switch (this) {
      _FriendPresence.unknown => 'Unknown',
      _FriendPresence.checking => 'Checking',
      _FriendPresence.online => 'Online',
      _FriendPresence.offline => 'Offline',
    };
  }

  IconData get icon {
    return switch (this) {
      _FriendPresence.unknown => Icons.help_outline,
      _FriendPresence.checking => Icons.sync,
      _FriendPresence.online => Icons.check_circle_outline,
      _FriendPresence.offline => Icons.cancel_outlined,
    };
  }

  Color color(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return switch (this) {
      _FriendPresence.unknown => colors.secondary,
      _FriendPresence.checking => colors.tertiary,
      _FriendPresence.online => Colors.green,
      _FriendPresence.offline => colors.error,
    };
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({
    super.key,
    required this.engine,
    required this.friendsRepository,
    required this.settingsRepository,
    required this.discoveryService,
    required this.fileTransferService,
  });

  final EngineManager engine;
  final FriendsRepository friendsRepository;
  final SettingsRepository settingsRepository;
  final LocalDiscoveryService discoveryService;
  final LocalFileTransferService fileTransferService;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final TextEditingController _peerController = TextEditingController();
  StreamSubscription<Map<String, dynamic>>? _engineSubscription;
  StreamSubscription<List<DiscoveredPeer>>? _discoverySubscription;
  StreamSubscription<List<FileTransferEntry>>? _transferSubscription;

  List<FriendEntry> _friends = const [];
  List<DiscoveredPeer> _discoveredPeers = const [];
  List<FileTransferEntry> _transfers = const [];
  Map<String, _FriendPresence> _friendStatuses = const {};
  AppSettings _settings = AppSettings.defaults();
  final Set<String> _notifiedCompletedTransfers = {};

  bool _running = false;
  bool _busy = true;
  String _nodeId = 'Unavailable';
  String _shareAddress = 'Unavailable';
  String _localIp = 'Unavailable';
  String? _statusMessage = 'Starting engine...';
  String? _errorMessage;

  String get _displayShareAddress {
    if (_shareAddress == 'Unavailable' || _shareAddress.isEmpty) {
      return _shareAddress;
    }

    if (_localIp == 'Unavailable') {
      return _shareAddress;
    }

    return _shareAddress.replaceFirst('/ip4/0.0.0.0/', '/ip4/$_localIp/');
  }

  @override
  void initState() {
    super.initState();
    _engineSubscription = widget.engine.updates.listen(_handleEngineEvent);
    _discoverySubscription = widget.discoveryService.peers.listen(
      _handleDiscoveredPeers,
    );
    _transferSubscription = widget.fileTransferService.transfers.listen(
      _handleTransfers,
    );
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    _engineSubscription?.cancel();
    _discoverySubscription?.cancel();
    _transferSubscription?.cancel();
    _peerController.dispose();
    unawaited(widget.discoveryService.stop());
    unawaited(widget.fileTransferService.stop());
    unawaited(widget.engine.stop());
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await _loadSettings();
    await _loadFriends();
    unawaited(_loadLocalIp());
    await _startEngine();
  }

  Future<void> _loadSettings() async {
    final settings = await widget.settingsRepository.loadSettings();
    if (!mounted) return;
    setState(() {
      _settings = settings;
    });
  }

  Future<void> _saveSettings(AppSettings settings) async {
    await widget.settingsRepository.saveSettings(settings);
    if (!mounted) return;
    setState(() {
      _settings = settings;
    });
    await _restartDiscovery();
  }

  List<FriendEntry> _sortFriends(List<FriendEntry> friends) {
    final sorted = [...friends]
      ..sort(
        (left, right) =>
            left.nickname.toLowerCase().compareTo(right.nickname.toLowerCase()),
      );
    return sorted;
  }

  Future<void> _loadFriends() async {
    final friends = _sortFriends(await widget.friendsRepository.loadFriends());
    if (!mounted) return;
    setState(() {
      _friends = friends;
      _friendStatuses = {
        for (final friend in friends)
          friend.peerId:
              _friendStatuses[friend.peerId] ?? _FriendPresence.unknown,
      };
    });
  }

  Future<void> _saveFriends(List<FriendEntry> friends) async {
    final sortedFriends = _sortFriends(friends);
    await widget.friendsRepository.saveFriends(sortedFriends);
    if (!mounted) return;
    setState(() {
      _friends = sortedFriends;
      _friendStatuses = {
        for (final friend in sortedFriends)
          friend.peerId:
              _friendStatuses[friend.peerId] ?? _FriendPresence.unknown,
      };
    });
  }

  Future<void> _cacheFriendAddress(String peerId, String shareAddress) async {
    final index = _friends.indexWhere((friend) => friend.peerId == peerId);
    if (index == -1) return;
    if (_friends[index].lastKnownShareAddress == shareAddress) return;

    final updatedFriends = [..._friends];
    updatedFriends[index] = updatedFriends[index].copyWith(
      lastKnownShareAddress: shareAddress,
    );
    await _saveFriends(updatedFriends);
  }

  Future<void> _loadLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list();
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (address.type == InternetAddressType.IPv4 && !address.isLoopback) {
            if (!mounted) return;
            setState(() {
              _localIp = address.address;
            });
            return;
          }
        }
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _localIp = 'Unavailable';
      });
    }
  }

  void _handleEngineEvent(Map<String, dynamic> event) {
    if (!mounted || event['type'] != 'event') return;

    switch (event['event']) {
      case 'node_started':
        setState(() {
          _running = true;
          _statusMessage = 'Engine online';
        });
        break;
      case 'node_stopped':
        setState(() {
          _running = false;
          _busy = false;
          _statusMessage = 'Engine stopped';
          _discoveredPeers = const [];
          _transfers = const [];
          _friendStatuses = {
            for (final friend in _friends)
              friend.peerId: _FriendPresence.unknown,
          };
        });
        unawaited(widget.discoveryService.stop());
        unawaited(widget.fileTransferService.stop());
        break;
      case 'file_received':
        final name = event['filename']?.toString() ?? 'unknown';
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Received file: $name')));
        break;
    }
  }

  void _handleDiscoveredPeers(List<DiscoveredPeer> peers) {
    if (!mounted) return;
    setState(() {
      _discoveredPeers = peers;
    });

    for (final peer in peers) {
      if (_friends.any((friend) => friend.peerId == peer.peerId)) {
        unawaited(_cacheFriendAddress(peer.peerId, peer.shareAddress));
      }
    }
  }

  void _handleTransfers(List<FileTransferEntry> transfers) {
    if (!mounted) return;
    setState(() {
      _transfers = transfers;
    });

    for (final transfer in transfers) {
      if (transfer.direction == FileTransferDirection.incoming &&
          transfer.status == FileTransferStatus.completed &&
          transfer.localPath != null &&
          !_notifiedCompletedTransfers.contains(transfer.id)) {
        _notifiedCompletedTransfers.add(transfer.id);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Received ${transfer.fileName} into ${transfer.localPath}',
            ),
          ),
        );
      }
    }
  }

  void _ensureCommandSucceeded(Map<String, dynamic> response, String command) {
    final error = response['error'];
    if (error is String && error.isNotEmpty) {
      throw StateError('$command failed: $error');
    }

    final data = response['data'];
    if (data is String && data.startsWith('Error:')) {
      throw StateError('$command failed: $data');
    }
  }

  void _setFriendPresence(String peerId, _FriendPresence presence) {
    if (!mounted) return;
    setState(() {
      _friendStatuses = {..._friendStatuses, peerId: presence};
    });
  }

  Future<void> _restartDiscovery() async {
    if (!_running ||
        _nodeId == 'Unavailable' ||
        _nodeId.isEmpty ||
        _shareAddress == 'Unavailable' ||
        _shareAddress.isEmpty) {
      await widget.discoveryService.stop();
      await widget.fileTransferService.stop();
      if (!mounted) return;
      setState(() {
        _discoveredPeers = const [];
        _transfers = const [];
      });
      return;
    }

    await widget.fileTransferService.start(
      peerId: _nodeId,
      nickname: _settings.nickname,
    );

    await widget.discoveryService.start(
      peerId: _nodeId,
      nickname: _settings.nickname,
      shareAddress: _shareAddress,
      fileTransferPort: widget.fileTransferService.listeningPort,
      capabilities: const [
        'tcp-connect',
        'lan-announcement',
        'lan-file-transfer',
      ],
    );
  }

  Future<void> _startEngine() async {
    if (_busy && _running) return;

    setState(() {
      _busy = true;
      _errorMessage = null;
      _statusMessage = 'Starting engine...';
    });

    try {
      await widget.engine.start();
      final id = await widget.engine.sendCommand('get_id');
      final shareAddress = await widget.engine.sendCommand(
        'get_listen_address',
      );
      _ensureCommandSucceeded(id, 'get_id');
      _ensureCommandSucceeded(shareAddress, 'get_listen_address');

      if (!mounted) return;
      setState(() {
        _running = true;
        _nodeId = id['data']?.toString() ?? 'Unavailable';
        _shareAddress = shareAddress['data']?.toString() ?? 'Unavailable';
        _statusMessage = 'Engine online';
      });
      await _restartDiscovery();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _errorMessage = '$error';
        _statusMessage = 'Engine unavailable';
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _stopEngine() async {
    setState(() {
      _busy = true;
      _errorMessage = null;
      _statusMessage = 'Stopping engine...';
    });

    await widget.discoveryService.stop();
    await widget.fileTransferService.stop();
    await widget.engine.stop();

    if (!mounted) return;
    setState(() {
      _busy = false;
      _running = false;
      _nodeId = 'Unavailable';
      _shareAddress = 'Unavailable';
      _statusMessage = 'Engine stopped';
      _discoveredPeers = const [];
      _transfers = const [];
      _friendStatuses = {
        for (final friend in _friends) friend.peerId: _FriendPresence.unknown,
      };
    });
  }

  DiscoveredPeer? _discoveredPeerById(String peerId) {
    for (final peer in _discoveredPeers) {
      if (peer.peerId == peerId) {
        return peer;
      }
    }
    return null;
  }

  String? _resolveFriendAddress(FriendEntry friend) {
    return _discoveredPeerById(friend.peerId)?.shareAddress ??
        friend.lastKnownShareAddress;
  }

  _FriendPresence _presenceForFriend(FriendEntry friend) {
    if (_discoveredPeerById(friend.peerId) != null) {
      return _FriendPresence.online;
    }
    return _friendStatuses[friend.peerId] ?? _FriendPresence.unknown;
  }

  Future<void> _connectToPeer({required String address, String? peerId}) async {
    final trimmedAddress = address.trim();
    if (trimmedAddress.isEmpty) return;

    setState(() {
      _busy = true;
      _errorMessage = null;
      _peerController.text = trimmedAddress;
    });

    if (peerId != null) {
      _setFriendPresence(peerId, _FriendPresence.checking);
    }

    try {
      final response = await widget.engine.sendCommand('connect', {
        'multiaddr': trimmedAddress,
      });
      _ensureCommandSucceeded(response, 'connect');

      if (peerId != null) {
        _setFriendPresence(peerId, _FriendPresence.online);
        await _cacheFriendAddress(peerId, trimmedAddress);
      }

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Connected to $trimmedAddress')));
    } catch (error) {
      if (peerId != null) {
        _setFriendPresence(peerId, _FriendPresence.offline);
      }

      if (!mounted) return;
      setState(() {
        _errorMessage = '$error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _connectToFriend(FriendEntry friend) async {
    final address = _resolveFriendAddress(friend);
    if (address == null || address.isEmpty) {
      setState(() {
        _errorMessage =
            'No active route is known for ${friend.nickname}. Wait for LAN discovery or backend discovery.';
      });
      return;
    }

    await _connectToPeer(address: address, peerId: friend.peerId);
  }

  Future<void> _sendFileToPeer({
    required String peerId,
    required String peerLabel,
    required String hostAddress,
    required int? port,
  }) async {
    if (port == null) {
      setState(() {
        _errorMessage =
            'No local file-sharing route is available for $peerLabel yet.';
      });
      return;
    }

    final filePath = await pickFileForTransfer();
    if (filePath == null || filePath.isEmpty) {
      return;
    }

    setState(() {
      _busy = true;
      _errorMessage = null;
    });

    try {
      await widget.fileTransferService.sendFile(
        peerId: peerId,
        peerLabel: peerLabel,
        hostAddress: hostAddress,
        port: port,
        filePath: filePath,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Sent ${filePath.split(Platform.pathSeparator).last} to $peerLabel',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = '$error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  String? _validateFriend(
    String peerId,
    String nickname, {
    String? editingPeerId,
  }) {
    if (peerId.isEmpty) {
      return 'Peer ID is required.';
    }
    if (nickname.isEmpty) {
      return 'Nickname is required.';
    }

    final duplicatePeerId = _friends.any(
      (friend) => friend.peerId != editingPeerId && friend.peerId == peerId,
    );
    if (duplicatePeerId) {
      return 'Peer ID must be unique in the friend list.';
    }

    return null;
  }

  Future<void> _showFriendEditor({
    FriendEntry? initialFriend,
    DiscoveredPeer? discoveredPeer,
  }) async {
    final peerIdController = TextEditingController(
      text: initialFriend?.peerId ?? discoveredPeer?.peerId ?? '',
    );
    final nicknameController = TextEditingController(
      text: initialFriend?.nickname ?? discoveredPeer?.nickname ?? '',
    );

    FriendEntry? editedFriend;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        String? validationError;

        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(initialFriend == null ? 'Add Friend' : 'Edit Friend'),
              content: SizedBox(
                width: 460,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: peerIdController,
                      decoration: const InputDecoration(
                        labelText: 'Peer ID',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: nicknameController,
                      decoration: const InputDecoration(
                        labelText: 'Nickname',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      discoveredPeer == null
                          ? 'Addresses stay internal. The app will use LAN or backend discovery to find routes.'
                          : 'A LAN-announced route is currently available and will be cached automatically.',
                    ),
                    if (validationError != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        validationError!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () {
                    final peerId = peerIdController.text.trim();
                    final nickname = nicknameController.text.trim();
                    final validationMessage = _validateFriend(
                      peerId,
                      nickname,
                      editingPeerId: initialFriend?.peerId,
                    );
                    if (validationMessage != null) {
                      setDialogState(() {
                        validationError = validationMessage;
                      });
                      return;
                    }

                    editedFriend = FriendEntry(
                      peerId: peerId,
                      nickname: nickname,
                      lastKnownShareAddress:
                          discoveredPeer?.shareAddress ??
                          initialFriend?.lastKnownShareAddress,
                    );
                    Navigator.of(dialogContext).pop();
                  },
                  child: Text(initialFriend == null ? 'Add' : 'Save'),
                ),
              ],
            );
          },
        );
      },
    );

    peerIdController.dispose();
    nicknameController.dispose();

    if (editedFriend == null) return;

    final updatedFriends = [
      for (final friend in _friends)
        if (friend.peerId == editedFriend!.peerId ||
            friend.peerId == initialFriend?.peerId)
          editedFriend!
        else
          friend,
      if (_friends.every((friend) => friend.peerId != editedFriend!.peerId) &&
          initialFriend == null)
        editedFriend!,
    ];

    await _saveFriends(updatedFriends);
  }

  Future<void> _removeFriend(FriendEntry friend) async {
    final shouldDelete =
        await showDialog<bool>(
          context: context,
          builder: (dialogContext) {
            return AlertDialog(
              title: const Text('Remove Friend'),
              content: Text(
                'Remove ${friend.nickname} from the local friend list?',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: const Text('Remove'),
                ),
              ],
            );
          },
        ) ??
        false;

    if (!shouldDelete) return;

    final updatedFriends = _friends
        .where((candidate) => candidate.peerId != friend.peerId)
        .toList(growable: false);
    await _saveFriends(updatedFriends);

    if (!mounted) return;
    setState(() {
      _friendStatuses = {
        for (final candidate in updatedFriends)
          candidate.peerId:
              _friendStatuses[candidate.peerId] ?? _FriendPresence.unknown,
      };
    });
  }

  Future<void> _copyPeerId() async {
    if (_nodeId == 'Unavailable' || _nodeId.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _nodeId));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Peer ID copied')));
  }

  Future<void> _copyShareAddress() async {
    if (_displayShareAddress == 'Unavailable' || _displayShareAddress.isEmpty) {
      return;
    }
    await Clipboard.setData(ClipboardData(text: _displayShareAddress));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Share address copied')));
  }

  Future<void> _showNicknameEditor() async {
    final nicknameController = TextEditingController(text: _settings.nickname);
    String? validationError;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Edit Nickname'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nicknameController,
                      decoration: const InputDecoration(
                        labelText: 'Nickname',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    if (validationError != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        validationError!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () async {
                    final nickname = nicknameController.text.trim();
                    if (nickname.isEmpty) {
                      setDialogState(() {
                        validationError = 'Nickname is required.';
                      });
                      return;
                    }

                    await _saveSettings(_settings.copyWith(nickname: nickname));
                    if (!dialogContext.mounted) return;
                    Navigator.of(dialogContext).pop();
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );

    nicknameController.dispose();
  }

  Widget _buildPresenceChip(BuildContext context, _FriendPresence presence) {
    final color = presence.color(context);

    return Chip(
      avatar: Icon(presence.icon, size: 18, color: color),
      label: Text(presence.label),
      side: BorderSide(color: color.withValues(alpha: 0.35)),
    );
  }

  Widget _buildIdentityCard(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _running ? Icons.dns : Icons.portable_wifi_off,
                  color: _running ? Colors.green : theme.colorScheme.error,
                ),
                const SizedBox(width: 12),
                Text(
                  _running ? 'Node Online' : 'Node Offline',
                  style: theme.textTheme.titleLarge,
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text('Nickname: ${_settings.nickname}'),
            const SizedBox(height: 8),
            SelectableText('Peer ID: $_nodeId'),
            const SizedBox(height: 8),
            SelectableText('Share address: $_displayShareAddress'),
            const SizedBox(height: 8),
            Text('Local IPv4: $_localIp'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.tonalIcon(
                  onPressed: _running ? _copyPeerId : null,
                  icon: const Icon(Icons.badge_outlined),
                  label: const Text('Copy Peer ID'),
                ),
                FilledButton.tonalIcon(
                  onPressed: _running ? _copyShareAddress : null,
                  icon: const Icon(Icons.copy_all_outlined),
                  label: const Text('Copy Share Address'),
                ),
                OutlinedButton.icon(
                  onPressed: _showNicknameEditor,
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Edit Nickname'),
                ),
              ],
            ),
            if (_statusMessage != null) ...[
              const SizedBox(height: 12),
              Text(_statusMessage!),
            ],
            if (_errorMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                _errorMessage!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildFriendCard(BuildContext context, FriendEntry friend) {
    final presence = _presenceForFriend(friend);
    final discoveredPeer = _discoveredPeerById(friend.peerId);
    final hasKnownRoute =
        discoveredPeer != null ||
        (friend.lastKnownShareAddress?.isNotEmpty ?? false);

    return Container(
      key: ValueKey('friend-card-${friend.peerId}'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      friend.nickname,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    SelectableText('Peer ID: ${friend.peerId}'),
                    const SizedBox(height: 8),
                    Text(
                      discoveredPeer != null
                          ? 'LAN route is available right now.'
                          : hasKnownRoute
                          ? 'A cached route is stored locally.'
                          : 'No route is currently known.',
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _buildPresenceChip(context, presence),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                key: ValueKey('friend-connect-${friend.peerId}'),
                onPressed: _busy || !_running
                    ? null
                    : () => _connectToFriend(friend),
                icon: const Icon(Icons.link),
                label: const Text('Connect'),
              ),
              FilledButton.tonalIcon(
                key: ValueKey('friend-send-${friend.peerId}'),
                onPressed:
                    _busy ||
                        !_running ||
                        discoveredPeer == null ||
                        discoveredPeer.fileTransferPort == null
                    ? null
                    : () => _sendFileToPeer(
                        peerId: friend.peerId,
                        peerLabel: friend.nickname,
                        hostAddress: discoveredPeer.hostAddress,
                        port: discoveredPeer.fileTransferPort,
                      ),
                icon: const Icon(Icons.upload_file_outlined),
                label: const Text('Send File'),
              ),
              OutlinedButton.icon(
                key: ValueKey('friend-edit-${friend.peerId}'),
                onPressed: () => _showFriendEditor(initialFriend: friend),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Edit'),
              ),
              OutlinedButton.icon(
                key: ValueKey('friend-delete-${friend.peerId}'),
                onPressed: () => _removeFriend(friend),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Remove'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFriendsCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Friends', style: Theme.of(context).textTheme.titleLarge),
                const Spacer(),
                FilledButton.icon(
                  onPressed: () => _showFriendEditor(),
                  icon: const Icon(Icons.person_add_alt_1),
                  label: const Text('Add Friend'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              'Friends are keyed by peer ID. Share addresses stay internal and are learned from LAN or backend discovery.',
            ),
            const SizedBox(height: 16),
            if (_friends.isEmpty)
              const Text('No friends saved yet.')
            else
              Column(
                children: [
                  for (var index = 0; index < _friends.length; index++) ...[
                    _buildFriendCard(context, _friends[index]),
                    if (index < _friends.length - 1) const SizedBox(height: 12),
                  ],
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildDiscoveredPeerCard(BuildContext context, DiscoveredPeer peer) {
    final isSaved = _friends.any((friend) => friend.peerId == peer.peerId);

    return Container(
      key: ValueKey('discovered-peer-${peer.peerId}'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      peer.nickname,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    SelectableText('Peer ID: ${peer.peerId}'),
                    const SizedBox(height: 8),
                    Text('Platform: ${peer.platform}'),
                    if (peer.capabilities.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text('Capabilities: ${peer.capabilities.join(', ')}'),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _buildPresenceChip(context, _FriendPresence.online),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                key: ValueKey('discovered-connect-${peer.peerId}'),
                onPressed: _busy || !_running
                    ? null
                    : () => _connectToPeer(
                        address: peer.shareAddress,
                        peerId: peer.peerId,
                      ),
                icon: const Icon(Icons.link),
                label: const Text('Connect'),
              ),
              FilledButton.tonalIcon(
                key: ValueKey('discovered-send-${peer.peerId}'),
                onPressed: _busy || !_running || peer.fileTransferPort == null
                    ? null
                    : () => _sendFileToPeer(
                        peerId: peer.peerId,
                        peerLabel: peer.nickname,
                        hostAddress: peer.hostAddress,
                        port: peer.fileTransferPort,
                      ),
                icon: const Icon(Icons.upload_file_outlined),
                label: const Text('Send File'),
              ),
              if (!isSaved)
                OutlinedButton.icon(
                  key: ValueKey('discovered-add-${peer.peerId}'),
                  onPressed: () => _showFriendEditor(discoveredPeer: peer),
                  icon: const Icon(Icons.person_add_alt_1),
                  label: const Text('Add Friend'),
                )
              else
                OutlinedButton.icon(
                  onPressed: null,
                  icon: const Icon(Icons.check),
                  label: const Text('Saved'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDiscoveryCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Local Discovery',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            const Text(
              'Nearby ShareThing clients announce their peer ID, nickname, and supported route on the local network.',
            ),
            const SizedBox(height: 16),
            if (!_running)
              const Text('Start the engine to announce and discover LAN peers.')
            else if (_discoveredPeers.isEmpty)
              const Text('No LAN peers discovered yet.')
            else
              Column(
                children: [
                  for (
                    var index = 0;
                    index < _discoveredPeers.length;
                    index++
                  ) ...[
                    _buildDiscoveredPeerCard(context, _discoveredPeers[index]),
                    if (index < _discoveredPeers.length - 1)
                      const SizedBox(height: 12),
                  ],
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildManualConnectCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Advanced Connect',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            const Text(
              'Use raw share addresses only as a fallback. Normal friend management should be peer ID based.',
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('manual-peer-field'),
              controller: _peerController,
              minLines: 2,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Peer multiaddr',
                hintText: '/ip4/192.168.1.20/tcp/4101/p2p/...',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              key: const ValueKey('manual-connect-button'),
              onPressed: _busy || !_running
                  ? null
                  : () => _connectToPeer(address: _peerController.text),
              child: const Text('Connect'),
            ),
            const SizedBox(height: 12),
            const Text(
              'LAN file transfer uses discovered peers. Manual raw-address mode currently covers direct connect only.',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTransfersCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Transfers', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            const Text(
              'Local LAN file sharing currently uses a direct app-managed transfer path across desktop and Android.',
            ),
            const SizedBox(height: 16),
            if (_transfers.isEmpty)
              const Text('No transfers yet.')
            else
              Column(
                children: [
                  for (var index = 0; index < _transfers.length; index++) ...[
                    _buildTransferTile(context, _transfers[index]),
                    if (index < _transfers.length - 1)
                      const SizedBox(height: 12),
                  ],
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildTransferTile(BuildContext context, FileTransferEntry transfer) {
    final statusLabel = switch (transfer.status) {
      FileTransferStatus.queued => 'Queued',
      FileTransferStatus.inProgress => 'In Progress',
      FileTransferStatus.completed => 'Completed',
      FileTransferStatus.failed => 'Failed',
    };

    final directionLabel = switch (transfer.direction) {
      FileTransferDirection.incoming => 'Incoming',
      FileTransferDirection.outgoing => 'Outgoing',
    };

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            transfer.fileName,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text('$directionLabel with ${transfer.peerLabel}'),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: transfer.progress),
          const SizedBox(height: 8),
          Text(
            '$statusLabel • ${transfer.bytesTransferred}/${transfer.totalBytes} bytes',
          ),
          if (transfer.localPath != null) ...[
            const SizedBox(height: 8),
            SelectableText('Path: ${transfer.localPath}'),
          ],
          if (transfer.error != null) ...[
            const SizedBox(height: 8),
            Text(
              transfer.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ShareThing')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _buildIdentityCard(context),
            const SizedBox(height: 16),
            _buildFriendsCard(context),
            const SizedBox(height: 16),
            _buildDiscoveryCard(context),
            const SizedBox(height: 16),
            _buildTransfersCard(context),
            const SizedBox(height: 16),
            _buildManualConnectCard(context),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : (_running ? _stopEngine : _startEngine),
        label: Text(_running ? 'Stop Engine' : 'Start Engine'),
        icon: Icon(_running ? Icons.stop : Icons.play_arrow),
      ),
    );
  }
}
