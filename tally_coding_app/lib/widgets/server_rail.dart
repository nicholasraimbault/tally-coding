// tally_coding_app/lib/widgets/server_rail.dart
//
// Sprint 50: Discord-style server rail.  Far-left column with workspace
// icons (one per /me/workspaces entry) + a "+ Create" tile at the bottom.
// onSelect callback updates the active workspace_id (caller persists via
// WorkspaceContext / shared_preferences).
import 'package:flutter/material.dart';
import '../api.dart';

class ServerRail extends StatefulWidget {
  final TallyOrchClient client;
  final int activeWorkspaceId;
  final ValueChanged<int> onSelect;
  const ServerRail({
    super.key,
    required this.client,
    required this.activeWorkspaceId,
    required this.onSelect,
  });

  @override
  State<ServerRail> createState() => _ServerRailState();
}

class _ServerRailState extends State<ServerRail> {
  List<Map<String, dynamic>> _workspaces = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await widget.client.listMyWorkspaces();
      if (!mounted) return;
      setState(() => _workspaces = list);
    } catch (_) {
      // silent: rail just shows fewer icons
    }
  }

  Future<void> _onCreate() async {
    final messenger = ScaffoldMessenger.of(context);
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _CreateWorkspaceDialog(),
    );
    if (name == null || name.isEmpty) return;
    try {
      final ws = await widget.client.createWorkspace(name: name);
      widget.onSelect(ws['id'] as int);
      await _load();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Create failed: $e')));
    }
  }

  Widget _icon(Map<String, dynamic> ws) {
    final active = ws['id'] == widget.activeWorkspaceId;
    final name = (ws['name'] as String?) ?? '?';
    final letter = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Tooltip(
        message: name,
        child: InkWell(
          onTap: () => widget.onSelect(ws['id'] as int),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 42, height: 42,
            decoration: BoxDecoration(
              color: active ? const Color(0xFF5865F2) : const Color(0xFF2B2D31),
              borderRadius: BorderRadius.circular(active ? 12 : 21),
            ),
            alignment: Alignment.center,
            child: Text(
              letter,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 60,
      color: const Color(0xFF1A1B1E),
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        children: [
          // Tally home indicator — uses a home icon so the letter 'T' is
          // reserved for workspace-name initials in the icon list below.
          Container(
            width: 42, height: 42,
            decoration: const BoxDecoration(
              color: Color(0xFFF23F43),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: const Icon(Icons.home, color: Colors.white, size: 20),
          ),
          Container(
            margin: const EdgeInsets.symmetric(vertical: 6),
            width: 32, height: 1,
            color: const Color(0xFF2E3035),
          ),
          for (final ws in _workspaces) _icon(ws),
          const Spacer(),
          Tooltip(
            message: 'Create workspace',
            child: InkWell(
              onTap: _onCreate,
              child: Container(
                width: 42, height: 42,
                decoration: BoxDecoration(
                  color: const Color(0xFF2B2D31),
                  borderRadius: BorderRadius.circular(21),
                ),
                alignment: Alignment.center,
                child: const Icon(Icons.add, color: Color(0xFF3BA55D)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CreateWorkspaceDialog extends StatefulWidget {
  @override
  State<_CreateWorkspaceDialog> createState() => _CreateWorkspaceDialogState();
}

class _CreateWorkspaceDialogState extends State<_CreateWorkspaceDialog> {
  final _ctrl = TextEditingController();
  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New workspace'),
      content: TextField(
        controller: _ctrl,
        decoration: const InputDecoration(labelText: 'Workspace name'),
        autofocus: true,
        onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.of(context).pop(_ctrl.text.trim()), child: const Text('Create')),
      ],
    );
  }
}
