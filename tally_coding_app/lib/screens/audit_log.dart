// tally_coding_app/lib/screens/audit_log.dart
//
// Sprint 51: workspace audit log viewer.  Reached from WorkspaceSettingsScreen
// via an "Activity log" button (B3).  Keyset-paginated via before_id.
import 'package:flutter/material.dart';
import '../api.dart';

const _pageSize = 50;

class AuditLogScreen extends StatefulWidget {
  final TallyOrchClient client;
  final int workspaceId;
  final String workspaceName;
  const AuditLogScreen({
    super.key,
    required this.client,
    required this.workspaceId,
    required this.workspaceName,
  });

  @override
  State<AuditLogScreen> createState() => _AuditLogScreenState();
}

class _AuditLogScreenState extends State<AuditLogScreen> {
  final List<Map<String, dynamic>> _entries = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;

  String? _kindFilter;
  String _actorFilter = '';
  final _actorCtrl = TextEditingController();

  static const _allKinds = <String>[
    'workspace_created',
    'workspace_renamed',
    'workspace_settings_updated',
    'workspace_deleted',
    'workspace_ownership_transferred',
    'member_invited',
    'member_removed',
    'member_left',
    'member_role_changed',
    'channel_created',
    'channel_archived',
    'channel_unarchived',
    'persistent_agent_created',
    'persistent_agent_enabled_toggled',
    'persistent_agent_deleted',
    'persistent_agent_auto_paused',
    'audit_log_pruned',
  ];

  @override
  void initState() {
    super.initState();
    _loadFirst();
  }

