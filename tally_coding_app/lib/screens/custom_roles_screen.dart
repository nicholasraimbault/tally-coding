import 'package:flutter/material.dart';

import '../api.dart';

/// Sprint 40: custom user-defined agent roles.  Lists seeded roles
/// (read-only) alongside the user's own custom roles (full CRUD),
/// so the user can see the entire palette + manage their own
/// additions in one place.
class CustomRolesScreen extends StatefulWidget {
  final TallyOrchClient client;
  const CustomRolesScreen({super.key, required this.client});

  @override
  State<CustomRolesScreen> createState() => _CustomRolesScreenState();
}

// Tool palette + model allow-list mirror what the orchestrator
// accepts on POST /agent_roles.  Keep these in sync if the
// orchestrator's _ALLOWED_* sets grow.
const _kAllowedModels = [
  'meta-llama/llama-3.3-70b-instruct',
  'moonshotai/kimi-k2-instruct',
  'moonshotai/kimi-k2.6-instruct',
  'deepseek/deepseek-r1-0528',
  'deepseek/deepseek-v3.2',
];
const _kAllowedTools = [
  'file_editor',
  'file_editor_read',
  'bash',
  'bash_read',
  'browser',
];

class _CustomRolesScreenState extends State<CustomRolesScreen> {
  Future<List<Map<String, dynamic>>>? _list;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    setState(() => _list = widget.client.listAgentRoles());
  }

  Future<void> _create() async {
    final result = await showDialog<_RoleFormResult>(
      context: context,
      builder: (ctx) => const _RoleFormDialog(initial: null),
    );
    if (result == null) return;
    try {
      await widget.client.createCustomRole(
        name: result.name,
        description: result.description,
        defaultModel: result.defaultModel,
        tools: result.tools,
        systemPrompt: result.systemPrompt,
      );
      if (!mounted) return;
      _refresh();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Custom role '${result.name}' saved.")),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _edit(Map<String, dynamic> role) async {
    final result = await showDialog<_RoleFormResult>(
      context: context,
      builder: (ctx) => _RoleFormDialog(initial: role),
    );
    if (result == null) return;
    try {
      await widget.client.patchCustomRole(
        role['name'] as String,
        description: result.description,
        defaultModel: result.defaultModel,
        tools: result.tools,
        systemPrompt: result.systemPrompt,
      );
      if (!mounted) return;
      _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _delete(Map<String, dynamic> role) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2B2D31),
        title: Text("Delete '${role['name']}'?",
            style: const TextStyle(color: Colors.white)),
        content: const Text(
          'Tasks already running with this role are unaffected — '
          'they read the role spec from their team_spec column. '
          'New task submissions will no longer see this role in the palette.',
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
      await widget.client.deleteCustomRole(role['name'] as String);
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
        title: const Text('Agent roles'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _refresh),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFF7C5CFC),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('New custom role'),
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
          final roles = snap.data ?? const [];
          final seeded = roles.where((r) => r['source'] == 'seeded').toList();
          final custom = roles.where((r) => r['source'] == 'custom').toList();
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (custom.isNotEmpty) ...[
                const _SectionHeader('Your custom roles'),
                for (final r in custom) ...[
                  _RoleTile(
                    role: r,
                    onTap: () => _edit(r),
                    onDelete: () => _delete(r),
                  ),
                  const SizedBox(height: 8),
                ],
                const SizedBox(height: 20),
              ],
              const _SectionHeader('Seeded roles (read-only)'),
              for (final r in seeded) ...[
                _RoleTile(role: r, onTap: null, onDelete: null),
                const SizedBox(height: 8),
              ],
              const SizedBox(height: 80),
            ],
          );
        },
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader(this.label);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 0, 6),
      child: Text(
        label,
        style: const TextStyle(
          color: Color(0xFF8E9297),
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class _RoleTile extends StatelessWidget {
  final Map<String, dynamic> role;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;
  const _RoleTile({required this.role, required this.onTap, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final isCustom = role['source'] == 'custom';
    final tools = (role['tools'] as List?)?.cast<String>() ?? const [];
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF2B2D31),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isCustom ? const Color(0xFF7C5CFC) : const Color(0xFF1E1F22),
            width: isCustom ? 1.2 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 36, height: 36,
              decoration: BoxDecoration(
                color: (isCustom ? const Color(0xFF7C5CFC) : const Color(0xFF4E5058))
                    .withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(18),
              ),
              alignment: Alignment.center,
              child: Text(
                (role['name'] as String).characters.first.toUpperCase(),
                style: TextStyle(
                  color: isCustom ? const Color(0xFF7C5CFC) : Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    role['name'] as String,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    (role['description'] as String?) ?? '',
                    style: const TextStyle(color: Color(0xFFB9BBBE), fontSize: 12),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Model: ${role['default_model']}  •  ${tools.length} tool${tools.length == 1 ? '' : 's'}',
                    style: const TextStyle(color: Color(0xFF8E9297), fontSize: 11),
                  ),
                ],
              ),
            ),
            if (onDelete != null)
              IconButton(
                icon: const Icon(Icons.delete_outline, color: Color(0xFFED4245), size: 20),
                tooltip: 'Delete',
                onPressed: onDelete,
              ),
          ],
        ),
      ),
    );
  }
}

