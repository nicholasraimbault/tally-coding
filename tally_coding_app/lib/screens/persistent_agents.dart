// tally_coding_app/lib/screens/persistent_agents.dart
//
// Sprint 49: list + manage persistent agents.  Reached from the channel
// rail's "Scheduled" category (+New tile).
import 'package:flutter/material.dart';
import '../api.dart';
import 'workflow_editor.dart';

class PersistentAgentsScreen extends StatefulWidget {
  final TallyOrchClient client;
  final int workspaceId;
  const PersistentAgentsScreen({super.key, required this.client, required this.workspaceId});

  @override
  State<PersistentAgentsScreen> createState() => _PersistentAgentsScreenState();
}

class _PersistentAgentsScreenState extends State<PersistentAgentsScreen> {
  List<Map<String, dynamic>> _agents = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final list = await widget.client.listPersistentAgents(workspaceId: widget.workspaceId);
      if (!mounted) return;
      setState(() { _agents = list; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _onAction(String action, Map<String, dynamic> agent) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      switch (action) {
        case 'edit':
          final spec = Map<String, dynamic>.from(agent['team_spec'] as Map? ?? {});
          await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => WorkflowEditorScreen(
              client: widget.client,
              persistentAgentId: agent['id'] as int,
              initialTeamSpec: spec,
            ),
          ));
          if (mounted) await _load();
          break;
        case 'run_now':
          await widget.client.runPersistentAgentNow(id: agent['id'] as int);
          if (mounted) {
            messenger.showSnackBar(const SnackBar(content: Text('Fired')));
            await _load();
          }
          break;
        case 'toggle':
          final newEnabled = !(agent['enabled'] as bool);
          await widget.client.updatePersistentAgent(
            id: agent['id'] as int,
            patch: {'enabled': newEnabled},
          );
          if (mounted) await _load();
          break;
        case 'delete':
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Delete persistent agent?'),
              content: Text('${agent['name']} will be soft-deleted. Its history is preserved.'),
              actions: [
                TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
                TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Delete')),
              ],
            ),
          );
          if (confirmed == true) {
            await widget.client.deletePersistentAgent(id: agent['id'] as int);
            if (mounted) await _load();
          }
          break;
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('$action failed: $e')));
      }
    }
  }

  Widget _agentTile(Map<String, dynamic> agent) {
    final cron = agent['cron_schedule'] as String?;
    final enabled = (agent['enabled'] as bool?) ?? true;
    final consecutiveFailures = (agent['consecutive_failures'] as int?) ?? 0;
    final subtitle = cron != null && cron.isNotEmpty
        ? 'cron: $cron'
        : 'event triggers only';
    return ListTile(
      leading: Icon(
        enabled ? Icons.check_circle : Icons.pause_circle,
        color: enabled ? const Color(0xFF3BA55D) : const Color(0xFFF0B232),
      ),
      title: Text(agent['name'] as String? ?? ''),
      subtitle: Text(
        consecutiveFailures > 0 ? '$subtitle · $consecutiveFailures failure(s)' : subtitle,
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (action) => _onAction(action, agent),
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'edit', child: Text('Edit')),
          PopupMenuItem(value: 'run_now', child: Text('Run now')),
          PopupMenuItem(value: 'toggle', child: Text('Enable / Disable')),
          PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scheduled agents')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text('Error: $_error'))
              : _agents.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('No persistent agents yet. Create one with the + button.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Color(0xFF949BA4))),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.builder(
                        itemCount: _agents.length,
                        itemBuilder: (_, i) => _agentTile(_agents[i]),
                      ),
                    ),
    );
  }
}
