// tally_coding_app/lib/screens/workspace_settings.dart
//
// Sprint 50 B5: workspace branding + members + danger-zone settings.
// Reached from the channel-rail gear icon.
import 'package:flutter/material.dart';
import '../api.dart';
import 'audit_log.dart';

// Roles a non-owner caller can select from (cannot set owner; cannot touch owner)
const _kAssignableRoles = ['admin', 'manager', 'member'];

class WorkspaceSettingsScreen extends StatefulWidget {
  final TallyOrchClient client;
  final int workspaceId;
  final String workspaceName;
  final String callerRole; // 'owner' / 'admin' / 'manager' / 'member'

  const WorkspaceSettingsScreen({
    super.key,
    required this.client,
    required this.workspaceId,
    required this.workspaceName,
    required this.callerRole,
  });

  @override
  State<WorkspaceSettingsScreen> createState() => _WorkspaceSettingsScreenState();
}

class _WorkspaceSettingsScreenState extends State<WorkspaceSettingsScreen> {
  late TextEditingController _nameCtrl;
  late TextEditingController _iconUrlCtrl;
  List<Map<String, dynamic>> _members = [];
  bool _loadingMembers = true;
  bool _savingBranding = false;

  // Sprint 51 B5 — archived channels
  List<Map<String, dynamic>> _archivedChannels = [];
  bool _loadingArchived = true;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.workspaceName);
    _iconUrlCtrl = TextEditingController();
    _loadMembers();
    _loadArchivedChannels(); // Sprint 51
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _iconUrlCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadMembers() async {
    try {
      final list = await widget.client.listWorkspaceMembers(workspaceId: widget.workspaceId);
      if (!mounted) return;
      setState(() {
        _members = list;
        _loadingMembers = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingMembers = false);
    }
  }

  // === Branding ===

  Future<void> _saveBranding() async {
    final messenger = ScaffoldMessenger.of(context);
    if (_savingBranding) return;
    setState(() => _savingBranding = true);
    try {
      final patch = <String, dynamic>{};
      if (_nameCtrl.text.trim() != widget.workspaceName) {
        patch['name'] = _nameCtrl.text.trim();
      }
      if (_iconUrlCtrl.text.trim().isNotEmpty) {
        patch['settings'] = {'icon_url': _iconUrlCtrl.text.trim()};
      }
      if (patch.isEmpty) {
        messenger.showSnackBar(const SnackBar(content: Text('Nothing to save')));
        return;
      }
      await widget.client.updateWorkspace(id: widget.workspaceId, patch: patch);
      if (mounted) messenger.showSnackBar(const SnackBar(content: Text('Saved')));
    } catch (e) {
      if (mounted) messenger.showSnackBar(SnackBar(content: Text('Save failed: $e')));
    } finally {
      if (mounted) setState(() => _savingBranding = false);
    }
  }

  // === Members ===

  // Owner can edit any non-owner role.
  // Admin can edit manager/member roles (but not owner or other admins).
  bool _canEditRole(String targetRole) {
    if (targetRole == 'owner') return false;
    if (widget.callerRole == 'owner') return true;
    if (widget.callerRole == 'admin' && targetRole != 'admin' && targetRole != 'owner') return true;
    return false;
  }

  Future<void> _onRoleChanged(Map<String, dynamic> member, String newRole) async {
    if (newRole == member['role']) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.client.updateWorkspaceMemberRole(
        workspaceId: widget.workspaceId,
        userId: member['user_id'] as String,
        role: newRole,
      );
      await _loadMembers();
    } catch (e) {
      if (mounted) messenger.showSnackBar(SnackBar(content: Text('Role change failed: $e')));
    }
  }

  Future<void> _onRemoveMember(Map<String, dynamic> member) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.client.removeWorkspaceMember(
        workspaceId: widget.workspaceId,
        userId: member['user_id'] as String,
      );
      await _loadMembers();
    } catch (e) {
      if (mounted) messenger.showSnackBar(SnackBar(content: Text('Remove failed: $e')));
    }
  }

  Future<void> _onInvite() async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => const _InviteMemberDialog(),
    );
    if (result == null) return;
    try {
      await widget.client.inviteWorkspaceMember(
        workspaceId: widget.workspaceId,
        userId: result['user_id']!,
        role: result['role']!,
      );
      await _loadMembers();
    } catch (e) {
      if (mounted) messenger.showSnackBar(SnackBar(content: Text('Invite failed: $e')));
    }
  }

  // === Danger zone ===

  Future<void> _onTransferOwnership() async {
    final eligible = _members
        .where((m) => m['member_kind'] == 'human' && m['role'] != 'owner')
        .toList();
    if (eligible.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No eligible recipients')),
        );
      }
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final newOwner = await showDialog<String>(
      context: context,
      builder: (_) => _TransferOwnershipDialog(members: eligible),
    );
    if (newOwner == null) return;
    try {
      await widget.client.transferOwnership(
        workspaceId: widget.workspaceId,
        newOwnerUserId: newOwner,
      );
      if (mounted) {
        messenger.showSnackBar(const SnackBar(content: Text('Ownership transferred')));
        navigator.pop();
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('Transfer failed: $e')));
      }
    }
  }

  // === Archived channels ===

  Future<void> _loadArchivedChannels() async {
    try {
      final channels = await widget.client.listChannels(
        workspaceId: widget.workspaceId, includeArchived: true,
      );
      if (!mounted) return;
      setState(() {
        _archivedChannels = channels
          .where((c) => c['archived_at'] != null && c['kind'] == 'custom')
          .toList();
        _loadingArchived = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingArchived = false);
    }
  }

  Future<void> _onUnarchive(Map<String, dynamic> ch) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.client.unarchiveChannel(channelId: ch['id'] as int);
      await _loadArchivedChannels();
      messenger.showSnackBar(SnackBar(content: Text('Unarchived "${ch['name']}"')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Unarchive failed: $e')));
    }
  }

  String _formatArchivedTime(num? ts) {
    if (ts == null) return '?';
    final dt = DateTime.fromMillisecondsSinceEpoch((ts * 1000).round());
    return '${dt.year}-${dt.month.toString().padLeft(2, "0")}-${dt.day.toString().padLeft(2, "0")}';
  }

  Future<void> _onLeave() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Leave workspace?'),
        content: const Text('You will lose access to all channels in this workspace.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Leave')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.client.leaveWorkspace(id: widget.workspaceId);
      if (mounted) navigator.pop();
    } catch (e) {
      if (mounted) messenger.showSnackBar(SnackBar(content: Text('Leave failed: $e')));
    }
  }

  Future<void> _onDelete() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete workspace?'),
        content: Text('${widget.workspaceName} will be soft-deleted. History is preserved.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.client.deleteWorkspace(id: widget.workspaceId);
      if (mounted) navigator.pop();
    } catch (e) {
      if (mounted) messenger.showSnackBar(SnackBar(content: Text('Delete failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Settings: ${widget.workspaceName}')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // === Branding ===
          const Text('Branding', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _iconUrlCtrl,
            decoration: const InputDecoration(labelText: 'Icon URL (optional)'),
          ),
          const SizedBox(height: 8),
          if (widget.callerRole == 'owner')
            ElevatedButton(
              onPressed: _savingBranding ? null : _saveBranding,
              child: Text(_savingBranding ? 'Saving…' : 'Save branding'),
            )
          else
            const Text(
              'Only the owner can edit branding.',
              style: TextStyle(color: Color(0xFF949BA4), fontSize: 12),
            ),

          const Divider(height: 32),

          // === Members ===
          Row(
            children: [
              const Text('Members', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const Spacer(),
              if (widget.callerRole == 'owner' || widget.callerRole == 'admin')
                TextButton.icon(
                  onPressed: _onInvite,
                  icon: const Icon(Icons.add),
                  label: const Text('Invite'),
                ),
            ],
          ),
          if (_loadingMembers)
            const Center(child: CircularProgressIndicator())
          else
            ..._members.map((m) => _memberTile(m)),

          const Divider(height: 32),

          // === Activity log ===
          if (widget.callerRole == 'owner' || widget.callerRole == 'admin')
            ListTile(
              leading: const Icon(Icons.history),
              title: const Text('Activity log'),
              subtitle: const Text('Workspace audit log'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => AuditLogScreen(
                  client: widget.client,
                  workspaceId: widget.workspaceId,
                  workspaceName: widget.workspaceName,
                  callerRole: widget.callerRole,
                ),
              )),
            ),

          const Divider(height: 32),

          // === Archived channels ===
          const Text('Archived channels', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          if (_loadingArchived)
            const Center(child: CircularProgressIndicator())
          else if (_archivedChannels.isEmpty)
            const Text('No archived channels.', style: TextStyle(color: Color(0xFF949BA4), fontSize: 12))
          else
            ..._archivedChannels.map((c) => ListTile(
                  leading: const Icon(Icons.archive, color: Color(0xFF949BA4)),
                  title: Text(c['name'] as String? ?? '?'),
                  subtitle: Text('archived ${_formatArchivedTime(c['archived_at'] as num?)}',
                      style: const TextStyle(fontSize: 11, color: Color(0xFF949BA4))),
                  trailing: TextButton(
                    onPressed: () => _onUnarchive(c),
                    child: const Text('Unarchive'),
                  ),
                )),

          const Divider(height: 32),

          // === Danger zone ===
          const Text(
            'Danger zone',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.red),
          ),
          const SizedBox(height: 8),
          if (widget.callerRole == 'owner')
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: ElevatedButton(
                onPressed: _onTransferOwnership,
                style: ElevatedButton.styleFrom(backgroundColor: Colors.purple),
                child: const Text('Transfer ownership'),
              ),
            ),
          if (widget.callerRole == 'owner')
            ElevatedButton(
              onPressed: _onDelete,
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              child: const Text('Delete workspace'),
            )
          else
            ElevatedButton(
              onPressed: _onLeave,
              style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
              child: const Text('Leave workspace'),
            ),
        ],
      ),
    );
  }

  Widget _memberTile(Map<String, dynamic> m) {
    final isTally = m['member_kind'] == 'tally';
    final name = isTally ? 'Tally' : (m['user_id'] as String? ?? 'unknown');
    final role = m['role'] as String? ?? '?';
    final canEdit = !isTally && _canEditRole(role);

    // Ensure the current role is always present in the dropdown items to avoid
    // a Flutter assertion when value is not in items list.
    final dropdownItems = canEdit
        ? {
            ...?(_kAssignableRoles.contains(role) ? null : {role}),
            ..._kAssignableRoles,
          }.toList()
        : <String>[];

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: isTally ? const Color(0xFFF23F43) : const Color(0xFF5865F2),
        child: Text(name[0].toUpperCase(), style: const TextStyle(color: Colors.white)),
      ),
      title: Text(name),
      subtitle: Text(role),
      trailing: canEdit
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButton<String>(
                  value: role,
                  items: [
                    for (final r in dropdownItems) DropdownMenuItem(value: r, child: Text(r)),
                  ],
                  onChanged: (v) {
                    if (v != null) _onRoleChanged(m, v);
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.delete, size: 18),
                  onPressed: () => _onRemoveMember(m),
                ),
              ],
            )
          : null,
    );
  }
}

