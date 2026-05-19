import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';

/// Sprint 37: persistent project workspaces.  Lists the user's
/// projects with a New / Rename / Delete affordance.  Tapping a
/// project lets the user select it as the "active project" for
/// subsequent task submissions.
class ProjectsScreen extends StatefulWidget {
  final TallyOrchClient client;
  /// Currently-active project id (null if no project is selected).
  /// We use this to render a "Current" badge on the right row.
  final String? activeProjectId;
  final ValueChanged<String?> onSelectActive;
  const ProjectsScreen({
    super.key,
    required this.client,
    required this.activeProjectId,
    required this.onSelectActive,
  });

  @override
  State<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends State<ProjectsScreen> {
  Future<List<Map<String, dynamic>>>? _list;
  String? _activeId;
  bool? _githubConnected;

  @override
  void initState() {
    super.initState();
    _activeId = widget.activeProjectId;
    _refresh();
    _refreshGithubStatus();
  }

  void _refresh() {
    setState(() => _list = widget.client.listProjects());
  }

  Future<void> _refreshGithubStatus() async {
    try {
      final has = await widget.client.hasGithubToken();
      if (!mounted) return;
      setState(() => _githubConnected = has);
    } catch (_) {
      if (!mounted) return;
      setState(() => _githubConnected = false);
    }
  }

  Future<void> _openGithubDialog() async {
    if (_githubConnected == true) {
      // Already connected — offer to disconnect.
      final disconnect = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF2B2D31),
          title: const Text('GitHub connected', style: TextStyle(color: Colors.white)),
          content: const Text(
            'Your GitHub PAT is stored encrypted on the orchestrator. '
            'Disconnect to revoke and remove it.',
            style: TextStyle(color: Color(0xFFB9BBBE)),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Keep')),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFED4245)),
              child: const Text('Disconnect', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );
      if (disconnect == true) {
        try {
          await widget.client.deleteGithubToken();
          if (!mounted) return;
          setState(() => _githubConnected = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('GitHub disconnected')),
          );
        } catch (e) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
        }
      }
      return;
    }
    final pat = await showDialog<String>(
      context: context,
      builder: (ctx) => const _ConnectGithubDialog(),
    );
    if (pat == null || pat.trim().isEmpty) return;
    try {
      await widget.client.setGithubToken(pat.trim());
      if (!mounted) return;
      setState(() => _githubConnected = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('GitHub PAT stored (encrypted).')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _pushToGithub(Map<String, dynamic> p) async {
    if (_githubConnected != true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Connect GitHub first (chip in the top bar).')),
      );
      return;
    }
    final spec = await showDialog<({String repo, String? branch, String? message})>(
      context: context,
      builder: (ctx) => _PushDialog(projectName: p['name'] as String),
    );
    if (spec == null) return;
    final progress = ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Row(children: [
          SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 10),
          Text('Pushing to GitHub…'),
        ]),
        duration: Duration(seconds: 60),
      ),
    );
    try {
      final result = await widget.client.pushProjectToGithub(
        p['id'] as String,
        repo: spec.repo,
        branch: spec.branch,
        commitMessage: spec.message,
      );
      progress.close();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => _PushResultDialog(result: result),
      );
    } catch (e) {
      progress.close();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _create() async {
    final result = await showDialog<({String name, String? description})>(
      context: context,
      builder: (ctx) => const _NewProjectDialog(),
    );
    if (result == null || result.name.trim().isEmpty) return;
    try {
      final proj = await widget.client.createProject(
        name: result.name.trim(),
        description: result.description?.trim().isEmpty == true ? null : result.description?.trim(),
      );
      if (!mounted) return;
      // Auto-select the new project so the user can immediately
      // submit a task into it.
      _setActive(proj['id'] as String);
      _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _rename(Map<String, dynamic> p) async {
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => _RenameDialog(initial: p['name'] as String),
    );
    if (newName == null || newName.trim().isEmpty) return;
    try {
      await widget.client.patchProject(p['id'] as String, name: newName.trim());
      if (!mounted) return;
      _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _delete(Map<String, dynamic> p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2B2D31),
        title: Text("Delete '${p['name']}'?",
            style: const TextStyle(color: Colors.white)),
        content: const Text(
          'This removes the project + its HEAD artifact set. Tasks that '
          'ran inside it stay in your task list — they just no longer '
          'reference a live project.',
          style: TextStyle(color: Color(0xFFB9BBBE)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
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
      await widget.client.deleteProject(p['id'] as String);
      if (!mounted) return;
      if (_activeId == p['id']) {
        _setActive(null);
      }
      _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  void _setActive(String? id) {
    setState(() => _activeId = id);
    widget.onSelectActive(id);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF313338),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1F22),
        foregroundColor: Colors.white,
        title: const Text('Projects'),
        actions: [
          _GithubChip(connected: _githubConnected, onTap: _openGithubDialog),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _refresh),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFF7C5CFC),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('New project'),
        onPressed: _create,
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
                child: Text('${snap.error}',
                    style: const TextStyle(color: Colors.white70),
                    textAlign: TextAlign.center),
              ),
            );
          }
          final projects = snap.data ?? const [];
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _ActiveSelector(
                activeId: _activeId,
                onClear: () => _setActive(null),
                hasProjects: projects.isNotEmpty,
              ),
              const SizedBox(height: 12),
              if (projects.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 36),
                  child: Center(
                    child: Text(
                      'No projects yet.\nTap "New project" to create one.\n'
                      "Tasks you submit while a project is selected will\n"
                      'build on the project\'s existing files.',
                      style: TextStyle(color: Color(0xFFB9BBBE)),
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              else
                for (final p in projects) ...[
                  _ProjectTile(
                    project: p,
                    isActive: _activeId == p['id'],
                    onSelect: () => _setActive(p['id'] as String),
                    onRename: () => _rename(p),
                    onDelete: () => _delete(p),
                    onPush: () => _pushToGithub(p),
                  ),
                  const SizedBox(height: 8),
                ],
              const SizedBox(height: 60),
            ],
          );
        },
      ),
    );
  }
}

