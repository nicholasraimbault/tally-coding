/// Sprint 25: Discord-shaped top-level UI.
///
///   ┌───┬──────────┬──────────────────────────┬──────────┐
///   │ S │ #general │  agent timeline / chat   │ MEMBERS  │
///   │ E │ #task-1  │                          │          │
///   │ R │ #task-2  │                          │ ✨ Tally │
///   │ V │          │                          │ 📋 Pl... │
///   │ E │          │                          │ 👤 Co... │
///   │ R │          │                          │          │
///   └───┴──────────┴──────────────────────────┴──────────┘
///     ↑      ↑                  ↑                  ↑
///   teams  channels       channel content      members
///
/// One team for now ("My Team"). The selected channel drives both the
/// main pane and the members sidebar.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../agent_roles.dart';
import '../api.dart';
import '../main.dart';
import '../services/notifications_ws.dart';
import '../state/workspace_context.dart';
import 'billing_screen.dart';
import 'custom_roles_screen.dart';
import 'general_channel.dart';
import 'notifications_screen.dart';
import 'persistent_agents.dart';
import 'projects_screen.dart';
import 'task_channel.dart';
import 'templates_screen.dart';
import '../widgets/new_dm_modal.dart';

/// The channel selection in the shell. `general` is the sentinel for
/// the architect chat; otherwise it's a task ID or a direct channel id.
sealed class ChannelSelection {
  const ChannelSelection();
}

class GeneralSelected extends ChannelSelection {
  const GeneralSelected();
}

class TaskSelected extends ChannelSelection {
  final String taskId;
  const TaskSelected(this.taskId);
}

/// Sprint 49 B7: DM or scheduled_agent channel opened by direct channel id.
class DirectChannelSelected extends ChannelSelection {
  final int channelId;
  final String channelName;
  const DirectChannelSelected(this.channelId, this.channelName);
}

class DiscordShellScreen extends StatefulWidget {
  final TallyOrchClient client;
  final NotificationsWsClient wsClient;
  /// Optional: when set, the shell opens with this task channel selected
  /// instead of #general. Used by the dev/screenshot deep-link.
  final String? initialTaskId;
  const DiscordShellScreen({
    super.key,
    required this.client,
    required this.wsClient,
    this.initialTaskId,
  });

  @override
  State<DiscordShellScreen> createState() => _DiscordShellScreenState();
}

class _DiscordShellScreenState extends State<DiscordShellScreen> {
  List<Task> _tasks = const [];
  bool _loading = true;
  String? _error;
  Timer? _refresh;
  Timer? _healthRefresh;
  late ChannelSelection _selected;
  // Sprint 35: pool readiness from /health, polled every 5s while not
  // ready so the banner disappears within a few seconds of bootstrap
  // completing without needing the user to touch anything.
  bool? _poolReady;
  int _poolTarget = 0;
  int _poolJoined = 0;
  String? _poolLastError;
  // Sprint 37: id of the user's current "active project".  Null = one-off
  // task mode (legacy behaviour).  Threaded into the composer so newly
  // submitted tasks inherit the project's HEAD artifact set.
  String? _activeProjectId;
  // Sprint 49 B7: DM and scheduled_agent channels loaded from the API.
  List<Map<String, dynamic>> _dmChannels = const [];
  List<Map<String, dynamic>> _scheduledChannels = const [];

  @override
  void initState() {
    super.initState();
    _selected = widget.initialTaskId != null
        ? TaskSelected(widget.initialTaskId!)
        : const GeneralSelected();
    _fetch();
    _fetchDirectChannels();
    _pollHealth();
    _refresh = Timer.periodic(const Duration(seconds: 4), (_) => _fetch());
    _healthRefresh = Timer.periodic(
      const Duration(seconds: 5),
      (_) {
        if (_poolReady != true) _pollHealth();
      },
    );
  }

  @override
  void dispose() {
    _refresh?.cancel();
    _healthRefresh?.cancel();
    super.dispose();
  }

