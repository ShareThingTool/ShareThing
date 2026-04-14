import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/engine_manager.dart';
import 'features/friends/friend.dart';
import 'features/friends/friends_repository.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(ShareThingApp());
}

class ShareThingApp extends StatelessWidget {
  ShareThingApp({super.key, EngineManager? engine})
    : engine = engine ?? EngineManager();

  final EngineManager engine;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ShareThing',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey),
        useMaterial3: true,
      ),
      home: MyHomePage(engine: engine),
    );
  }
}

enum _FriendPresence { unknown, checking, online, offline }

extension on _FriendPresence {
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
  const MyHomePage({super.key, required this.engine});

  final EngineManager engine;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final FriendsRepository _friendsRepository = FriendsRepository();
  final TextEditingController _peerController = TextEditingController();
  StreamSubscription<Map<String, dynamic>>? _engineSubscription;

  List<FriendEntry> _friends = const [];
  Map<String, _FriendPresence> _friendStatuses = const {};

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
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    _engineSubscription?.cancel();
    _peerController.dispose();
    unawaited(widget.engine.stop());
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await _loadFriends();
    unawaited(_loadLocalIp());
    await _startEngine();
  }

  Future<void> _loadFriends() async {
    final friends = await _friendsRepository.loadFriends();
    if (!mounted) return;

    final sortedFriends = [...friends]
      ..sort(
        (left, right) =>
            left.nickname.toLowerCase().compareTo(right.nickname.toLowerCase()),
      );

    setState(() {
      _friends = sortedFriends;
      _friendStatuses = {
        for (final friend in sortedFriends)
          friend.id: _friendStatuses[friend.id] ?? _FriendPresence.unknown,
      };
    });
  }

  Future<void> _saveFriends(List<FriendEntry> friends) async {
    final sortedFriends = [...friends]
      ..sort(
        (left, right) =>
            left.nickname.toLowerCase().compareTo(right.nickname.toLowerCase()),
      );

    await _friendsRepository.saveFriends(sortedFriends);
    if (!mounted) return;

    setState(() {
      _friends = sortedFriends;
      _friendStatuses = {
        for (final friend in sortedFriends)
          friend.id: _friendStatuses[friend.id] ?? _FriendPresence.unknown,
      };
    });
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
          _friendStatuses = {
            for (final friend in _friends) friend.id: _FriendPresence.unknown,
          };
        });
        break;
      case 'file_received':
        final name = event['filename']?.toString() ?? 'unknown';
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Received file: $name')));
        break;
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

  void _setFriendPresence(String friendId, _FriendPresence presence) {
    if (!mounted) return;
    setState(() {
      _friendStatuses = {..._friendStatuses, friendId: presence};
    });
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

    await widget.engine.stop();

    if (!mounted) return;
    setState(() {
      _busy = false;
      _running = false;
      _nodeId = 'Unavailable';
      _shareAddress = 'Unavailable';
      _statusMessage = 'Engine stopped';
      _friendStatuses = {
        for (final friend in _friends) friend.id: _FriendPresence.unknown,
      };
    });
  }

  Future<void> _connectToPeer({
    required String address,
    String? friendId,
  }) async {
    final trimmedAddress = address.trim();
    if (trimmedAddress.isEmpty) return;

    setState(() {
      _busy = true;
      _errorMessage = null;
      _peerController.text = trimmedAddress;
    });

    if (friendId != null) {
      _setFriendPresence(friendId, _FriendPresence.checking);
    }

    try {
      final response = await widget.engine.sendCommand('connect', {
        'multiaddr': trimmedAddress,
      });
      _ensureCommandSucceeded(response, 'connect');

      if (friendId != null) {
        _setFriendPresence(friendId, _FriendPresence.online);
      }

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Connected to $trimmedAddress')));
    } catch (error) {
      if (friendId != null) {
        _setFriendPresence(friendId, _FriendPresence.offline);
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

  String? _validateFriend(
    String nickname,
    String multiaddr, {
    String? editingId,
  }) {
    if (nickname.isEmpty) {
      return 'Nickname is required.';
    }
    if (multiaddr.isEmpty) {
      return 'Share address is required.';
    }
    if (!multiaddr.contains('/p2p/')) {
      return 'Share address must contain a /p2p/<peerId> segment.';
    }

    final duplicateNickname = _friends.any(
      (friend) =>
          friend.id != editingId &&
          friend.nickname.toLowerCase() == nickname.toLowerCase(),
    );
    if (duplicateNickname) {
      return 'Nickname must be unique.';
    }

    return null;
  }

  Future<void> _showFriendEditor([FriendEntry? initialFriend]) async {
    final nicknameController = TextEditingController(
      text: initialFriend?.nickname ?? '',
    );
    final addressController = TextEditingController(
      text: initialFriend?.multiaddr ?? '',
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
                width: 440,
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
                    const SizedBox(height: 12),
                    TextField(
                      controller: addressController,
                      minLines: 2,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'Share address',
                        hintText: '/ip4/192.168.1.20/tcp/4001/p2p/...',
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
                  onPressed: () {
                    final nickname = nicknameController.text.trim();
                    final multiaddr = addressController.text.trim();
                    final validationMessage = _validateFriend(
                      nickname,
                      multiaddr,
                      editingId: initialFriend?.id,
                    );
                    if (validationMessage != null) {
                      setDialogState(() {
                        validationError = validationMessage;
                      });
                      return;
                    }

                    editedFriend = FriendEntry(
                      id:
                          initialFriend?.id ??
                          DateTime.now().microsecondsSinceEpoch.toString(),
                      nickname: nickname,
                      multiaddr: multiaddr,
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

    nicknameController.dispose();
    addressController.dispose();

    if (editedFriend == null) return;

    final updatedFriends = [
      for (final friend in _friends)
        if (friend.id == editedFriend!.id) editedFriend! else friend,
      if (_friends.every((friend) => friend.id != editedFriend!.id))
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
        .where((candidate) => candidate.id != friend.id)
        .toList(growable: false);
    await _saveFriends(updatedFriends);

    if (!mounted) return;
    setState(() {
      _friendStatuses = {
        for (final candidate in updatedFriends)
          candidate.id:
              _friendStatuses[candidate.id] ?? _FriendPresence.unknown,
      };
    });
  }

  Future<void> _copyShareAddress() async {
    if (_displayShareAddress == 'Unavailable' || _displayShareAddress.isEmpty) {
      return;
    }

    await Clipboard.setData(ClipboardData(text: _displayShareAddress));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Share address copied to clipboard')),
    );
  }

  Widget _buildPresenceChip(BuildContext context, _FriendPresence presence) {
    final color = presence.color(context);

    return Chip(
      avatar: Icon(presence.icon, size: 18, color: color),
      label: Text(presence.label),
      side: BorderSide(color: color.withValues(alpha: 0.35)),
    );
  }

  Widget _buildStatusCard(BuildContext context) {
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
            SelectableText('Peer ID: $_nodeId'),
            const SizedBox(height: 8),
            SelectableText(
              '${widget.engine.endpointLabel}: $_displayShareAddress',
            ),
            const SizedBox(height: 8),
            Text('Local IPv4: $_localIp'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.tonalIcon(
                  onPressed: _running ? _copyShareAddress : null,
                  icon: const Icon(Icons.copy_all_outlined),
                  label: const Text('Copy Share Address'),
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
    final presence = _friendStatuses[friend.id] ?? _FriendPresence.unknown;

    return Container(
      key: ValueKey('friend-card-${friend.id}'),
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
                    SelectableText(friend.multiaddr),
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
                key: ValueKey('friend-connect-${friend.id}'),
                onPressed: _busy || !_running
                    ? null
                    : () => _connectToPeer(
                        address: friend.multiaddr,
                        friendId: friend.id,
                      ),
                icon: const Icon(Icons.link),
                label: const Text('Connect'),
              ),
              OutlinedButton.icon(
                key: ValueKey('friend-edit-${friend.id}'),
                onPressed: () => _showFriendEditor(friend),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Edit'),
              ),
              OutlinedButton.icon(
                key: ValueKey('friend-delete-${friend.id}'),
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
            Text(
              'Presence currently reflects the last connect attempt. Discovery-backed online status comes later.',
              style: Theme.of(context).textTheme.bodyMedium,
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

  Widget _buildManualConnectCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Manual Connect',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('manual-peer-field'),
              controller: _peerController,
              minLines: 2,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Peer multiaddr',
                hintText: '/ip4/192.168.1.20/tcp/4001/p2p/...',
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
            if (!widget.engine.supportsFileTransfers)
              const Text(
                'File transfer is not connected to the Flutter bridge yet.',
              ),
          ],
        ),
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
            _buildStatusCard(context),
            const SizedBox(height: 16),
            _buildFriendsCard(context),
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
