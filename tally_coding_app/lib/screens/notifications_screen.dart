// tally_coding_app/lib/screens/notifications_screen.dart
//
// Sprint 46 B7: three-tab notifications screen.
//   • Inbox — dismissible notification list
//   • Alert rules — CRUD for spend-alert rules
//   • Devices — push device registration (UnifiedPush + desktop)
import 'package:flutter/material.dart';
import '../api.dart';
import '../services/unified_push.dart';
import '../services/desktop_notifier.dart';

class NotificationsScreen extends StatelessWidget {
  final TallyOrchClient client;
  const NotificationsScreen({super.key, required this.client});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Notifications'),
          bottom: const TabBar(tabs: [
            Tab(icon: Icon(Icons.inbox), text: 'Inbox'),
            Tab(icon: Icon(Icons.rule), text: 'Alert rules'),
            Tab(icon: Icon(Icons.devices), text: 'Devices'),
          ]),
        ),
        body: TabBarView(children: [
          _InboxTab(client: client),
          _RulesTab(client: client),
          _DevicesTab(client: client),
        ]),
      ),
    );
  }
}

// ─── _InboxTab ───────────────────────────────────────────────────────────────

class _InboxTab extends StatefulWidget {
  final TallyOrchClient client;
  const _InboxTab({required this.client});

  @override
  State<_InboxTab> createState() => _InboxTabState();
}

class _InboxTabState extends State<_InboxTab> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final items = await widget.client.listNotifications();
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _dismiss(int id) async {
    try {
      await widget.client.dismissNotification(id);
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_items.isEmpty) {
      return const Center(child: Text('No notifications yet.'));
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.builder(
        itemCount: _items.length,
        itemBuilder: (ctx, i) {
          final n = _items[i];
          final sev = n['severity'] as String? ?? 'info';
          final icon = sev == 'error'
              ? Icons.error_outline
              : sev == 'warning'
                  ? Icons.warning_amber
                  : Icons.info_outline;
          final color = sev == 'error'
              ? Colors.red
              : sev == 'warning'
                  ? Colors.orange
                  : Colors.blue;
          return Dismissible(
            key: ValueKey(n['id']),
            background: Container(
              color: Colors.green,
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 16),
              child: const Icon(Icons.check, color: Colors.white),
            ),
            onDismissed: (_) => _dismiss(n['id'] as int),
            child: ListTile(
              leading: Icon(icon, color: color),
              title: Text(n['kind'] as String),
              subtitle: Text(n['payload_json'] as String),
            ),
          );
        },
      ),
    );
  }
}

// ─── _RulesTab ───────────────────────────────────────────────────────────────

class _RulesTab extends StatefulWidget {
  final TallyOrchClient client;
  const _RulesTab({required this.client});

  @override
  State<_RulesTab> createState() => _RulesTabState();
}