class _InviteMemberDialog extends StatefulWidget {
  const _InviteMemberDialog();

  @override
  State<_InviteMemberDialog> createState() => _InviteMemberDialogState();
}

class _InviteMemberDialogState extends State<_InviteMemberDialog> {
  final _userIdCtrl = TextEditingController();
  String _role = 'member';

  @override
  void dispose() {
    _userIdCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Invite member'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _userIdCtrl,
            decoration: const InputDecoration(labelText: 'User ID'),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _role,
            decoration: const InputDecoration(labelText: 'Role'),
            items: [
              for (final r in const ['admin', 'manager', 'member'])
                DropdownMenuItem(value: r, child: Text(r)),
            ],
            onChanged: (v) {
              if (v != null) setState(() => _role = v);
            },
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        TextButton(
          onPressed: () {
            final uid = _userIdCtrl.text.trim();
            if (uid.isEmpty) return;
            Navigator.of(context).pop({'user_id': uid, 'role': _role});
          },
          child: const Text('Invite'),
        ),
      ],
    );
  }
}

class _TransferOwnershipDialog extends StatefulWidget {
  final List<Map<String, dynamic>> members;
  const _TransferOwnershipDialog({required this.members});

  @override
  State<_TransferOwnershipDialog> createState() => _TransferOwnershipDialogState();
}

class _TransferOwnershipDialogState extends State<_TransferOwnershipDialog> {
  String? _selected;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Transfer ownership'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'You will be demoted to admin. This cannot be undone (the new owner can transfer back).',
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _selected,
            decoration: const InputDecoration(labelText: 'New owner'),
            items: [
              for (final m in widget.members)
                DropdownMenuItem(
                  value: m['user_id'] as String,
                  child: Text('${m['user_id']} (${m['role']})'),
                ),
            ],
            onChanged: (v) => setState(() => _selected = v),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _selected == null ? null : () => Navigator.of(context).pop(_selected),
          child: const Text('Transfer'),
        ),
      ],
    );
  }
}
