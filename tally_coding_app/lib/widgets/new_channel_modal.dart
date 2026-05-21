// tally_coding_app/lib/widgets/new_channel_modal.dart
//
// Sprint 50 B6: create a custom channel with mixed-kind members.
// Returns the created channel dict via Navigator.pop, or null on cancel.
import 'package:flutter/material.dart';
import '../api.dart';

class NewChannelModal extends StatefulWidget {
  final TallyOrchClient client;
  final int workspaceId;
  const NewChannelModal({super.key, required this.client, required this.workspaceId});

  @override
  State<NewChannelModal> createState() => _NewChannelModalState();
}

class _NewChannelModalState extends State<NewChannelModal> {
  final _nameCtrl = TextEditingController();
  List<Map<String, dynamic>> _humans = [];
  List<Map<String, dynamic>> _agents = [];
  bool _loading = true;
  bool _saving = false;

  final Set<String> _selectedHumans = {};   // user_ids
  bool _includeTally = false;
  final Set<int> _selectedAgents = {};      // agent ids

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final humans = await widget.client.listWorkspaceMembers(workspaceId: widget.workspaceId);
      final agents = await widget.client.listPersistentAgents(workspaceId: widget.workspaceId);
      if (!mounted) return;
      setState(() {
        _humans = humans.where((m) => m['member_kind'] == 'human').toList();
        _agents = agents;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _submit() async {
    if (_saving) return;
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Name required')));
      return;
    }
    setState(() => _saving = true);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final members = <Map<String, dynamic>>[];
      for (final uid in _selectedHumans) {
        members.add({'kind': 'human', 'id': uid});
      }
      if (_includeTally) members.add({'kind': 'tally'});
      for (final aid in _selectedAgents) {
        members.add({'kind': 'persistent_agent', 'id': '$aid'});
      }
      final ch = await widget.client.createCustomChannel(
        workspaceId: widget.workspaceId,
        name: name,
        members: members,
      );
      navigator.pop(ch);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Create failed: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _section(String label, Widget body) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          body,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: SizedBox(
        width: 480,
        height: 560,
        child: Column(
          children: [
            AppBar(
              title: const Text('New channel'),
              automaticallyImplyLeading: false,
              actions: [
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
              ],
            ),
            if (_loading)
              const Expanded(child: Center(child: CircularProgressIndicator()))
            else
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: _nameCtrl,
                        decoration: const InputDecoration(labelText: 'Channel name', hintText: 'e.g. code-review'),
                        autofocus: true,
                      ),
                      _section('Humans', Wrap(
                        spacing: 8,
                        children: [
                          for (final m in _humans)
                            FilterChip(
                              label: Text(m['user_id'] as String? ?? '?'),
                              selected: _selectedHumans.contains(m['user_id']),
                              onSelected: (s) => setState(() {
                                final uid = m['user_id'] as String;
                                if (s) { _selectedHumans.add(uid); }
                                else { _selectedHumans.remove(uid); }
                              }),
                            ),
                        ],
                      )),
                      _section('Tally', FilterChip(
                        label: const Text('Include Tally'),
                        selected: _includeTally,
                        onSelected: (s) => setState(() => _includeTally = s),
                      )),
                      _section('Persistent agents', Wrap(
                        spacing: 8,
                        children: [
                          if (_agents.isEmpty)
                            const Text('No persistent agents yet.',
                              style: TextStyle(color: Color(0xFF949BA4), fontSize: 12)),
                          for (final a in _agents)
                            FilterChip(
                              label: Text(a['name'] as String? ?? '?'),
                              selected: _selectedAgents.contains(a['id']),
                              onSelected: (s) => setState(() {
                                final aid = a['id'] as int;
                                if (s) { _selectedAgents.add(aid); }
                                else { _selectedAgents.remove(aid); }
                              }),
                            ),
                        ],
                      )),
                    ],
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
                  const SizedBox(width: 8),
                  ElevatedButton(onPressed: _saving ? null : _submit,
                    child: Text(_saving ? 'Creating…' : 'Create')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