  Future<void> _fetch() async {
    try {
      final tasks = await widget.client.listTasks(limit: 200);
      if (!mounted) return;
      setState(() {
        _tasks = _sortForChannelList(tasks);
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _pollHealth() async {
    try {
      final h = await widget.client.health();
      if (!mounted) return;
      setState(() {
        _poolReady = h['pool_ready'] as bool? ?? true;
        _poolTarget = (h['pool_target'] as num?)?.toInt() ?? 0;
        _poolJoined = (h['pool_joined'] as num?)?.toInt() ?? 0;
        _poolLastError = h['pool_last_error'] as String?;
      });
    } catch (_) {
      // Network error: leave previous state; the banner will surface if
      // pool was already known-not-ready, otherwise it stays hidden.
    }
  }

  /// Active first (running > pending > recovering), then completed/failed
  /// in reverse-chronological order — matches the locked UX memo
  /// ("completed below active").
  List<Task> _sortForChannelList(List<Task> tasks) {
    int statusRank(String s) => switch (s) {
          'running' => 0,
          'pending' => 1,
          'recovering' => 2,
          _ => 3,
        };
    final sorted = [...tasks];
    sorted.sort((a, b) {
      final r = statusRank(a.status).compareTo(statusRank(b.status));
      if (r != 0) return r;
      return b.createdAt.compareTo(a.createdAt);
    });
    return sorted;
  }

  /// Called by GeneralChannelScreen after the user submits a task and
  /// the architect responds. Refresh + jump to the new channel.
  Future<void> _onTaskSubmitted(Task t) async {
    await _fetch();
    if (!mounted) return;
    setState(() => _selected = TaskSelected(t.id));
  }

  /// Sprint 49 B7: load DM and scheduled_agent channels from the API,
  /// then check escalation status on each scheduled_agent channel.
  Future<void> _fetchDirectChannels() async {
    try {
      final channels = await widget.client.listChannels(
        workspaceId: WorkspaceContext.activeIdOrDefault(context),
      );
      if (!mounted) return;
      final dms = channels.where((c) => c['kind'] == 'dm').toList();
      final scheduled = channels
          .where((c) => c['kind'] == 'scheduled_agent')
          .toList();
      setState(() {
        _dmChannels = dms;
        _scheduledChannels = scheduled;
      });
      await _loadEscalationStatus(scheduled);
    } catch (e) {
      debugPrint('discord_shell: failed to load direct channels: $e');
    }
  }

  /// Sprint 49 B7: for each scheduled_agent channel, fetch the latest
  /// message. If it is kind='escalation', mark the channel with an
  /// '_unread_escalation' flag so the rail can show an orange dot.
  ///
  /// This is the Sprint 49 simplest path (N extra GET /messages?limit=1
  /// calls). Sprint 50+ can add a server-side unread_kinds field.
  Future<void> _loadEscalationStatus(
    List<Map<String, dynamic>> scheduledChannels,
  ) async {
    var changed = false;
    for (final ch in scheduledChannels) {
      try {
        final msgs = await widget.client.getMessages(
          channelId: ch['id'] as int,
          limit: 1,
        );
        if (msgs.isNotEmpty && msgs.first['kind'] == 'escalation') {
          ch['_unread_escalation'] = true;
          changed = true;
        }
      } catch (_) {/* non-critical */}
    }
    if (changed && mounted) setState(() {});
  }

/// Sprint 33-rest: server rail 💳 → push the billing screen.
  Future<void> _openBilling(BuildContext context) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => BillingScreen(
          client: widget.client,
        ),
      ),
    );
  }

  /// Sprint 34: server rail 📋 → saved templates catalogue.
  Future<void> _openTemplates(BuildContext context) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => TemplatesScreen(client: widget.client),
      ),
    );
  }

  /// Sprint 37: server rail 📁 → projects catalogue.  Setting an active
  /// project re-renders the composer with the project context so new
  /// tasks inherit its HEAD artifact set.
  Future<void> _openProjects(BuildContext context) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ProjectsScreen(
          client: widget.client,
          activeProjectId: _activeProjectId,
          onSelectActive: (id) => setState(() => _activeProjectId = id),
        ),
      ),
    );
  }

  /// Sprint 40: server rail 🧑‍💻 → custom agent roles catalogue.
  Future<void> _openCustomRoles(BuildContext context) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => CustomRolesScreen(client: widget.client),
      ),
    );
  }

  /// Sprint 46 B7: server rail 🔔 → notifications screen (inbox + rules +
  /// devices).
  Future<void> _openNotifications(BuildContext context) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => NotificationsScreen(client: widget.client),
      ),
    );
  }

  /// Sprint 31: width threshold below which the shell collapses from
  /// four panes to one. Wide → keep desktop layout; narrow → AppBar +
  /// drawer (channels) + bottom sheet (members). 1100px lands on a
  /// natural break — phones / portrait tablets are below, desktops +
  /// landscape tablets above.
  static const double _narrowBreakpoint = 1100;
  /// `--dart-define=TALLY_FORCE_NARROW=true` forces the narrow layout
  /// regardless of window width — used by Sprint 31's smoke test on a
  /// machine without an Android emulator + a maximized desktop window.
  static const bool _forceNarrow =
      bool.fromEnvironment('TALLY_FORCE_NARROW', defaultValue: false);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final isNarrow = _forceNarrow || constraints.maxWidth < _narrowBreakpoint;
      return isNarrow ? _buildNarrow(context) : _buildWide(context);
    });
  }

  Widget _buildWide(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            if (_poolReady == false)
              _PoolWarmingBanner(
                target: _poolTarget,
                joined: _poolJoined,
                lastError: _poolLastError,
              ),
            Expanded(
              child: Row(
                children: [
                  _ServerRail(
                    onSignOut: () => resetTallyConfig(context),
                    onOpenBilling: () => _openBilling(context),
                    onOpenTemplates: () => _openTemplates(context),
                    onOpenProjects: () => _openProjects(context),
                    onOpenCustomRoles: () => _openCustomRoles(context),
                    onOpenNotifications: () => _openNotifications(context),
                  ),
                  Container(width: 1, color: cs.outlineVariant.withValues(alpha: 0.3)),
                  _ChannelList(
                    tasks: _tasks,
                    selected: _selected,
                    loading: _loading && _tasks.isEmpty,
                    error: _error,
                    onSelect: (sel) => setState(() => _selected = sel),
                    onRetry: _fetch,
                    dmChannels: _dmChannels,
                    scheduledChannels: _scheduledChannels,
                    onNewScheduled: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => PersistentAgentsScreen(
                          client: widget.client,
                          workspaceId: WorkspaceContext.of(context).activeWorkspaceId,
                        ),
                      ),
                    ),
                    onNewDm: () async {
                      final result = await showDialog<Map<String, dynamic>>(
                        context: context,
                        builder: (_) => NewDmModal(
                          client: widget.client,
                          workspaceId: WorkspaceContext.of(context).activeWorkspaceId,
                        ),
                      );
                      if (result != null && mounted) {
                        // Reload channels so any new DM appears in the rail.
                        await _fetch();
                        await _fetchDirectChannels();
                      }
                    },
                  ),
                  Container(width: 1, color: cs.outlineVariant.withValues(alpha: 0.3)),
                  Expanded(child: _mainPane()),
                  Container(width: 1, color: cs.outlineVariant.withValues(alpha: 0.3)),
                  _MembersPanel(selected: _selected, tasks: _tasks),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNarrow(BuildContext context) {
    final channelTitle = switch (_selected) {
      GeneralSelected() => '#general',
      TaskSelected(taskId: final id) => '#${id.substring(0, 8)}',
      DirectChannelSelected(channelName: final name) => '#$name',
    };
    return Scaffold(
      backgroundColor: const Color(0xFF313338),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1F22),
        foregroundColor: Colors.white,
        title: Text(channelTitle,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
        actions: [
          IconButton(
            tooltip: 'Members / agents',
            icon: const Icon(Icons.people),
            onPressed: () => _showMembersSheet(context),
          ),
        ],
      ),
      drawer: _NarrowDrawer(
        tasks: _tasks,
        selected: _selected,
        loading: _loading && _tasks.isEmpty,
        error: _error,
        dmChannels: _dmChannels,
        scheduledChannels: _scheduledChannels,
        onSelect: (sel) {
          setState(() => _selected = sel);
          Navigator.of(context).pop();
        },
        onRetry: _fetch,
        onOpenBilling: () {
          Navigator.of(context).pop();
          _openBilling(context);
        },
        onOpenTemplates: () {
          Navigator.of(context).pop();
          _openTemplates(context);
        },
        onOpenProjects: () {
          Navigator.of(context).pop();
          _openProjects(context);
        },
        onOpenNotifications: () {
          Navigator.of(context).pop();
          _openNotifications(context);
        },
        onSignOut: () => resetTallyConfig(context),
        onNewScheduled: () {
          Navigator.of(context).pop();
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => PersistentAgentsScreen(
                client: widget.client,
                workspaceId: WorkspaceContext.of(context).activeWorkspaceId,
              ),
            ),
          );
        },
        onNewDm: () async {
          Navigator.of(context).pop(); // close the drawer first
          final result = await showDialog<Map<String, dynamic>>(
            context: context,
            builder: (_) => NewDmModal(
              client: widget.client,
              workspaceId: WorkspaceContext.of(context).activeWorkspaceId,
            ),
          );
          if (result != null && mounted) {
            // Reload channels so any new DM appears in the rail.
            await _fetch();
            await _fetchDirectChannels();
          }
        },
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            if (_poolReady == false)
              _PoolWarmingBanner(
                target: _poolTarget,
                joined: _poolJoined,
                lastError: _poolLastError,
              ),
            Expanded(child: _mainPane()),
          ],
        ),
      ),
    );
  }

  void _showMembersSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF2B2D31),
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        expand: false,
        builder: (ctx, scroll) {
          return Column(
            children: [
              Container(
                margin: const EdgeInsets.symmetric(vertical: 8),
                width: 32,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFF4F545C),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Expanded(
                child: _MembersPanel(
                  selected: _selected,
                  tasks: _tasks,
                  scrollController: scroll,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _mainPane() {
    return switch (_selected) {
      GeneralSelected() => GeneralChannelScreen(
          client: widget.client,
          recentTasks: _tasks,
          onTaskSubmitted: _onTaskSubmitted,
          activeProjectId: _activeProjectId,
        ),
      TaskSelected(taskId: final id) => TaskChannelScreen(
          key: ValueKey('task-$id'),
          client: widget.client,
          taskId: id,
          wsClient: widget.wsClient,
        ),
      // Sprint 49 B7: DM / scheduled_agent channels open via directChannelId.
      DirectChannelSelected(channelId: final cid, channelName: final name) =>
        TaskChannelScreen(
          key: ValueKey('ch-$cid'),
          client: widget.client,
          wsClient: widget.wsClient,
          directChannelId: cid,
          channelTitle: name,
        ),
    };
  }
}

/// Sprint 35: top-of-shell banner shown while the orchestrator's
/// worker pool is still bootstrapping (or has failed to bootstrap).
/// Lets the user see WHY task submission is currently 503'ing without
/// having to read CVM logs.  Hides itself the moment pool_ready flips
/// to true (driven by the 5 s /health poll).
class _PoolWarmingBanner extends StatelessWidget {
  final int target;
  final int joined;
  final String? lastError;
  const _PoolWarmingBanner({
    required this.target,
    required this.joined,
    required this.lastError,
  });

  @override
  Widget build(BuildContext context) {
    final hasError = lastError != null;
    final color = hasError ? const Color(0xFFED4245) : const Color(0xFFFAA61A);
    final icon = hasError ? Icons.error_outline : Icons.hourglass_top;
    final headline = hasError
        ? 'Workers offline — orchestrator is retrying.'
        : 'Workers warming up ($joined / $target joined)…';
    return Container(
      width: double.infinity,
      color: color.withValues(alpha: 0.18),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  headline,
                  style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 13),
                ),
                if (hasError && lastError != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    lastError!,
                    style: const TextStyle(color: Color(0xFFC4C9CE), fontSize: 11),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ] else ...[
                  const SizedBox(height: 2),
                  const Text(
                    "Task submission will fail until at least one worker joins. Reads + billing keep working.",
                    style: TextStyle(color: Color(0xFFC4C9CE), fontSize: 11),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Leftmost narrow rail. One server (this team) + a settings button +
/// Sprint 30's team builder entry + Sprint 33's billing entry +
/// Sprint 34's templates catalogue entry.
class _ServerRail extends StatelessWidget {
  final VoidCallback onSignOut;
  final VoidCallback onOpenBilling;
  final VoidCallback onOpenTemplates;
  final VoidCallback onOpenProjects;
  final VoidCallback onOpenCustomRoles;
  final VoidCallback onOpenNotifications;
  const _ServerRail({
    required this.onSignOut,
    required this.onOpenBilling,
    required this.onOpenTemplates,
    required this.onOpenProjects,
    required this.onOpenCustomRoles,
    required this.onOpenNotifications,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 72,
      color: const Color(0xFF1E1F22),
      child: Column(
        children: [
          const SizedBox(height: 12),
          _ServerTile(
            label: 'T',
            tooltip: 'My Team',
            selected: true,
            background: const Color(0xFF7C5CFC),
          ),
          const SizedBox(height: 8),
          const Divider(color: Color(0xFF2B2D31), thickness: 2, indent: 16, endIndent: 16),
          IconButton(
            tooltip: 'Projects',
            icon: const Icon(Icons.folder_outlined, color: Color(0xFF99AAB5)),
            onPressed: onOpenProjects,
          ),
          IconButton(
            tooltip: 'Saved templates',
            icon: const Icon(Icons.bookmark_border, color: Color(0xFF99AAB5)),
            onPressed: onOpenTemplates,
          ),
          IconButton(
            tooltip: 'Agent roles',
            icon: const Icon(Icons.psychology_outlined, color: Color(0xFF99AAB5)),
            onPressed: onOpenCustomRoles,
          ),
          IconButton(
            tooltip: 'Billing & usage',
            icon: const Icon(Icons.credit_card, color: Color(0xFF99AAB5)),
            onPressed: onOpenBilling,
          ),
          IconButton(
            tooltip: 'Notifications',
            icon: const Icon(Icons.notifications_outlined,
                color: Color(0xFF99AAB5)),
            onPressed: onOpenNotifications,
          ),
          const Spacer(),
          IconButton(
            tooltip: 'Sign out / reconnect',
            icon: const Icon(Icons.logout, color: Color(0xFF99AAB5)),
            onPressed: onSignOut,
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _ServerTile extends StatelessWidget {
  final String label;
  final String tooltip;
  final bool selected;
  final Color background;
  const _ServerTile({
    required this.label,
    required this.tooltip,
    required this.selected,
    required this.background,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(selected ? 14 : 24),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 18,
          ),
        ),
      ),
    );
  }
}

/// Channel list (column 2).
class _ChannelList extends StatelessWidget {
  final List<Task> tasks;
  final ChannelSelection selected;
  final bool loading;
  final String? error;
  final ValueChanged<ChannelSelection> onSelect;
  final VoidCallback onRetry;
  final VoidCallback onNewScheduled;
  final VoidCallback onNewDm;
  /// Sprint 49 B7: DM and scheduled_agent channels from the API.
  final List<Map<String, dynamic>> dmChannels;
  final List<Map<String, dynamic>> scheduledChannels;
  /// Sprint 31: when null the list fills its parent (drawer mode);
  /// when set it pins to that width (desktop left rail = 240).
  final double? width;
  const _ChannelList({
    required this.tasks,
    required this.selected,
    required this.loading,
    required this.error,
    required this.onSelect,
    required this.onRetry,
    required this.onNewScheduled,
    required this.onNewDm,
    this.dmChannels = const [],
    this.scheduledChannels = const [],
    this.width = 240,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      color: const Color(0xFF2B2D31),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Text(
                  'My Team',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const Spacer(),
                if (loading)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          ),
          Container(height: 1, color: const Color(0xFF1E1F22)),
          Expanded(child: _scrollableBody(context)),
        ],
      ),
    );
  }

  Widget _scrollableBody(BuildContext context) {
    return ListView(
      children: [
        const SizedBox(height: 8),
        _ChannelTile(
          icon: const Text('✨', style: TextStyle(fontSize: 16)),
          label: 'general',
          selected: selected is GeneralSelected,
          onTap: () => onSelect(const GeneralSelected()),
        ),
        const SizedBox(height: 12),
        _categoryHeader(context, 'TASKS'),
        ..._taskItems(context),
        const SizedBox(height: 12),
        // Sprint 49 B7: Scheduled channels from API + new-scheduled CTA.
        _categoryHeader(context, 'SCHEDULED'),
        ..._directChannelItems(context, scheduledChannels),
        _NewTile(label: '+ New scheduled', onTap: onNewScheduled),
        const SizedBox(height: 12),
        // Sprint 49 B7: DM channels from API + new-DM CTA.
        _categoryHeader(context, 'DIRECT MESSAGES'),
        ..._directChannelItems(context, dmChannels),
        _NewTile(label: '+ New DM', onTap: onNewDm),
        const SizedBox(height: 8),
      ],
    );
  }

  /// Sprint 49 B7: render tiles for DM / scheduled_agent channels.
  /// Shows an orange escalation dot if '_unread_escalation' is set.
  List<Widget> _directChannelItems(
    BuildContext context,
    List<Map<String, dynamic>> channels,
  ) {
    return [
      for (final ch in channels)
        _ChannelTile(
          icon: const Icon(Icons.tag, color: Color(0xFF8E9297), size: 14),
          label: ch['name'] as String? ?? 'channel',
          selected: selected is DirectChannelSelected &&
              (selected as DirectChannelSelected).channelId == ch['id'] as int,
          onTap: () => onSelect(DirectChannelSelected(
            ch['id'] as int,
            ch['name'] as String? ?? 'channel',
          )),
          trailing: (ch['_unread_escalation'] == true)
              ? const Icon(Icons.circle, color: Color(0xFFFF9800), size: 8)
              : null,
        ),
    ];
  }

  Widget _categoryHeader(BuildContext context, String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: const Color(0xFF8E9297),
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
            ),
      ),
    );
  }

  List<Widget> _taskItems(BuildContext context) {
    if (error != null && tasks.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              const Icon(Icons.cloud_off, color: Color(0xFF99AAB5)),
              const SizedBox(height: 8),
              Text(error!, style: const TextStyle(color: Color(0xFF99AAB5), fontSize: 11)),
              const SizedBox(height: 8),
              OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ),
        ),
      ];
    }
    if (tasks.isEmpty) {
      return const [
        Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'No tasks yet.\nType in #general to start one.',
            style: TextStyle(color: Color(0xFF8E9297), fontSize: 12),
          ),
        ),
      ];
    }
    return [
      for (final t in tasks)
        _ChannelTile(
          icon: _statusGlyph(t.status),
          label: t.channelTitle,
          subtitle: '#${t.id.substring(0, 8)} · ${t.status}',
          selected: selected is TaskSelected && (selected as TaskSelected).taskId == t.id,
          onTap: () => onSelect(TaskSelected(t.id)),
        ),
    ];
  }

  Widget _statusGlyph(String status) {
    final (icon, color) = switch (status) {
      'running' => (Icons.play_arrow, Color(0xFF5865F2)),
      'pending' => (Icons.schedule, Color(0xFFFEE75C)),
      'recovering' => (Icons.refresh, Color(0xFFFAA61A)),
      'completed' => (Icons.check_circle, Color(0xFF57F287)),
      'failed' => (Icons.error, Color(0xFFED4245)),
      _ => (Icons.tag, Color(0xFF8E9297)),
    };
    return Icon(icon, color: color, size: 14);
  }
}

