import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/app_logger.dart';
import 'core/engine_manager.dart';
import 'core/storage/app_storage_paths.dart';
import 'features/discovery/discovered_peer.dart';
import 'features/file_transfer/file_transfer_entry.dart';
import 'features/file_transfer/incoming_file_request.dart';
import 'features/file_transfer/transfer_history_repository.dart';
import 'features/friends/friend.dart';
import 'features/friends/friends_repository.dart';
import 'features/settings/app_settings.dart';
import 'features/settings/settings_repository.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(ShareThingApp());
}

class ShareThingApp extends StatefulWidget {
  ShareThingApp({
    super.key,
    EngineManager? engine,
    FriendsRepository? friendsRepository,
    SettingsRepository? settingsRepository,
    TransferHistoryRepository? transferHistoryRepository,
    AppStoragePaths? storagePaths,
  }) : engine = engine ?? EngineManager(),
       friendsRepository = friendsRepository ?? JsonFriendsRepository(),
       settingsRepository = settingsRepository ?? JsonSettingsRepository(),
       transferHistoryRepository =
           transferHistoryRepository ?? JsonTransferHistoryRepository(),
       storagePaths = storagePaths ?? const AppStoragePaths();

  final EngineManager engine;
  final FriendsRepository friendsRepository;
  final SettingsRepository settingsRepository;
  final TransferHistoryRepository transferHistoryRepository;
  final AppStoragePaths storagePaths;

  @override
  State<ShareThingApp> createState() => _ShareThingAppState();
}

class _ShareThingAppState extends State<ShareThingApp> {
  AppLifecycleListener? _appLifecycleListener;
  StreamSubscription<ProcessSignal>? _sigtermSubscription;
  StreamSubscription<ProcessSignal>? _sigintSubscription;
  bool _shuttingDown = false;

  @override
  void initState() {
    super.initState();
    _appLifecycleListener = AppLifecycleListener(
      onExitRequested: () async {
        await _shutdownNode();
        return AppExitResponse.exit;
      },
    );

    if (Platform.isLinux || Platform.isMacOS) {
      _sigtermSubscription = ProcessSignal.sigterm.watch().listen((_) {
        unawaited(_handleTerminationSignal());
      });
      _sigintSubscription = ProcessSignal.sigint.watch().listen((_) {
        unawaited(_handleTerminationSignal());
      });
    }
  }

  @override
  void dispose() {
    _appLifecycleListener?.dispose();
    _sigtermSubscription?.cancel();
    _sigintSubscription?.cancel();
    unawaited(_shutdownNode());
    super.dispose();
  }

  Future<void> _handleTerminationSignal() async {
    await _shutdownNode();
    exit(0);
  }

  Future<void> _shutdownNode() async {
    if (_shuttingDown) return;
    _shuttingDown = true;
    try {
      await widget.engine.stop();
    } finally {
      _shuttingDown = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ShareThing',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey),
        useMaterial3: true,
      ),
      home: MyHomePage(
        engine: widget.engine,
        friendsRepository: widget.friendsRepository,
        settingsRepository: widget.settingsRepository,
        transferHistoryRepository: widget.transferHistoryRepository,
        storagePaths: widget.storagePaths,
      ),
    );
  }
}

enum _FriendPresence { unknown, offline, online }

extension _FriendPresenceUi on _FriendPresence {
  String get label {
    return switch (this) {
      _FriendPresence.unknown => 'Unknown',
      _FriendPresence.offline => 'Offline',
      _FriendPresence.online => 'Online',
    };
  }

  IconData get icon {
    return switch (this) {
      _FriendPresence.unknown => Icons.help_outline,
      _FriendPresence.offline => Icons.portable_wifi_off_outlined,
      _FriendPresence.online => Icons.check_circle_outline,
    };
  }

