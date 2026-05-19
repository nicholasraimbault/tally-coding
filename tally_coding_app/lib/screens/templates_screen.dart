import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';

/// Sprint 34: template management.  Lists the signed-in user's saved
/// team_spec templates with per-row actions: rename, share via link,
/// delete.  Editing the team_spec graph itself stays in the team
/// builder — this screen is the catalogue + the share + the rename
/// affordance, not a second graph editor.
class TemplatesScreen extends StatefulWidget {
  final TallyOrchClient client;
  const TemplatesScreen({super.key, required this.client});

  @override
  State<TemplatesScreen> createState() => _TemplatesScreenState();
}

class _TemplatesScreenState extends State<TemplatesScreen> {
  Future<List<Map<String, dynamic>>>? _list;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    setState(() => _list = widget.client.listTemplates());
  }

  Future<void> _rename(Map<String, dynamic> tpl) async {
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => _RenameDialog(initial: tpl['name'] as String),
    );
    if (newName == null || newName.trim().isEmpty) return;
    try {
      await widget.client.patchTemplate(tpl['name'] as String, newName: newName.trim());
      if (!mounted) return;
      _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _editNote(Map<String, dynamic> tpl) async {
    final newNote = await showDialog<String>(
      context: context,
      builder: (ctx) => _NoteDialog(initial: (tpl['note'] as String?) ?? ''),
    );
    if (newNote == null) return;
    try {
      await widget.client.patchTemplate(tpl['name'] as String, note: newNote);
      if (!mounted) return;
      _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _share(Map<String, dynamic> tpl) async {
    try {
      final url = await widget.client.shareTemplate(tpl['name'] as String);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => _ShareDialog(
          templateName: tpl['name'] as String,
          shareUrl: url,
          onRevoke: () async {
            await widget.client.revokeShareToken(tpl['name'] as String);
            if (!ctx.mounted) return;
            Navigator.of(ctx).pop();
          },
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _delete(Map<String, dynamic> tpl) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2B2D31),
        title: Text("Delete '${tpl['name']}'?",
            style: const TextStyle(color: Colors.white)),
        content: const Text(
          'This removes the saved template. Tasks that used it are unaffected.',
          style: TextStyle(color: Color(0xFFB9BBBE)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFED4245)),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.client.deleteTemplate(tpl['name'] as String);
      if (!mounted) return;
      _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF313338),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1F22),
        foregroundColor: Colors.white,
        title: const Text('Saved templates'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _refresh),
        ],
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _list,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '${snap.error}',
                  style: const TextStyle(color: Colors.white70),
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          final templates = snap.data ?? const [];
          if (templates.isEmpty) {
            return const Center(
              child: Text(
                'No templates yet.\nPromote a completed task or build one in the team builder.',
                style: TextStyle(color: Color(0xFFB9BBBE)),
                textAlign: TextAlign.center,
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: templates.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (_, i) => _TemplateTile(
              template: templates[i],
              onRename: () => _rename(templates[i]),
              onEditNote: () => _editNote(templates[i]),
              onShare: () => _share(templates[i]),
              onDelete: () => _delete(templates[i]),
            ),
          );
        },
      ),
    );
  }
}

class _TemplateTile extends StatelessWidget {
  final Map<String, dynamic> template;
  final VoidCallback onRename;
  final VoidCallback onEditNote;
  final VoidCallback onShare;
  final VoidCallback onDelete;
  const _TemplateTile({
    required this.template,
    required this.onRename,
    required this.onEditNote,
    required this.onShare,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final spec = template['team_spec'] as Map<String, dynamic>? ?? const {};
    final agents = (spec['agents'] as List?) ?? const [];
    final note = (template['note'] as String?) ?? '';
    final useCount = (template['use_count'] as num?)?.toInt() ?? 0;
    final hasShareToken = (template['share_token'] as String?)?.isNotEmpty ?? false;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF2B2D31),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        template['name'] as String,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                    if (hasShareToken)
                      const Tooltip(
                        message: 'Sharable via link',
                        child: Icon(Icons.link, size: 14, color: Color(0xFF57F287)),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${agents.length} agent${agents.length == 1 ? '' : 's'} · used $useCount time${useCount == 1 ? '' : 's'}',
                  style: const TextStyle(color: Color(0xFFB9BBBE), fontSize: 12),
                ),
                if (note.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    note,
                    style: const TextStyle(color: Color(0xFFC4C9CE), fontSize: 12),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          PopupMenuButton<String>(
            color: const Color(0xFF1E1F22),
            icon: const Icon(Icons.more_vert, color: Color(0xFF99AAB5)),
            onSelected: (action) {
              switch (action) {
                case 'rename':
                  onRename();
                  break;
                case 'note':
                  onEditNote();
                  break;
                case 'share':
                  onShare();
                  break;
                case 'delete':
                  onDelete();
                  break;
              }
            },
            itemBuilder: (ctx) => const [
              PopupMenuItem(value: 'rename', child: Text('Rename', style: TextStyle(color: Colors.white))),
              PopupMenuItem(value: 'note', child: Text('Edit note', style: TextStyle(color: Colors.white))),
              PopupMenuItem(value: 'share', child: Text('Share link', style: TextStyle(color: Colors.white))),
              PopupMenuItem(value: 'delete', child: Text('Delete', style: TextStyle(color: Color(0xFFED4245)))),
            ],
          ),
        ],
      ),
    );
  }
}

class _RenameDialog extends StatefulWidget {
  final String initial;
  const _RenameDialog({required this.initial});
  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _ctrl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF2B2D31),
      title: const Text('Rename template', style: TextStyle(color: Colors.white)),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        style: const TextStyle(color: Colors.white),
        decoration: const InputDecoration(
          labelText: 'New name',
          labelStyle: TextStyle(color: Color(0xFFB9BBBE)),
        ),
        maxLength: 64,
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(_ctrl.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _NoteDialog extends StatefulWidget {
  final String initial;
  const _NoteDialog({required this.initial});
  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<_NoteDialog> {
  late final TextEditingController _ctrl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF2B2D31),
      title: const Text('Edit template note', style: TextStyle(color: Colors.white)),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        maxLines: 4,
        style: const TextStyle(color: Colors.white),
        decoration: const InputDecoration(
          labelText: 'Notes (visible only to you)',
          labelStyle: TextStyle(color: Color(0xFFB9BBBE)),
          alignLabelWithHint: true,
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(_ctrl.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _ShareDialog extends StatelessWidget {
  final String templateName;
  final String shareUrl;
  final Future<void> Function() onRevoke;
  const _ShareDialog({
    required this.templateName,
    required this.shareUrl,
    required this.onRevoke,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF2B2D31),
      title: Text("Share '$templateName'",
          style: const TextStyle(color: Colors.white)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Anyone with this link can view the team_spec (read-only). '
            'They cannot run tasks against your account.',
            style: TextStyle(color: Color(0xFFB9BBBE), fontSize: 12),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1F22),
              borderRadius: BorderRadius.circular(4),
            ),
            child: SelectableText(
              shareUrl,
              style: const TextStyle(color: Colors.white, fontSize: 12, fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await onRevoke();
          },
          style: TextButton.styleFrom(foregroundColor: const Color(0xFFED4245)),
          child: const Text('Revoke link'),
        ),
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: shareUrl));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Link copied to clipboard')),
              );
            }
          },
          child: const Text('Copy'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