/// A tappable "+ New" row shown at the bottom of each category section.
class _NewTile extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _NewTile({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                const SizedBox(
                  width: 20,
                  child: Center(
                    child: Icon(Icons.add, color: Color(0xFF8E9297), size: 14),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: const TextStyle(
                    color: Color(0xFF8E9297),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChannelTile extends StatelessWidget {
  final Widget icon;
  final String label;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;
  /// Sprint 49 B7: optional trailing widget (e.g. escalation indicator dot).
  final Widget? trailing;
  const _ChannelTile({
    required this.icon,
    required this.label,
    this.subtitle,
    required this.selected,
    required this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: selected ? const Color(0xFF404249) : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                SizedBox(width: 20, child: Center(child: icon)),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected ? Colors.white : const Color(0xFFC4C9CE),
                          fontSize: 13,
                          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                        ),
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFF8E9297),
                            fontSize: 10,
                          ),
                        ),
                    ],
                  ),
                ),
                // Sprint 49 B7: escalation dot or other trailing indicator.
                if (trailing != null) ...[
                  const SizedBox(width: 4),
                  trailing!,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Rightmost members panel.
class _MembersPanel extends StatelessWidget {
  final ChannelSelection selected;
  final List<Task> tasks;
  /// Sprint 31: in the modal bottom sheet variant, the inner list
  /// needs to participate in the DraggableScrollableSheet's scroll.
  /// When null (desktop right rail), the panel uses its own scrolling.
  final ScrollController? scrollController;
  const _MembersPanel({
    required this.selected,
    required this.tasks,
    this.scrollController,
  });

  @override
  Widget build(BuildContext context) {
    final isSheet = scrollController != null;
    return Container(
      width: isSheet ? null : 240,
      color: const Color(0xFF2B2D31),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              switch (selected) {
                GeneralSelected() => 'MEMBERS',
                TaskSelected() => 'AGENTS',
                DirectChannelSelected() => 'MEMBERS',
              },
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: const Color(0xFF8E9297),
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                  ),
            ),
          ),
          Expanded(child: _body(context)),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    // Sprint 49 B7: DM / scheduled_agent channels don't have agent rosters.
    if (selected is GeneralSelected || selected is DirectChannelSelected) {
      return ListView(
        controller: scrollController,
        children: const [
          _MemberTile(
            role: tallyMember,
            status: 'online',
            statusColor: Color(0xFF57F287),
          ),
        ],
      );
    }
    final taskId = (selected as TaskSelected).taskId;
    final task = tasks.where((t) => t.id == taskId).cast<Task?>().firstOrNull;
    final agents = _agentListFor(task);
    if (agents.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text(
          'Tally is still picking the team.',
          style: TextStyle(color: Color(0xFF8E9297), fontSize: 12),
        ),
      );
    }
    return ListView.builder(
      controller: scrollController,
      itemCount: agents.length,
      itemBuilder: (context, i) {
        final a = agents[i];
        return _MemberTile(
          role: agentRoleOf(a.roleName),
          status: a.status,
          statusColor: switch (a.status) {
            'working' => const Color(0xFF5865F2),
            'done' => const Color(0xFF57F287),
            'failed' => const Color(0xFFED4245),
            _ => const Color(0xFF8E9297),
          },
          model: a.model,
        );
      },
    );
  }

  /// Derive an "agent in this team" list from the task's team_spec +
  /// the result's per-agent rollup. Sprint 25 builds the list from
  /// `team_spec.agents[]` (the architect's plan); status is overlaid
  /// from `result.agents[i]` when the task has finished a step.
  List<_AgentRow> _agentListFor(Task? task) {
    if (task == null) return const [];
    final spec = task.teamSpec;
    final rollup = task.result?['agents'] as List<dynamic>?;
    final completedRoles = <int, bool>{
      for (final r in rollup ?? const []) (r as Map<String, dynamic>)['agent_idx'] as int: true,
    };
    final modelByIdx = <int, String>{
      for (final r in rollup ?? const [])
        (r as Map<String, dynamic>)['agent_idx'] as int: r['model'] as String? ?? '',
    };

    final planned = (spec?['agents'] as List<dynamic>?) ?? const [];
    if (planned.isNotEmpty) {
      return [
        for (var i = 0; i < planned.length; i++)
          _AgentRow(
            roleName: (planned[i] as Map<String, dynamic>)['role'] as String,
            model: (planned[i] as Map<String, dynamic>)['model'] as String?
                ?? modelByIdx[i] ?? '',
            status: _statusFor(i, task.status, completedRoles, planned.length),
          ),
      ];
    }
    // Fallback: derive from result.agents (terminal tasks without a team_spec).
    return [
      for (final r in rollup ?? const [])
        _AgentRow(
          roleName: (r as Map<String, dynamic>)['role'] as String? ?? '?',
          model: r['model'] as String? ?? '',
          status: (r['result'] as Map<String, dynamic>?)?['success'] == true ? 'done' : 'failed',
        ),
    ];
  }

  String _statusFor(int idx, String taskStatus, Map<int, bool> done, int total) {
    if (done[idx] == true) return 'done';
    if (taskStatus == 'completed') return 'done';
    if (taskStatus == 'failed') return idx == done.length ? 'failed' : 'idle';
    if (taskStatus == 'running' && idx == done.length) return 'working';
    return 'idle';
  }
}