class _RoleFormResult {
  final String name;
  final String description;
  final String defaultModel;
  final List<String> tools;
  final String systemPrompt;
  _RoleFormResult({
    required this.name,
    required this.description,
    required this.defaultModel,
    required this.tools,
    required this.systemPrompt,
  });
}

/// Dialog for both create + edit.  When ``initial`` is null we're
/// creating; otherwise editing (name field is locked since rename
/// isn't supported on the backend yet).
class _RoleFormDialog extends StatefulWidget {
  final Map<String, dynamic>? initial;
  const _RoleFormDialog({required this.initial});

  @override
  State<_RoleFormDialog> createState() => _RoleFormDialogState();
}

class _RoleFormDialogState extends State<_RoleFormDialog> {
  late final TextEditingController _name;
  late final TextEditingController _description;
  late String _model;
  late final Set<String> _tools;
  late final TextEditingController _systemPrompt;

  @override
  void initState() {
    super.initState();
    final init = widget.initial;
    _name = TextEditingController(text: (init?['name'] as String?) ?? '');
    _description = TextEditingController(text: (init?['description'] as String?) ?? '');
    _model = (init?['default_model'] as String?) ?? _kAllowedModels.first;
    _tools = {...?((init?['tools'] as List?)?.cast<String>())};
    if (_tools.isEmpty && init == null) _tools.add('file_editor');
    _systemPrompt = TextEditingController(text: (init?['system_prompt'] as String?) ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _systemPrompt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.initial != null;
    return AlertDialog(
      backgroundColor: const Color(0xFF2B2D31),
      title: Text(isEdit ? 'Edit custom role' : 'New custom role',
          style: const TextStyle(color: Colors.white)),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _name,
                enabled: !isEdit,
                autofocus: !isEdit,
                style: const TextStyle(color: Colors.white, fontFamily: 'monospace'),
                decoration: InputDecoration(
                  labelText: 'Name',
                  labelStyle: const TextStyle(color: Color(0xFFB9BBBE)),
                  helperText: isEdit ? 'Rename not supported — drop + recreate' : null,
                  helperStyle: const TextStyle(color: Color(0xFF8E9297)),
                ),
                maxLength: 64,
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _description,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Description (what the architect sees)',
                  labelStyle: TextStyle(color: Color(0xFFB9BBBE)),
                ),
                maxLength: 200,
              ),
              const SizedBox(height: 6),
              DropdownButtonFormField<String>(
                value: _model,
                dropdownColor: const Color(0xFF1E1F22),
                style: const TextStyle(color: Colors.white, fontFamily: 'monospace'),
                decoration: const InputDecoration(
                  labelText: 'Default model',
                  labelStyle: TextStyle(color: Color(0xFFB9BBBE)),
                ),
                items: [
                  for (final m in _kAllowedModels)
                    DropdownMenuItem(value: m, child: Text(m, style: const TextStyle(fontSize: 13))),
                ],
                onChanged: (v) => setState(() => _model = v ?? _model),
              ),
              const SizedBox(height: 12),
              const Text('Tools',
                  style: TextStyle(color: Color(0xFFB9BBBE), fontSize: 12, fontWeight: FontWeight.w600)),
              Wrap(
                spacing: 6,
                children: [
                  for (final tool in _kAllowedTools)
                    FilterChip(
                      label: Text(tool, style: const TextStyle(fontSize: 11)),
                      selected: _tools.contains(tool),
                      onSelected: (sel) => setState(() {
                        if (sel) {
                          _tools.add(tool);
                        } else {
                          _tools.remove(tool);
                        }
                      }),
                      selectedColor: const Color(0xFF7C5CFC).withValues(alpha: 0.35),
                      backgroundColor: const Color(0xFF1E1F22),
                      labelStyle: TextStyle(
                        color: _tools.contains(tool) ? Colors.white : const Color(0xFFB9BBBE),
                      ),
                      checkmarkColor: Colors.white,
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _systemPrompt,
                maxLines: 8,
                minLines: 4,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: const InputDecoration(
                  labelText: 'System prompt (sent to the worker for each agent run)',
                  labelStyle: TextStyle(color: Color(0xFFB9BBBE)),
                  alignLabelWithHint: true,
                ),
                maxLength: 8192,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: () {
            final n = _name.text.trim();
            if (n.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Name is required')),
              );
              return;
            }
            if (_systemPrompt.text.trim().isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('System prompt is required')),
              );
              return;
            }
            Navigator.of(context).pop(_RoleFormResult(
              name: n,
              description: _description.text.trim(),
              defaultModel: _model,
              tools: _tools.toList(),
              systemPrompt: _systemPrompt.text,
            ));
          },
          child: Text(isEdit ? 'Save' : 'Create'),
        ),
      ],
    );
  }
}