  @override
  void dispose() {
    _actorCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadFirst() async {
    setState(() { _loading = true; _entries.clear(); _hasMore = true; _error = null; });
    try {
      final page = await widget.client.listAuditLog(
        workspaceId: widget.workspaceId,
        limit: _pageSize,
        kind: _kindFilter,
        actorUserId: _actorFilter.isEmpty ? null : _actorFilter,
      );
      if (!mounted) return;
      setState(() {
        _entries.addAll(page);
        _loading = false;
        _hasMore = page.length == _pageSize;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _entries.isEmpty) return;
    setState(() => _loadingMore = true);
    try {
      final page = await widget.client.listAuditLog(
        workspaceId: widget.workspaceId,
        limit: _pageSize,
        beforeId: _entries.last['id'] as int,
        kind: _kindFilter,
        actorUserId: _actorFilter.isEmpty ? null : _actorFilter,
      );
      if (!mounted) return;
      setState(() {
        _entries.addAll(page);
        _hasMore = page.length == _pageSize;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loadingMore = false; _error = e.toString(); });
    }
  }

  IconData _iconForKind(String kind) {
    if (kind.startsWith('workspace_')) return Icons.business;
    if (kind.startsWith('member_')) return Icons.person;
    if (kind.startsWith('channel_')) return Icons.tag;
    if (kind.startsWith('persistent_agent_')) return Icons.bolt;
    return Icons.history;
  }

  String _humanize(Map<String, dynamic> e) {
    final kind = e['kind'] as String;
    final actor = e['actor_user_id'] as String? ?? 'system';
    final payload = (e['payload'] as Map?)?.cast<String, dynamic>() ?? const {};
    switch (kind) {
      case 'workspace_created':
        return '$actor created workspace "${payload['name'] ?? ''}"';
      case 'workspace_renamed':
        return '$actor renamed workspace from "${payload['old_name']}" to "${payload['new_name']}"';
      case 'workspace_settings_updated':
        return '$actor updated workspace settings (${(payload['keys_changed'] as List?)?.join(", ") ?? ""})';
      case 'workspace_deleted':
        return '$actor deleted workspace "${payload['name'] ?? ''}"';
      case 'member_invited':
        return '$actor invited ${payload['user_id']} as ${payload['role']}';
      case 'member_removed':
        return '$actor removed ${payload['user_id']}';
      case 'member_left':
        return '$actor left the workspace';
      case 'member_role_changed':
        return '$actor changed ${payload['user_id']} from ${payload['old_role']} to ${payload['new_role']}';
      case 'channel_created':
        return '$actor created channel "${payload['name'] ?? ''}"';
      case 'channel_archived':
        return '$actor archived channel "${payload['name'] ?? ''}"';
      case 'channel_unarchived':
        return '$actor unarchived channel "${payload['name'] ?? ''}"';
      case 'persistent_agent_created':
        return '$actor created persistent agent "${payload['name'] ?? ''}" (${payload['role_name']})';
      case 'persistent_agent_enabled_toggled':
        return '$actor ${payload['enabled'] == true ? "enabled" : "disabled"} agent "${payload['name'] ?? ''}"';
      case 'persistent_agent_deleted':
        return '$actor deleted persistent agent "${payload['name'] ?? ''}"';
      case 'persistent_agent_auto_paused':
        return 'system auto-paused agent "${payload['name'] ?? ''}" after ${payload['consecutive_failures']} consecutive failures';
      default:
        return '$actor: $kind';
    }
  }

  String _formatTime(num ts) {
    final dt = DateTime.fromMillisecondsSinceEpoch((ts * 1000).round());
    return '${dt.year}-${dt.month.toString().padLeft(2, "0")}-${dt.day.toString().padLeft(2, "0")} '
        '${dt.hour.toString().padLeft(2, "0")}:${dt.minute.toString().padLeft(2, "0")}';
  }

  Widget _tile(Map<String, dynamic> entry) {
    final kind = entry['kind'] as String;
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: const Color(0xFF2B2D31),
        child: Icon(_iconForKind(kind), size: 20, color: const Color(0xFFB9BBBE)),
      ),
      title: Text(_humanize(entry)),
      subtitle: Text('$kind • ${_formatTime((entry['created_at'] as num?) ?? 0)}',
          style: const TextStyle(fontSize: 11, color: Color(0xFF949BA4))),
    );
  }

  Widget _filterBar() {
    return ExpansionTile(
      title: const Text('Filters'),
      initiallyExpanded: false,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<String?>(
                value: _kindFilter,
                decoration: const InputDecoration(labelText: 'Kind'),
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('Any')),
                  for (final k in _allKinds)
                    DropdownMenuItem<String?>(value: k, child: Text(k)),
                ],
                onChanged: (v) => setState(() => _kindFilter = v),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _actorCtrl,
                decoration: const InputDecoration(labelText: 'Actor user_id'),
                onChanged: (v) => _actorFilter = v.trim(),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _kindFilter = null;
                        _actorFilter = '';
                        _actorCtrl.clear();
                      });
                      _loadFirst();
                    },
                    child: const Text('Clear'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _loadFirst,
                    child: const Text('Apply'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Activity log: ${widget.workspaceName}')),
      body: Column(
        children: [
          _filterBar(),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('Error: $_error')))
                    : _entries.isEmpty
                        ? const Center(child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Text('No activity yet.',
                                style: TextStyle(color: Color(0xFF949BA4))),
                          ))
                        : Column(
                            children: [
                              Expanded(
                                child: RefreshIndicator(
                                  onRefresh: _loadFirst,
                                  child: ListView.builder(
                                    itemCount: _entries.length,
                                    itemBuilder: (_, i) => _tile(_entries[i]),
                                  ),
                                ),
                              ),
                              if (_hasMore)
                                Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Center(
                                    child: TextButton.icon(
                                      icon: _loadingMore
                                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                                          : const Icon(Icons.expand_more),
                                      label: Text(_loadingMore ? 'Loading…' : 'Load more'),
                                      onPressed: _loadingMore ? null : _loadMore,
                                    ),
                                  ),
                                ),
                            ],
                          ),
          ),
        ],
      ),
    );
  }
}
