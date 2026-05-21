// tally_coding_app/lib/widgets/new_dm_modal.dart
//
// Sprint 49 B6 / Sprint 50 B9: "+ New DM" modal.  Three tabs:
//   - People   (real workspace humans from listWorkspaceMembers filtered to
//               member_kind='human')
//   - Tally    (single entry — the workspace assistant)
//   - Agents   (persistent agents from listPersistentAgents)
//
// Tapping a target calls openDmChannel and pops the channel dict via
// Navigator.pop so the caller can navigate to it.
import 'package:flutter/material.dart';
import '../api.dart';

class NewDmModal extends StatefulWidget {
  final TallyOrchClient client;
  final int workspaceId;
  const NewDmModal({
    super.key,
    required this.client,
    required this.workspaceId,
  });

  @override
  State<NewDmModal> createState() => _NewDmModalState();
}

class _NewDmModalState extends State<NewDmModal>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;
  List<Map<String, dynamic>> _agents = [];
  bool _loadingAgents = true;
  List<Map<String, dynamic>> _humans = [];
  bool _loadingHumans = true;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _loadAgents();
    _loadHumans();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _loadAgents() async {
    try {
      final list = await widget.client
          .listPersistentAgents(workspaceId: widget.workspaceId);
      if (!mounted) return;
      setState(() {
        _agents = list;
        _loadingAgents = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingAgents = false);
    }
  }

  Future<void> _loadHumans() async {
    try {
      final members = await widget.client
          .listWorkspaceMembers(workspaceId: widget.workspaceId);
      if (!mounted) return;
      setState(() {
        _humans = members.where((m) => m['member_kind'] == 'human').toList();
        _loadingHumans = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingHumans = false);
    }
  }

  Future<void> _open(String kind, String? id) async {
    // Capture context-dependent objects before the async gap.
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      final ch = await widget.client
          .openDmChannel(targetKind: kind, targetId: id);
      if (!mounted) return;
      navigator.pop(ch);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Open DM failed: $e')),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Tab content
  // ---------------------------------------------------------------------------

  Widget _peopleTab() {
    if (_loadingHumans) return const Center(child: CircularProgressIndicator());
    if (_humans.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No other people in this workspace yet.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFF949BA4)),
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: _humans.length,
      itemBuilder: (_, i) {
        final m = _humans[i];
        final uid = m['user_id'] as String? ?? '?';
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: const Color(0xFF5865F2),
            child: Text(
              uid.isNotEmpty ? uid[0].toUpperCase() : '?',
              style: const TextStyle(color: Colors.white),
            ),
          ),
          title: Text(uid),
          subtitle: Text(m['role'] as String? ?? ''),
          onTap: () => _open('human', uid),
        );
      },
    );
  }

  Widget _tallyTab() {
    return ListView(
      children: [
        ListTile(
          leading: const CircleAvatar(
            backgroundColor: Color(0xFFF23F43),
            child: Text('T', style: TextStyle(color: Colors.white)),
          ),
          title: const Text('Tally'),
          subtitle: const Text('Your workspace assistant'),
          onTap: () => _open('tally', null),
        ),
      ],
    );
  }

  Widget _agentsTab() {
    if (_loadingAgents) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_agents.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No persistent agents yet.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFF949BA4)),
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: _agents.length,
      itemBuilder: (_, i) {
        final a = _agents[i];
        return ListTile(
          leading: const CircleAvatar(
            backgroundColor: Color(0xFF3BA55D),
            child: Icon(Icons.alarm, color: Colors.white, size: 18),
          ),
          title: Text(a['name'] as String? ?? ''),
          subtitle: Text(a['role_name'] as String? ?? ''),
          onTap: () => _open('persistent_agent', '${a['id']}'),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF313338),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: SizedBox(
        width: 500,
        height: 480,
        child: Column(
          children: [
            AppBar(
              backgroundColor: const Color(0xFF2B2D31),
              foregroundColor: Colors.white,
              title: const Text(
                'New direct message',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              automaticallyImplyLeading: false,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
              ),
              actions: [
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
              bottom: TabBar(
                controller: _tabs,
                labelColor: Colors.white,
                unselectedLabelColor: const Color(0xFF949BA4),
                indicatorColor: const Color(0xFF5865F2),
                tabs: const [
                  Tab(text: 'People'),
                  Tab(text: 'Tally'),
                  Tab(text: 'Agents'),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: [_peopleTab(), _tallyTab(), _agentsTab()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