class _RulesTabState extends State<_RulesTab> {
  List<Map<String, dynamic>> _rules = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final out = await widget.client.listNotificationRules();
      if (!mounted) return;
      setState(() {
        _rules = out;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _add() async {
    final picked = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => const _RuleEditorDialog(),
    );
    if (picked == null) return;
    try {
      await widget.client.createNotificationRule(
        kind: picked['kind'] as String,
        threshold: picked['threshold'] as int,
      );
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _toggle(Map<String, dynamic> rule) async {
    try {
      await widget.client.patchNotificationRule(
        rule['id'] as int,
        enabled: !(rule['enabled'] as bool),
      );
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _delete(int id) async {
    try {
      await widget.client.deleteNotificationRule(id);
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      if (_loading)
        const Center(child: CircularProgressIndicator())
      else if (_rules.isEmpty)
        const Center(child: Text('No alert rules. Tap + to add one.'))
      else
        ListView.builder(
          itemCount: _rules.length,
          itemBuilder: (ctx, i) {
            final r = _rules[i];
            return ListTile(
              leading: Switch(
                value: r['enabled'] as bool,
                onChanged: (_) => _toggle(r),
              ),
              title: Text('${r['kind']} ≥ ${r['threshold']}'),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _delete(r['id'] as int),
              ),
            );
          },
        ),
      Positioned(
        bottom: 16,
        right: 16,
        child: FloatingActionButton(
          onPressed: _add,
          child: const Icon(Icons.add),
        ),
      ),
    ]);
  }
}

// ─── _RuleEditorDialog ───────────────────────────────────────────────────────

class _RuleEditorDialog extends StatefulWidget {
  const _RuleEditorDialog();

  @override
  State<_RuleEditorDialog> createState() => _RuleEditorDialogState();
}

class _RuleEditorDialogState extends State<_RuleEditorDialog> {
  String _kind = 'period_pct';
  final _threshold = TextEditingController(text: '80');

  static const _kinds = [
    ('period_pct', 'Period % used'),
    ('daily_amount', 'Daily credit total'),
    ('weekly_amount', 'Weekly credit total'),
    ('per_task_amount', 'Single task credits'),
    ('auto_recharge_monthly_pct', 'Auto-recharge monthly % used'),
  ];

  @override
  void dispose() {
    _threshold.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New alert rule'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButton<String>(
            value: _kind,
            onChanged: (v) => setState(() => _kind = v!),
            items: [
              for (final (id, label) in _kinds)
                DropdownMenuItem(value: id, child: Text(label)),
            ],
          ),
          TextField(
            controller: _threshold,
            decoration: const InputDecoration(labelText: 'Threshold'),
            keyboardType: TextInputType.number,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final t = int.tryParse(_threshold.text);
            if (t == null || t <= 0) return;
            Navigator.pop(context, {'kind': _kind, 'threshold': t});
          },
          child: const Text('Create'),
        ),
      ],
    );
  }
}

// ─── _DevicesTab ─────────────────────────────────────────────────────────────

class _DevicesTab extends StatefulWidget {
  final TallyOrchClient client;
  const _DevicesTab({required this.client});

  @override
  State<_DevicesTab> createState() => _DevicesTabState();
}

class _DevicesTabState extends State<_DevicesTab> {
  List<Map<String, dynamic>> _devices = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final out = await widget.client.listPushDevices();
      if (!mounted) return;
      setState(() {
        _devices = out;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _addAndroid() async {
    try {
      final endpoint =
          await UnifiedPushManager.instance.registerAndPickEndpoint(context);
      if (endpoint == null) return;
      await widget.client.registerPushDevice(
        provider: 'unifiedpush',
        endpointUrl: endpoint,
        label: 'Android (UnifiedPush)',
        platform: 'android',
      );
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _addDesktop() async {
    try {
      final ok = await DesktopNotifier.instance.requestPermission();
      if (!ok) return;
      await widget.client.registerPushDevice(
        provider: 'desktop_local',
        label: 'Linux desktop',
        platform: 'linux',
      );
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _delete(int id) async {
    try {
      await widget.client.deletePushDevice(id);
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      if (_loading)
        const Center(child: CircularProgressIndicator())
      else
        ListView(children: [
          ..._devices.map((d) => ListTile(
                leading: Icon(
                  d['provider'] == 'unifiedpush'
                      ? Icons.android
                      : Icons.desktop_windows,
                ),
                title: Text(d['label'] as String? ?? d['provider'] as String),
                subtitle: Text(
                    '${d['provider']} · ${d['platform'] ?? 'unknown'}'),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _delete(d['id'] as int),
                ),
              )),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.add_to_home_screen),
            title: const Text('Add Android device (UnifiedPush)'),
            subtitle: const Text(
                'Privacy-respecting push via your distributor'),
            onTap: _addAndroid,
          ),
          ListTile(
            leading: const Icon(Icons.desktop_windows),
            title: const Text('Add desktop notifications'),
            subtitle: const Text('Native libnotify on Linux'),
            onTap: _addDesktop,
          ),
        ]),
    ]);
  }
}