  Color color(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return switch (this) {
      _FriendPresence.unknown => colors.secondary,
      _FriendPresence.offline => colors.error,
      _FriendPresence.online => Colors.green,
    };
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({
    super.key,
    required this.engine,
    required this.friendsRepository,
    required this.settingsRepository,
    required this.transferHistoryRepository,
    required this.storagePaths,
  });

  final EngineManager engine;
  final FriendsRepository friendsRepository;
  final SettingsRepository settingsRepository;
  final TransferHistoryRepository transferHistoryRepository;
  final AppStoragePaths storagePaths;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  StreamSubscription<Map<String, dynamic>>? _engineSubscription;

  List<FriendEntry> _friends = const [];
  Map<String, DiscoveredPeer> _discoveredPeers = const {};
  Map<String, _FriendPresence> _peerPresence = const {};
  Map<String, FileTransferEntry> _transfers = const {};
  Map<String, IncomingFileRequest> _incomingRequests = const {};
  final Map<String, String> _pendingSavePaths = {};
  AppSettings _settings = AppSettings.defaults();

  bool _running = false;
  bool _busy = true;
  String _peerId = 'Unavailable';
  List<String> _listenAddresses = const [];
  String? _statusMessage = 'Starting node...';
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _engineSubscription = widget.engine.updates.listen(_handleEngineEvent);
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    _engineSubscription?.cancel();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await _loadSettings();
    await _loadFriends();
    await _loadTransferHistory();
    await _startEngine();
  }

  Future<void> _loadTransferHistory() async {
    final history = await widget.transferHistoryRepository.loadHistory();
    if (!mounted) return;
    setState(() {
      _transfers = {for (final e in history) e.id: e};
    });
  }

  Future<void> _saveTransferHistory() async {
    final entries = _transfers.values.toList(growable: false)
      ..sort((a, b) {
        final aTime = a.startedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bTime = b.startedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return aTime.compareTo(bTime);
      });
    await widget.transferHistoryRepository.saveHistory(entries);
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

    if (_running) {
      await _restartEngine();
    }
  }

  Future<void> _loadFriends() async {
    final friends = await widget.friendsRepository.loadFriends();
    if (!mounted) return;
    setState(() {
      _friends = _sortFriends(friends);
    });
  }

  Future<void> _saveFriends(List<FriendEntry> friends) async {
    final sorted = _sortFriends(friends);
    await widget.friendsRepository.saveFriends(sorted);
    if (!mounted) return;
    setState(() {
      _friends = sorted;
    });
  }

  List<FriendEntry> _sortFriends(List<FriendEntry> friends) {
    final sorted = [...friends]
      ..sort(
        (left, right) =>
            left.nickname.toLowerCase().compareTo(right.nickname.toLowerCase()),
      );
    return sorted;
  }