class _ActiveSelector extends StatelessWidget {
  final String? activeId;
  final VoidCallback onClear;
  final bool hasProjects;
  const _ActiveSelector({
    required this.activeId,
    required this.onClear,
    required this.hasProjects,
  });

  @override
  Widget build(BuildContext context) {
    if (activeId == null) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF2B2D31),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF1E1F22)),
        ),
        child: Row(
          children: const [
            Icon(Icons.folder_off_outlined, color: Color(0xFF99AAB5), size: 18),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'No active project. Submitted tasks won\'t inherit from any project HEAD.',
                style: TextStyle(color: Color(0xFFC4C9CE), fontSize: 12),
              ),
            ),
          ],
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF7C5CFC).withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF7C5CFC)),
      ),
      child: Row(
        children: [
          const Icon(Icons.folder, color: Color(0xFF7C5CFC), size: 18),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'A project is active. New tasks will inherit its HEAD and merge their artifacts back on success.',
              style: TextStyle(color: Color(0xFFDCDDDE), fontSize: 12),
            ),
          ),
          TextButton(
            onPressed: onClear,
            style: TextButton.styleFrom(foregroundColor: const Color(0xFFB9BBBE)),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }
}

class _ProjectTile extends StatelessWidget {
  final Map<String, dynamic> project;
  final bool isActive;
  final VoidCallback onSelect;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final VoidCallback onPush;
  const _ProjectTile({
    required this.project,
    required this.isActive,
    required this.onSelect,
    required this.onRename,
    required this.onDelete,
    required this.onPush,
  });

  @override
  Widget build(BuildContext context) {
    final description = (project['description'] as String?) ?? '';
    final fileCount = (project['file_count'] as num?)?.toInt() ?? 0;
    return InkWell(
      onTap: onSelect,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF2B2D31),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isActive ? const Color(0xFF7C5CFC) : const Color(0xFF1E1F22),
            width: isActive ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.folder,
              color: isActive ? const Color(0xFF7C5CFC) : const Color(0xFF99AAB5),
              size: 28,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          project['name'] as String,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (isActive) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFF7C5CFC),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: const Text(
                            'Active',
                            style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$fileCount file${fileCount == 1 ? '' : 's'} in HEAD',
                    style: const TextStyle(color: Color(0xFF99AAB5), fontSize: 11),
                  ),
                  if (description.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      description,
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
              onSelected: (a) {
                if (a == 'rename') onRename();
                if (a == 'push') onPush();
                if (a == 'delete') onDelete();
              },
              itemBuilder: (ctx) => const [
                PopupMenuItem(value: 'rename', child: Text('Rename', style: TextStyle(color: Colors.white))),
                PopupMenuItem(value: 'push', child: Text('Push to GitHub', style: TextStyle(color: Colors.white))),
                PopupMenuItem(value: 'delete', child: Text('Delete', style: TextStyle(color: Color(0xFFED4245)))),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _NewProjectDialog extends StatefulWidget {
  const _NewProjectDialog();
  @override
  State<_NewProjectDialog> createState() => _NewProjectDialogState();
}

class _NewProjectDialogState extends State<_NewProjectDialog> {
  final _name = TextEditingController();
  final _desc = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF2B2D31),
      title: const Text('New project', style: TextStyle(color: Colors.white)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              labelText: 'Name',
              labelStyle: TextStyle(color: Color(0xFFB9BBBE)),
            ),
            maxLength: 64,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _desc,
            maxLines: 3,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              labelText: 'Description (optional)',
              labelStyle: TextStyle(color: Color(0xFFB9BBBE)),
              alignLabelWithHint: true,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop((
            name: _name.text,
            description: _desc.text,
          )),
          child: const Text('Create'),
        ),
      ],
    );
  }
}