class _AgentRow {
  final String roleName;
  final String model;
  final String status;
  _AgentRow({required this.roleName, required this.model, required this.status});
}

class _MemberTile extends StatelessWidget {
  final AgentRole role;
  final String status;
  final Color statusColor;
  final String? model;
  const _MemberTile({
    required this.role,
    required this.status,
    required this.statusColor,
    this.model,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () {}, // future: @-mention insert
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                Stack(
                  alignment: Alignment.bottomRight,
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: role.tint.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      alignment: Alignment.center,
                      child: Text(role.glyph, style: const TextStyle(fontSize: 16)),
                    ),
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: statusColor,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: const Color(0xFF2B2D31), width: 2),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        role.name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        model?.isNotEmpty == true
                            ? model!.split('/').last
                            : role.tagline,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFF8E9297),
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Sprint 31: drawer variant of the channel list for narrow layouts.
/// Wraps `_ChannelList` with a footer of the server-rail actions
/// (builder + sign-out) so all design-time + admin entry points stay
/// reachable on a phone.
class _NarrowDrawer extends StatelessWidget {
  final List<Task> tasks;
  final ChannelSelection selected;
  final bool loading;
  final String? error;
  final ValueChanged<ChannelSelection> onSelect;
  final VoidCallback onRetry;
  final VoidCallback onOpenBilling;
  final VoidCallback onOpenTemplates;
  final VoidCallback onOpenProjects;
  final VoidCallback onOpenNotifications;
  final VoidCallback onSignOut;
  final VoidCallback onNewScheduled;
  final VoidCallback onNewDm;
  /// Sprint 49 B7: DM and scheduled_agent channels from the API.
  final List<Map<String, dynamic>> dmChannels;
  final List<Map<String, dynamic>> scheduledChannels;
  const _NarrowDrawer({
    required this.tasks,
    required this.selected,
    required this.loading,
    required this.error,
    required this.onSelect,
    required this.onRetry,
    required this.onOpenBilling,
    required this.onOpenTemplates,
    required this.onOpenProjects,
    required this.onOpenNotifications,
    required this.onSignOut,
    required this.onNewScheduled,
    required this.onNewDm,
    this.dmChannels = const [],
    this.scheduledChannels = const [],
  });

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: const Color(0xFF2B2D31),
      child: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: _ChannelList(
                tasks: tasks,
                selected: selected,
                loading: loading,
                error: error,
                onSelect: onSelect,
                onRetry: onRetry,
                onNewScheduled: onNewScheduled,
                onNewDm: onNewDm,
                dmChannels: dmChannels,
                scheduledChannels: scheduledChannels,
                width: null,
              ),
            ),
            Container(height: 1, color: const Color(0xFF1E1F22)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Projects',
                    icon: const Icon(Icons.folder_outlined, size: 18,
                        color: Color(0xFF99AAB5)),
                    onPressed: onOpenProjects,
                  ),
                  IconButton(
                    tooltip: 'Saved templates',
                    icon: const Icon(Icons.bookmark_border, size: 18,
                        color: Color(0xFF99AAB5)),
                    onPressed: onOpenTemplates,
                  ),
                  IconButton(
                    tooltip: 'Billing & usage',
                    icon: const Icon(Icons.credit_card, size: 18,
                        color: Color(0xFF99AAB5)),
                    onPressed: onOpenBilling,
                  ),
                  IconButton(
                    tooltip: 'Notifications',
                    icon: const Icon(Icons.notifications_outlined, size: 18,
                        color: Color(0xFF99AAB5)),
                    onPressed: onOpenNotifications,
                  ),
                  IconButton(
                    tooltip: 'Sign out / reconnect',
                    icon: const Icon(Icons.logout, size: 18,
                        color: Color(0xFF99AAB5)),
                    onPressed: onSignOut,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