  Future<void> _startEngine() async {
    appLogger.i('ui.startEngine nickname=${_settings.nickname}');
    setState(() {
      _busy = true;
      _errorMessage = null;
      _statusMessage = 'Starting node...';
    });

    try {
      await widget.engine.start(
        nickname: _settings.nickname,
        discoveryServers: const [],
      );

      if (!mounted) return;
      setState(() {
        _busy = false;
      });
    } catch (error) {
      appLogger.e('ui.startEngine.failed', error: error);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _running = false;
        _statusMessage = 'Node unavailable';
        _errorMessage = '$error';
      });
    }
  }

  Future<void> _restartEngine() async {
    await widget.engine.stop();
    if (!mounted) return;
    setState(() {
      _running = false;
      _peerId = 'Unavailable';
      _listenAddresses = const [];
      _discoveredPeers = const {};
      _peerPresence = const {};
      _incomingRequests = const {};
    });
    await _startEngine();
  }

  Future<void> _stopEngine() async {
    appLogger.i('ui.stopEngine');
    setState(() {
      _busy = true;
      _errorMessage = null;
      _statusMessage = 'Stopping node...';
    });

    await widget.engine.stop();

    if (!mounted) return;
    setState(() {
      _busy = false;
      _running = false;
      _peerId = 'Unavailable';
      _listenAddresses = const [];
      _statusMessage = 'Node stopped';
      _discoveredPeers = const {};
      _peerPresence = const {};
      _incomingRequests = const {};
    });
  }

  void _handleEngineEvent(Map<String, dynamic> event) {
    appLogger.d('ui.engineEvent $event');
    switch (event['type']) {
      case 'NODE_STARTED':
        final listenAddresses =
            (event['listenAddresses'] as List<dynamic>? ?? const [])
                .map((address) => address.toString())
                .toList(growable: false);
        setState(() {
          _running = true;
          _peerId = event['peerId']?.toString() ?? 'Unavailable';
          _listenAddresses = listenAddresses;
          _statusMessage = 'Node online';
        });
        break;
      case 'NODE_STOPPED':
        final offlinePresence = <String, _FriendPresence>{
          for (final peerId in _discoveredPeers.keys)
            peerId: _FriendPresence.offline,
        };
        setState(() {
          _running = false;
          _statusMessage = 'Node stopped';
          _peerPresence = {..._peerPresence, ...offlinePresence};
        });
        break;
      case 'PEER_DISCOVERED':
        final peerId = event['peerId']?.toString();
        if (peerId == null || peerId.isEmpty || peerId == _peerId) return;

        final addresses = (event['addresses'] as List<dynamic>? ?? const [])
            .map((address) => address.toString())
            .toList(growable: false);

        final friendIdx = _friends.indexWhere((f) => f.peerId == peerId);
        List<FriendEntry>? updatedFriends;
        if (friendIdx >= 0 && addresses.isNotEmpty) {
          final updated = [..._friends];
          updated[friendIdx] = _friends[friendIdx].copyWith(addresses: addresses);
          updatedFriends = updated;
        }

        setState(() {
          _discoveredPeers = {
            ..._discoveredPeers,
            peerId: DiscoveredPeer(
              peerId: peerId,
              nickname: event['nickname']?.toString() ?? peerId,
              addresses: addresses,
              lastSeen: DateTime.now(),
            ),
          };
          _peerPresence = {..._peerPresence, peerId: _FriendPresence.online};
          if (updatedFriends != null) _friends = updatedFriends;
        });
        if (updatedFriends != null) unawaited(_saveFriends(updatedFriends));
        break;
      case 'PEER_NICKNAME_CHANGED':
        final peerId = event['peerId']?.toString();
        final newNickname = event['newNickname']?.toString();
        if (peerId == null || newNickname == null) return;

        final updatedFriends = [
          for (final friend in _friends)
            if (friend.peerId == peerId)
              friend.copyWith(nickname: newNickname)
            else
              friend,
        ];
        unawaited(_saveFriends(updatedFriends));

        final existingPeer = _discoveredPeers[peerId];
        if (existingPeer != null) {
          setState(() {
            _discoveredPeers = {
              ..._discoveredPeers,
              peerId: existingPeer.copyWith(nickname: newNickname),
            };
          });
        }
        break;
      case 'PEER_OFFLINE':
        final peerId = event['peerId']?.toString();
        if (peerId == null || peerId.isEmpty) return;
        setState(() {
          _peerPresence = {..._peerPresence, peerId: _FriendPresence.offline};
        });
        break;
      case 'INCOMING_FILE_REQUEST':
        final transferId = event['transferId']?.toString();
        final peerId = event['peerId']?.toString();
        final fileName = event['filename']?.toString();
        final totalBytes = _intValue(event['totalBytes']);
        if (transferId == null || peerId == null || fileName == null) return;

        setState(() {
          _incomingRequests = {
            ..._incomingRequests,
            transferId: IncomingFileRequest(
              transferId: transferId,
              peerId: peerId,
              fileName: fileName,
              totalBytes: totalBytes,
            ),
          };
        });
        break;
      case 'TRANSFER_UPDATE':
        final transferId = event['transferId']?.toString();
        if (transferId == null || transferId.isEmpty) return;

        final direction = event['direction']?.toString() == 'INCOMING'
            ? FileTransferDirection.incoming
            : FileTransferDirection.outgoing;

        final status = switch (event['status']?.toString()) {
          'IN_PROGRESS' => FileTransferStatus.inProgress,
          'COMPLETED' => FileTransferStatus.completed,
          'FAILED' => FileTransferStatus.failed,
          _ => FileTransferStatus.queued,
        };

        final existing = _transfers[transferId];
        final now = DateTime.now();
        final updated = FileTransferEntry(
          id: transferId,
          direction: direction,
          peerId: event['peerId']?.toString() ?? existing?.peerId ?? 'unknown',
          peerLabel:
              _friendLabel(event['peerId']?.toString()) ??
              existing?.peerLabel ??
              (event['peerId']?.toString() ?? 'Unknown Peer'),
          fileName:
              event['filename']?.toString() ?? existing?.fileName ?? 'transfer',
          bytesTransferred: _intValue(event['bytesTransferred']),
          totalBytes: _intValue(event['totalBytes']),
          status: status,
          error: status == FileTransferStatus.failed
              ? (event['message']?.toString() ?? existing?.error)
              : existing?.error,
          localPath: _pendingSavePaths[transferId] ?? existing?.localPath,
          startedAt: existing?.startedAt ??
              (status == FileTransferStatus.queued ||
                      status == FileTransferStatus.inProgress
                  ? now
                  : null),
          completedAt: (status == FileTransferStatus.completed ||
                  status == FileTransferStatus.failed)
              ? (existing?.completedAt ?? now)
              : existing?.completedAt,
        );

        final terminal = status == FileTransferStatus.completed ||
            status == FileTransferStatus.failed;

        setState(() {
          _transfers = {..._transfers, transferId: updated};
          if (terminal) {
            _incomingRequests = Map.of(_incomingRequests)..remove(transferId);
          }
        });
        if (terminal) _pendingSavePaths.remove(transferId);
        unawaited(_saveTransferHistory());
        break;
      case 'ERROR':
        setState(() {
          _errorMessage = event['message']?.toString() ?? 'Unknown node error';
          _busy = false;
        });
        break;
    }
  }

  int _intValue(dynamic value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  String? _friendLabel(String? peerId) {
    if (peerId == null || peerId.isEmpty) return null;

    for (final friend in _friends) {
      if (friend.peerId == peerId) {
        return friend.nickname;
      }
    }

    final discovered = _discoveredPeers[peerId];
    return discovered?.nickname;
  }

  _FriendPresence _presenceForPeer(String peerId) {
    final knownPresence = _peerPresence[peerId];
    if (knownPresence != null) {
      return knownPresence;
    }
    if (_discoveredPeers.containsKey(peerId)) {
      return _FriendPresence.online;
    }
    return _FriendPresence.unknown;
  }

  Future<void> _sendFileToPeer(String peerId) async {
    final result = await FilePicker.platform.pickFiles();
    final filePath = result?.files.singleOrNull?.path;
    if (filePath == null || filePath.isEmpty) {
      return;
    }

    setState(() {
      _busy = true;
      _errorMessage = null;
    });

    final knownAddresses = {
      ...?_discoveredPeers[peerId]?.addresses,
      for (final f in _friends)
        if (f.peerId == peerId) ...f.addresses,
    }.toList(growable: false);

    try {
      appLogger.i('ui.sendFile targetPeerId=$peerId filePath=$filePath knownAddresses=$knownAddresses');
      await widget.engine.sendFile(
        targetPeerId: peerId,
        filePath: filePath,
        knownAddresses: knownAddresses,
      );
    } catch (error) {
      appLogger.e('ui.sendFile.failed', error: error);
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

  Future<void> _acceptIncomingRequest(IncomingFileRequest request) async {
    final String? savePath;
    if (Platform.isAndroid) {
      final dir = Directory('/storage/emulated/0/Download');
      await dir.create(recursive: true);
      savePath = '${dir.path}/${request.fileName}';
    } else if (Platform.isIOS) {
      final dir = await const AppStoragePaths().receivedFilesDirectory();
      savePath = '${dir.path}/${request.fileName}';
    } else {
      savePath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save incoming file',
        fileName: request.fileName,
      );
    }
    if (savePath == null || savePath.isEmpty) {
      return;
    }

    _pendingSavePaths[request.transferId] = savePath;

    setState(() {
      _busy = true;
      _errorMessage = null;
    });

    try {
      appLogger.i(
        'ui.acceptIncoming transferId=${request.transferId} '
        'peerId=${request.peerId} savePath=$savePath',
      );
      await widget.engine.acceptFile(
        transferId: request.transferId,
        savePath: savePath,
      );
    } catch (error) {
      appLogger.e('ui.acceptIncoming.failed', error: error);
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

  Future<void> _rejectIncomingRequest(IncomingFileRequest request) async {
    setState(() {
      _busy = true;
      _errorMessage = null;
    });

    try {
      appLogger.i(
        'ui.rejectIncoming transferId=${request.transferId} peerId=${request.peerId}',
      );
      await widget.engine.rejectFile(transferId: request.transferId);
      if (!mounted) return;
      setState(() {
        _incomingRequests = Map.of(_incomingRequests)
          ..remove(request.transferId);
      });
    } catch (error) {
      appLogger.e('ui.rejectIncoming.failed', error: error);
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
    final editedFriend = await showDialog<FriendEntry>(
      context: context,
      builder: (dialogContext) => _FriendEditorDialog(
        initialFriend: initialFriend,
        discoveredPeer: discoveredPeer,
        validate: (peerId, nickname) => _validateFriend(
          peerId,
          nickname,
          editingPeerId: initialFriend?.peerId,
        ),
      ),
    );

    if (editedFriend == null) return;

    final updatedFriends = [
      for (final friend in _friends)
        if (friend.peerId == editedFriend.peerId ||
            friend.peerId == initialFriend?.peerId)
          editedFriend
        else
          friend,
      if (_friends.every((friend) => friend.peerId != editedFriend.peerId) &&
          initialFriend == null)
        editedFriend,
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
  }

  Future<void> _showNicknameEditor() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => _NicknameEditorDialog(
        initialNickname: _settings.nickname,
        onSave: (nickname) => _saveSettings(_settings.copyWith(nickname: nickname)),
      ),
    );
  }

  Future<void> _copyPeerId() async {
    if (_peerId == 'Unavailable' || _peerId.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _peerId));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Peer ID copied')));
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
            SelectableText('Peer ID: $_peerId'),
            const SizedBox(height: 8),
            Text('Listen addresses:'),
            const SizedBox(height: 8),
            if (_listenAddresses.isEmpty)
              const Text('No listen addresses announced yet.')
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: _listenAddresses
                    .map((address) => SelectableText(address))
                    .toList(growable: false),
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                if (_running)
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _stopEngine,
                    icon: const Icon(Icons.stop_outlined),
                    label: const Text('Stop Node'),
                  )
                else
                  FilledButton.icon(
                    onPressed: _busy ? null : _startEngine,
                    icon: const Icon(Icons.play_arrow_outlined),
                    label: const Text('Start Node'),
                  ),
                FilledButton.tonalIcon(
                  onPressed: _running ? _copyPeerId : null,
                  icon: const Icon(Icons.badge_outlined),
                  label: const Text('Copy Peer ID'),
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
              'Friends are stored locally as peer ID and nickname entries.',
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

  Widget _buildFriendCard(BuildContext context, FriendEntry friend) {
    final presence = _presenceForPeer(friend.peerId);

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
                key: ValueKey('friend-send-${friend.peerId}'),
                onPressed: _busy || !_running
                    ? null
                    : () => _sendFileToPeer(friend.peerId),
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

  Widget _buildDiscoveredPeersCard(BuildContext context) {
    final peers = _discoveredPeers.values.toList(growable: false)
      ..sort(
        (left, right) =>
            left.nickname.toLowerCase().compareTo(right.nickname.toLowerCase()),
      );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Discovered Peers',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            const Text(
              'Nearby peers appear here when they become discoverable.',
            ),
            const SizedBox(height: 16),
            if (peers.isEmpty)
              const Text('No peers discovered yet.')
            else
              Column(
                children: [
                  for (var index = 0; index < peers.length; index++) ...[
                    _buildDiscoveredPeerCard(context, peers[index]),
                    if (index < peers.length - 1) const SizedBox(height: 12),
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
                    if (peer.addresses.isEmpty)
                      const Text('No addresses announced.')
                    else
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: peer.addresses
                            .map((address) => SelectableText(address))
                            .toList(growable: false),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _buildPresenceChip(context, _presenceForPeer(peer.peerId)),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                key: ValueKey('discovered-send-${peer.peerId}'),
                onPressed: _busy || !_running
                    ? null
                    : () => _sendFileToPeer(peer.peerId),
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

  Widget _buildIncomingRequestsCard(BuildContext context) {
    final requests = _incomingRequests.values.toList(growable: false)
      ..sort((left, right) => left.transferId.compareTo(right.transferId));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Incoming Requests',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            if (requests.isEmpty)
              const Text('No incoming files pending.')
            else
              Column(
                children: [
                  for (var index = 0; index < requests.length; index++) ...[
                    _buildIncomingRequestCard(context, requests[index]),
                    if (index < requests.length - 1) const SizedBox(height: 12),
                  ],
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildIncomingRequestCard(
    BuildContext context,
    IncomingFileRequest request,
  ) {
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
            request.fileName,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text('From: ${_friendLabel(request.peerId) ?? request.peerId}'),
          const SizedBox(height: 8),
          Text('Size: ${request.totalBytes} bytes'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: _busy ? null : () => _acceptIncomingRequest(request),
                child: const Text('Accept'),
              ),
              OutlinedButton(
                onPressed: _busy ? null : () => _rejectIncomingRequest(request),
                child: const Text('Reject'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTransfersCard(BuildContext context) {
    final transfers = _transfers.values.toList(growable: false)
      ..sort((a, b) {
        final aTime = a.startedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bTime = b.startedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bTime.compareTo(aTime);
      });

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Transfers', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            if (transfers.isEmpty)
              const Text('No transfers yet.')
            else
              Column(
                children: [
                  for (var index = 0; index < transfers.length; index++) ...[
                    _buildTransferCard(context, transfers[index]),
                    if (index < transfers.length - 1)
                      const SizedBox(height: 12),
                  ],
                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.centerRight,
                    child: OutlinedButton.icon(
                      onPressed: () => _confirmClearHistory(context),
                      icon: Icon(
                        Icons.delete_outline,
                        color: Theme.of(context).colorScheme.error,
                      ),
                      label: Text(
                        'Clear History',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmClearHistory(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear transfer history?'),
        content: const Text(
          'All transfer history will be permanently deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _transfers = const {});
    unawaited(_saveTransferHistory());
  }

  Widget _buildTransferCard(BuildContext context, FileTransferEntry transfer) {
    final colors = Theme.of(context).colorScheme;
    final (statusLabel, statusColor, statusIcon) = switch (transfer.status) {
      FileTransferStatus.queued => ('Queued', colors.secondary, Icons.schedule),
      FileTransferStatus.inProgress => (
        'In Progress',
        colors.primary,
        Icons.sync,
      ),
      FileTransferStatus.completed => (
        'Completed',
        Colors.green,
        Icons.check_circle_outline,
      ),
      FileTransferStatus.failed => (
        'Failed',
        colors.error,
        Icons.error_outline,
      ),
    };
    final directionLabel = switch (transfer.direction) {
      FileTransferDirection.incoming => 'Incoming',
      FileTransferDirection.outgoing => 'Outgoing',
    };
    final directionIcon = switch (transfer.direction) {
      FileTransferDirection.incoming => Icons.arrow_downward,
      FileTransferDirection.outgoing => Icons.arrow_upward,
    };
    final timestamp = transfer.completedAt ?? transfer.startedAt;
    final timeLabel = timestamp != null ? _formatTimestamp(timestamp) : null;
    final sizeLabel = _formatBytes(transfer.totalBytes);
    final active = transfer.status == FileTransferStatus.queued ||
        transfer.status == FileTransferStatus.inProgress;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(directionIcon, size: 16, color: colors.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  transfer.fileName,
                  style: Theme.of(context).textTheme.titleMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(statusIcon, size: 16, color: statusColor),
              const SizedBox(width: 4),
              Text(
                statusLabel,
                style: TextStyle(color: statusColor, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  '$directionLabel • ${transfer.peerLabel} • $sizeLabel',
                  style: Theme.of(context).textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (timeLabel != null) ...[
                const SizedBox(width: 8),
                Text(timeLabel, style: Theme.of(context).textTheme.bodySmall),
              ],
            ],
          ),
          if (active) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(value: transfer.progress),
            const SizedBox(height: 4),
            Text(
              '${_formatBytes(transfer.bytesTransferred)} / $sizeLabel',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          if (transfer.error != null) ...[
            const SizedBox(height: 6),
            Text(
              transfer.error!,
              style: TextStyle(color: colors.error, fontSize: 12),
            ),
          ],
          if (transfer.status == FileTransferStatus.completed &&
              transfer.direction == FileTransferDirection.incoming &&
              transfer.localPath != null) ...[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => unawaited(
                  _openFileLocation(context, transfer.localPath!),
                ),
                icon: const Icon(Icons.folder_open_outlined, size: 16),
                label: Text(_showInFilesLabel),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _formatTimestamp(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  String get _showInFilesLabel {
    if (Platform.isMacOS) return 'Show in Finder';
    if (Platform.isWindows) return 'Show in Explorer';
    return 'Show in Files';
  }

  Future<void> _openFileLocation(BuildContext context, String path) async {
    if (Platform.isMacOS) {
      await Process.run('open', ['-R', path]);
      return;
    }
    if (Platform.isWindows) {
      await Process.run('explorer.exe', ['/select,', path]);
      return;
    }
    if (Platform.isLinux) {
      await _openFileLocationLinux(context, path);
      return;
    }
    if (Platform.isAndroid) {
      await widget.engine.openFileLocation(path);
    }
  }

  static const _linuxManagers = <({String name, String exec, bool selectsFile})>[
    (name: 'Nautilus', exec: 'nautilus', selectsFile: true),
    (name: 'Dolphin', exec: 'dolphin', selectsFile: true),
    (name: 'Nemo', exec: 'nemo', selectsFile: true),
    (name: 'Thunar', exec: 'thunar', selectsFile: false),
    (name: 'PCManFM', exec: 'pcmanfm', selectsFile: false),
    (name: 'Caja', exec: 'caja', selectsFile: false),
  ];

  Future<void> _openFileLocationLinux(BuildContext context, String path) async {
    final dir = File(path).parent.path;

    final available = <({String name, List<String> cmd})>[];
    for (final m in _linuxManagers) {
      final result = await Process.run('which', [m.exec]);
      if (result.exitCode == 0) {
        available.add((
          name: m.name,
          cmd: m.selectsFile ? [m.exec, path] : [m.exec, dir],
        ));
      }
    }

    if (available.isEmpty) {
      await Process.run('xdg-open', [dir]);
      return;
    }

    if (available.length == 1) {
      final c = available.first.cmd;
      await Process.run(c.first, c.sublist(1));
      return;
    }

    if (!context.mounted) return;
    final chosen = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Open with'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final m in available)
              ListTile(
                title: Text(m.name),
                onTap: () => Navigator.of(ctx).pop(m.cmd),
              ),
          ],
        ),
      ),
    );
    if (chosen == null) return;
    await Process.run(chosen.first, chosen.sublist(1));
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
            _buildDiscoveredPeersCard(context),
            const SizedBox(height: 16),
            _buildIncomingRequestsCard(context),
            const SizedBox(height: 16),
            _buildTransfersCard(context),
          ],
        ),
      ),
    );
  }
}

class _NicknameEditorDialog extends StatefulWidget {
  const _NicknameEditorDialog({required this.initialNickname, required this.onSave});

  final String initialNickname;
  final Future<void> Function(String) onSave;

  @override
  State<_NicknameEditorDialog> createState() => _NicknameEditorDialogState();
}

class _NicknameEditorDialogState extends State<_NicknameEditorDialog> {
  late final TextEditingController _controller;
  String? _validationError;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialNickname);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit Nickname'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _controller,
              decoration: const InputDecoration(
                labelText: 'Nickname',
                border: OutlineInputBorder(),
              ),
            ),
            if (_validationError != null) ...[
              const SizedBox(height: 12),
              Text(
                _validationError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () async {
            final nickname = _controller.text.trim();
            if (nickname.isEmpty) {
              setState(() => _validationError = 'Nickname is required.');
              return;
            }
            final navigator = Navigator.of(context);
            await widget.onSave(nickname);
            if (!mounted) return;
            navigator.pop();
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _FriendEditorDialog extends StatefulWidget {
  const _FriendEditorDialog({
    this.initialFriend,
    this.discoveredPeer,
    required this.validate,
  });

  final FriendEntry? initialFriend;
  final DiscoveredPeer? discoveredPeer;
  final String? Function(String peerId, String nickname) validate;

  @override
  State<_FriendEditorDialog> createState() => _FriendEditorDialogState();
}

class _FriendEditorDialogState extends State<_FriendEditorDialog> {
  late final TextEditingController _peerIdController;
  late final TextEditingController _nicknameController;
  String? _validationError;

  @override
  void initState() {
    super.initState();
    _peerIdController = TextEditingController(
      text: widget.initialFriend?.peerId ?? widget.discoveredPeer?.peerId ?? '',
    );
    _nicknameController = TextEditingController(
      text: widget.initialFriend?.nickname ?? widget.discoveredPeer?.nickname ?? '',
    );
  }

  @override
  void dispose() {
    _peerIdController.dispose();
    _nicknameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.initialFriend != null;
    return AlertDialog(
      title: Text(isEditing ? 'Edit Friend' : 'Add Friend'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _peerIdController,
              decoration: const InputDecoration(
                labelText: 'Peer ID',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nicknameController,
              decoration: const InputDecoration(
                labelText: 'Nickname',
                border: OutlineInputBorder(),
              ),
            ),
            if (_validationError != null) ...[
              const SizedBox(height: 12),
              Text(
                _validationError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final peerId = _peerIdController.text.trim();
            final nickname = _nicknameController.text.trim();
            final error = widget.validate(peerId, nickname);
            if (error != null) {
              setState(() => _validationError = error);
              return;
            }
            Navigator.of(context).pop(FriendEntry(
              peerId: peerId,
              nickname: nickname,
              addresses: widget.initialFriend?.addresses ?? widget.discoveredPeer?.addresses ?? const [],
            ));
          },
          child: Text(isEditing ? 'Save' : 'Add'),
        ),
      ],
    );
  }
}