class _GithubChip extends StatelessWidget {
  final bool? connected;
  final VoidCallback onTap;
  const _GithubChip({required this.connected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isConnected = connected == true;
    final color = isConnected ? const Color(0xFF57F287) : const Color(0xFF99AAB5);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(isConnected ? Icons.check_circle : Icons.code, color: color, size: 14),
              const SizedBox(width: 6),
              Text(
                isConnected ? 'GitHub connected' : 'Connect GitHub',
                style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConnectGithubDialog extends StatefulWidget {
  const _ConnectGithubDialog();
  @override
  State<_ConnectGithubDialog> createState() => _ConnectGithubDialogState();
}

class _ConnectGithubDialogState extends State<_ConnectGithubDialog> {
  final _ctrl = TextEditingController();
  bool _show = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF2B2D31),
      title: const Text('Connect GitHub', style: TextStyle(color: Colors.white)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Paste a GitHub personal access token (classic or fine-grained) "
            "with `repo` scope. It's stored encrypted on the orchestrator "
            "and used only for push operations you trigger.",
            style: TextStyle(color: Color(0xFFB9BBBE), fontSize: 12),
          ),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: () async {
              final url = Uri.parse('https://github.com/settings/personal-access-tokens/new');
              await launchUrl(url, mode: LaunchMode.externalApplication);
            },
            child: const Text(
              'Generate a fine-grained PAT →',
              style: TextStyle(
                color: Color(0xFF7C5CFC),
                fontSize: 12,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            autofocus: true,
            obscureText: !_show,
            style: const TextStyle(color: Colors.white, fontFamily: 'monospace'),
            decoration: InputDecoration(
              labelText: 'Token',
              labelStyle: const TextStyle(color: Color(0xFFB9BBBE)),
              hintText: 'ghp_… or github_pat_…',
              hintStyle: const TextStyle(color: Color(0xFF52555A)),
              suffixIcon: IconButton(
                icon: Icon(_show ? Icons.visibility_off : Icons.visibility,
                    color: const Color(0xFF99AAB5), size: 18),
                onPressed: () => setState(() => _show = !_show),
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(_ctrl.text),
          child: const Text('Connect'),
        ),
      ],
    );
  }
}

class _PushDialog extends StatefulWidget {
  final String projectName;
  const _PushDialog({required this.projectName});
  @override
  State<_PushDialog> createState() => _PushDialogState();
}

class _PushDialogState extends State<_PushDialog> {
  final _repo = TextEditingController();
  final _branch = TextEditingController();
  final _message = TextEditingController();

  @override
  void dispose() {
    _repo.dispose();
    _branch.dispose();
    _message.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF2B2D31),
      title: Text("Push '${widget.projectName}' to GitHub",
          style: const TextStyle(color: Colors.white)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _repo,
            autofocus: true,
            style: const TextStyle(color: Colors.white, fontFamily: 'monospace'),
            decoration: const InputDecoration(
              labelText: 'Repo (owner/repo)',
              labelStyle: TextStyle(color: Color(0xFFB9BBBE)),
              hintText: 'me/my-repo',
              hintStyle: TextStyle(color: Color(0xFF52555A)),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _branch,
            style: const TextStyle(color: Colors.white, fontFamily: 'monospace'),
            decoration: const InputDecoration(
              labelText: 'Branch (optional)',
              labelStyle: TextStyle(color: Color(0xFFB9BBBE)),
              hintText: 'defaults to tally/push-<timestamp>',
              hintStyle: TextStyle(color: Color(0xFF52555A)),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _message,
            maxLines: 3,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              labelText: 'Commit message (optional)',
              labelStyle: TextStyle(color: Color(0xFFB9BBBE)),
              alignLabelWithHint: true,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop((
            repo: _repo.text.trim(),
            branch: _branch.text.trim().isEmpty ? null : _branch.text.trim(),
            message: _message.text.trim().isEmpty ? null : _message.text.trim(),
          )),
          child: const Text('Push'),
        ),
      ],
    );
  }
}

class _PushResultDialog extends StatelessWidget {
  final Map<String, dynamic> result;
  const _PushResultDialog({required this.result});

  @override
  Widget build(BuildContext context) {
    final url = result['branch_url'] as String? ?? '';
    return AlertDialog(
      backgroundColor: const Color(0xFF2B2D31),
      title: const Text('Push succeeded', style: TextStyle(color: Color(0xFF57F287))),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Repo: ${result['repo']}',
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
          const SizedBox(height: 4),
          Text(
            'Branch: ${result['branch']}',
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
          const SizedBox(height: 4),
          Text(
            'Commit: ${(result['commit_sha'] as String? ?? '').substring(0, 8)}',
            style: const TextStyle(color: Color(0xFFB9BBBE), fontSize: 12, fontFamily: 'monospace'),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1F22),
              borderRadius: BorderRadius.circular(4),
            ),
            child: SelectableText(
              url,
              style: const TextStyle(color: Colors.white, fontSize: 12, fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: url));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('URL copied')),
              );
            }
          },
          child: const Text('Copy URL'),
        ),
        TextButton(
          onPressed: () async {
            await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
          },
          child: const Text('Open on GitHub'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
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
      title: const Text('Rename project', style: TextStyle(color: Colors.white)),
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
