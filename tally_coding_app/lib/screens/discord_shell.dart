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
import 'package:provider/provider.dart';

import '../agent_roles.dart';
import '../api.dart';
import '../services/notifications_ws.dart';
import '../state/workspace_context.dart';
import '../widgets/bottom_sheet/bottom_sheet.dart';
import 'general_channel.dart';
import 'task_channel.dart';
import '../theme/tc_tokens.dart';
import '../widgets/kanban/kanban.dart';
import '../widgets/new_channel_modal.dart';
import '../widgets/sidebar/sidebar.dart';
import 'workspace_settings.dart';

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

class BoardSelected extends ChannelSelection {
  const BoardSelected();
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
  // Sprint 50 B7: custom channels loaded from the API.
  List<Map<String, dynamic>> _customChannels = const [];
  // Sprint 54: tracks which workspace's direct channels we last fetched
  // so didChangeDependencies refetches on workspace switch.  A simple
  // boolean flag would skip refetches after WorkspaceContext updates
  // (user switching workspace) and leave the rail showing the old
  // workspace's channels.  Storing the id and comparing on every
  // didChangeDependencies call is both the initial-load gate (null !=
  // <new id>) and the workspace-switch hook (<old id> != <new id>).
  int? _lastFetchedDirectChannelsWorkspaceId;
  // B3a: most-recent Tally narrator text from the WS stream.
  // Populated in Task 12; null until the first narrator event arrives.
  String? _latestNarratorText;
  // B5: active workspace display name for the SidebarShell WorkspaceRow badge.
  // Loaded asynchronously from /me/workspaces; shows 'workspace' as fallback.
  String _workspaceDisplayName = 'workspace';

  @override
  void initState() {
    super.initState();
    _selected = widget.initialTaskId != null
        ? TaskSelected(widget.initialTaskId!)
        : const BoardSelected();
    _fetch();
    // _fetchDirectChannels intentionally NOT called here — see
    // didChangeDependencies. Reading WorkspaceContext from initState
    // crashes because inherited widgets aren't yet resolved.
    _pollHealth();
    _refresh = Timer.periodic(const Duration(seconds: 4), (_) => _fetch());
    _healthRefresh = Timer.periodic(
      const Duration(seconds: 5),
      (_) {
        if (_poolReady != true) _pollHealth();
      },
    );
    // Sprint 54: subscribe to channel-created WS events so the rail
    // refreshes the moment a new channel is created (by another
    // device, by the API, or by the user's own action processed on
    // a different replica) — without waiting for the 4-s _fetch poll.
    widget.wsClient.onChannelCreated = (_, __) {
      if (mounted) _fetchDirectChannels();
    };
    // B3a Task 12+13: subscribe to new_message events to extract
    // kind='tally_narrator' (narrator bubble) and kind='escalation'
    // (enqueue into BottomSheetController).  Fetches message content
    // via REST — WS frame only carries the ids.
    widget.wsClient.onNewMessage = (channelId, messageId) async {
      try {
        final msgs = await widget.client.getMessages(
          channelId: channelId,
          limit: 1,
          sinceId: messageId - 1,
        );
        if (msgs.isEmpty || !mounted) return;
        final msg = msgs.first;
        final kind = msg['kind'] as String?;
        if (kind == 'tally_narrator') {
          // B3a Task 12: update narrator bubble text.
          final text = msg['text'] as String?;
          if (text != null) setState(() => _latestNarratorText = text);
        } else if (kind == 'escalation') {
          // B3a Task 13: route escalation payload into the controller.
          final payload = msg['payload'] as Map?;
          if (payload != null) {
            final esc = EscalationModel.fromJson({
              ...payload.cast<String, dynamic>(),
              // Prefer channel_id from the WS frame (the channel the
              // message lives in); fall back to payload if present.
              'channel_id': channelId,
            });
            context.read<BottomSheetController>().enqueueEscalation(esc);
          }
        }
      } catch (_) {
        // Non-critical: narrator/escalation stays at last known value.
      }
    };
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Sprint 54: fetch direct channels here (not initState) because
    // WorkspaceContext.of(context) crashes if called before the
    // inherited widget tree is resolved.  Refetch whenever the active
    // workspace_id changes (initial mount when last id is null, or
    // user switching workspaces).  The 4-s _fetch() timer only
    // refreshes tasks, not direct/scheduled/custom channels — so
    // without this hook the rail would stay stale after a workspace
    // switch.
    final ctxId = WorkspaceContext.of(context).activeWorkspaceId;
    if (_lastFetchedDirectChannelsWorkspaceId != ctxId) {
      _lastFetchedDirectChannelsWorkspaceId = ctxId;
      _fetchDirectChannels();
      _loadActiveWorkspaceName(); // B5: refresh workspace name on workspace switch
    }
  }

  @override
  void dispose() {
    _refresh?.cancel();
    _healthRefresh?.cancel();
    // B3a Task 12: clear the WS message callback to avoid callbacks
    // firing after the shell is unmounted.
    widget.wsClient.onNewMessage = null;
    super.dispose();
  }

  Future<void> _fetch() async {
    try {
      final tasks = await widget.client.listTasks(limit: 200);
      if (!mounted) return;
      setState(() {
        _tasks = _sortForChannelList(tasks);
      });
    } catch (_) {
      // Non-critical: keep showing last known task list.
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
  /// Sprint 54+: resolve the workspace to open settings for, then push
  /// WorkspaceSettingsScreen.  Replaces a silent-return-on-missing
  /// handler that left the user tapping the gear icon with no
  /// feedback when their shared_preferences.active_workspace_id
  /// pointed at a workspace they're no longer a member of.
  Future<void> _openSettings() async {
    final wsId = WorkspaceContext.of(context).activeWorkspaceId;
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    final List<Map<String, dynamic>> myWs;
    try {
      myWs = await widget.client.listMyWorkspaces();
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(
          content: Text('Could not load workspaces: $e'),
        ));
      }
      return;
    }
    if (!mounted) return;
    if (myWs.isEmpty) {
      messenger.showSnackBar(const SnackBar(
        content: Text('No workspaces available'),
      ));
      return;
    }
    // Find a match, or fall back to the first available.  Falling
    // back is better UX than silent-failing — the user clearly wants
    // to see settings; show them SOMETHING and surface the mismatch.
    final mine = myWs.firstWhere(
      (w) => w['id'] == wsId,
      orElse: () => myWs.first,
    );
    final mineId = mine['id'] as int;
    if (mineId != wsId) {
      // Update WorkspaceContext so the stale id doesn't keep re-triggering
      // the fallback on every gear tap (PR #8 review feedback #4).
      WorkspaceContext.of(context).onChange(mineId);
    }
    // Push BEFORE the SnackBar so MaterialApp's ScaffoldMessenger paints
    // the SnackBar on the destination screen's Scaffold (where the user
    // is looking) instead of behind the new route (PR #8 review feedback #3).
    nav.push(MaterialPageRoute(
      builder: (_) => WorkspaceSettingsScreen(
        client: widget.client,
        workspaceId: mineId,
        workspaceName: mine['name'] as String? ?? '?',
        callerRole: mine['role'] as String? ?? 'member',
      ),
    ));
    if (mineId != wsId) {
      messenger.showSnackBar(SnackBar(
        content: Text(
          'Active workspace #$wsId not in your list — opening settings '
          'for "${mine['name']}" instead',
        ),
      ));
    }
  }

  Future<void> _fetchDirectChannels() async {
    try {
      final channels = await widget.client.listChannels(
        workspaceId: WorkspaceContext.activeIdOrDefault(context),
      );
      if (!mounted) return;
      final scheduled = channels
          .where((c) => c['kind'] == 'scheduled_agent')
          .toList();
      final custom = channels.where((c) => c['kind'] == 'custom').toList();
      setState(() {
        _customChannels = custom;
      });
      // B3b Task 9: push the full channel list into BottomSheetController so
      // ChannelsSheet has up-to-date data on every workspace load/switch.
      _loadChannelsIntoController(channels);
      await _loadEscalationStatus(scheduled);
    } catch (e) {
      debugPrint('discord_shell: failed to load direct channels: $e');
    }
  }

  /// B3b Task 9: converts the raw API channel maps into [ChannelModel]s and
  /// pushes them into [BottomSheetController].  Called after every
  /// [_fetchDirectChannels] so the channels sheet always reflects the active
  /// workspace.
  void _loadChannelsIntoController(List<Map<String, dynamic>> channels) {
    try {
      final models = channels
          .map((c) => ChannelModel.fromJson(c))
          .toList();
      context.read<BottomSheetController>().setChannels(models);
    } catch (e) {
      debugPrint('discord_shell: _loadChannelsIntoController failed: $e');
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

  /// B5: load the active workspace name for the SidebarShell WorkspaceRow badge.
  /// Called from didChangeDependencies so WorkspaceContext is available.
  /// Silently falls back to 'workspace' on error.
  Future<void> _loadActiveWorkspaceName() async {
    try {
      final wsId = WorkspaceContext.of(context).activeWorkspaceId;
      final list = await widget.client.listMyWorkspaces();
      if (!mounted) return;
      final ws = list.firstWhere(
        (w) => w['id'] == wsId,
        orElse: () => list.isNotEmpty ? list.first : <String, dynamic>{},
      );
      if (ws.isNotEmpty) {
        final name = ws['name'] as String? ?? 'workspace';
        if (_workspaceDisplayName != name) {
          setState(() => _workspaceDisplayName = name);
        }
      }
    } catch (_) {
      // silent: badge shows 'workspace' as fallback
    }
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
    // B5: derive sidebar channel list from custom channels only (long-term channels).
    final sidebarChannels = _customChannels.map((ch) => SidebarChannelEntry(
      name: ch['name'] as String? ?? 'channel',
      needsAttention: ch['_unread_escalation'] == true,
      escalationCount: ch['_unread_escalation'] == true ? 1 : 0,
    )).toList();

    // B5: stub ambient data from current task list.
    final runningTasks = _tasks.where((t) => t.status == 'running').toList();
    final doneTodayCount = _tasks.where((t) => t.status == 'completed').length;

    // F1-Fix4: bridge BottomSheetController.queue → SidebarShell.escalations
    // so the desktop sidebar mini-dash reflects real escalations from WS events.
    // EscalationModel → SidebarEscalationData: map channelId to a channel name
    // from the loaded channels list; fall back to '#<id>' when not found.
    final bsController = context.watch<BottomSheetController>();
    final sidebarEscalations = bsController.queue.map((esc) {
      // Resolve channel name from the channels the controller knows about.
      final ch = bsController.channels
          .cast<ChannelModel?>()
          .firstWhere((c) => c?.id == esc.channelId, orElse: () => null);
      final channelName = ch?.name ?? '${esc.channelId}';
      // Resolve task name from local task list.
      final task = _tasks.cast<Task?>().firstWhere(
        (t) => t?.id == esc.taskId,
        orElse: () => null,
      );
      final taskName = task?.channelTitle ?? esc.taskId;
      return SidebarEscalationData(
        channelName: channelName,
        taskName: taskName,
        question: esc.question,
        quickReplies: esc.options,
        emphasizedTerms: const [],
      );
    }).toList();

    // F1-Fix5: whether a right pane should be shown alongside the kanban.
    final hasRightPane = _selected is TaskSelected ||
        _selected is DirectChannelSelected ||
        _selected is GeneralSelected;

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
                  // B5: SidebarShell replaces ServerRail + _ChannelList + _MembersPanel.
                  SidebarShell(
                    workspaceName: _workspaceDisplayName,
                    onWorkspaceSwitcherTap: () => _openSettings(),
                    onSearchTap: () {}, // search deferred
                    channels: sidebarChannels,
                    activeChannelName: _activeLongTermChannelName(),
                    // F1-Fix3: Board entry — highlight when board is selected,
                    // tap → return to board view from any channel/task.
                    isBoardSelected: _selected is BoardSelected,
                    onBoardTap: () => setState(() => _selected = const BoardSelected()),
                    onChannelTap: (name) {
                      final ch = _customChannels.firstWhere(
                        (c) => c['name'] == name,
                        orElse: () => <String, dynamic>{},
                      );
                      if (ch.isNotEmpty) {
                        setState(() => _selected = DirectChannelSelected(
                          ch['id'] as int,
                          name,
                        ));
                      }
                    },
                    onAddChannel: () async {
                      final newCh = await showDialog<Map<String, dynamic>>(
                        context: context,
                        builder: (_) => NewChannelModal(
                          client: widget.client,
                          workspaceId: WorkspaceContext.of(context).activeWorkspaceId,
                        ),
                      );
                      if (newCh != null && mounted) await _fetchDirectChannels();
                    },
                    // Ambient mini-dash data
                    openCount: runningTasks.length,
                    doneToday: doneTodayCount,
                    tasks: runningTasks.take(3).map((t) => SidebarMiniTaskData(
                      title: t.channelTitle,
                      agentRoles: _agentRolesFor(t),
                      progressPct: _progressFor(t),
                    )).toList(),
                    // F1-Fix2: pass null directly; SidebarMiniDash hides the
                    // narrator bubble until a real WS narrator event arrives.
                    narratorText: _latestNarratorText,
                    narratorEmphasis: const [],
                    // F1-Fix4: live escalations from BottomSheetController queue.
                    escalations: sidebarEscalations,
                    // F1-Fix4: quick-reply posts message + resolves escalation
                    // (mirrors the onReply logic in _BoardBottomSheet).
                    onQuickReply: (option) async {
                      final esc = bsController.activeEscalation;
                      if (esc == null) return;
                      try {
                        await widget.client.postMessage(
                          channelId: esc.channelId,
                          text: option,
                          kind: 'message',
                          payload: {'in_response_to_escalation': esc.id},
                        );
                      } catch (_) {
                        // POST failed — keep escalation active for retry.
                        return;
                      }
                      if (context.mounted) {
                        context.read<BottomSheetController>().resolveActive();
                      }
                    },
                    // F1-Fix4: skip cycles the head escalation to the tail.
                    onSkipEscalation: bsController.skip,
                    // F1-Fix4: open escalation channel in the right pane.
                    onOpenChannel: () {
                      final esc = bsController.activeEscalation;
                      if (esc == null) return;
                      final ch = bsController.channels
                          .cast<ChannelModel?>()
                          .firstWhere(
                            (c) => c?.id == esc.channelId,
                            orElse: () => null,
                          );
                      final name = ch?.name ?? 'general';
                      setState(() => _selected = DirectChannelSelected(esc.channelId, name));
                    },
                  ),
                  // F1-Fix5: Desktop split-pane — kanban always visible on desktop.
                  // When hasRightPane, kanban occupies flex:1 and the right pane
                  // takes an additional flex:1 (50/50 split).
                  // When board-only, kanban expands to fill all remaining space.
                  Expanded(
                    child: hasRightPane
                        ? Row(
                            children: [
                              // Left half: kanban (always visible on desktop).
                              Expanded(
                                child: KanbanView(
                                  tasks: _filteredTasksForKanban(),
                                  onTaskTap: (task) => setState(
                                    () => _selected = TaskSelected(task.id),
                                  ),
                                  onNewTask: () => setState(
                                    () => _selected = const GeneralSelected(),
                                  ),
                                ),
                              ),
                              // Right half: chat pane with a close affordance.
                              Expanded(
                                child: Column(
                                  children: [
                                    // Close button strip at top of right pane.
                                    _RightPaneCloseBar(
                                      onClose: () => setState(
                                        () => _selected = const BoardSelected(),
                                      ),
                                    ),
                                    Expanded(child: _mainPane(isNarrow: false)),
                                  ],
                                ),
                              ),
                            ],
                          )
                        : _mainPane(isNarrow: false),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// B5: returns the channel name for the currently selected long-term channel,
  /// or null if a task channel / general / board is selected.
  String? _activeLongTermChannelName() {
    if (_selected case DirectChannelSelected(channelName: final name)) {
      return name;
    }
    return null;
  }

  /// B5: extract agent role strings from a task's team_spec.
  List<String> _agentRolesFor(Task t) {
    final agents = (t.teamSpec?['agents'] as List<dynamic>?) ?? const [];
    return agents
        .map((a) => (a as Map<String, dynamic>)['role'] as String? ?? 'coder')
        .toList();
  }

  /// B5: estimate task progress — 50% for running, 100% for completed.
  int _progressFor(Task t) =>
      t.status == 'completed' ? 100 : (t.status == 'running' ? 50 : 0);

  Widget _buildNarrow(BuildContext context) {
    final channelTitle = switch (_selected) {
      GeneralSelected() => '#general',
      TaskSelected(taskId: final id) => '#${id.substring(0, 8)}',
      DirectChannelSelected(channelName: final name) => '#$name',
      BoardSelected() => 'Board',
    };
    final tc = context.tc;
    return Scaffold(
      backgroundColor: tc.bg,
      appBar: AppBar(
        backgroundColor: tc.elev,
        foregroundColor: Colors.white,
        title: Text(channelTitle,
            style: const TextStyle(
              fontFamily: 'JetBrainsMono',
              fontWeight: FontWeight.w600,
              fontSize: 16,
            )),
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings),
            onPressed: () => _openSettings(),
          ),
          IconButton(
            tooltip: 'Members / agents',
            icon: const Icon(Icons.people),
            onPressed: () => _showMembersSheet(context),
          ),
        ],
      ),
      // No drawer: all channels live in the bottom sheet's expanded state.
      // The hamburger drawer has been removed per F4 (Claude Design mockups
      // Screens 1 + 3 show no hamburger on mobile).
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
            Expanded(child: _mainPane(isNarrow: true)),
          ],
        ),
      ),
    );
  }

  void _showMembersSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.tc.sheet,
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
                  color: context.tc.fgDimmer,
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

  /// Returns the main pane widget for the current [_selected] state.
  ///
  /// [isNarrow] controls whether the mobile bottom sheet overlay is mounted.
  /// On desktop (isNarrow == false) the BoardSelected arm returns only
  /// [KanbanView]; the [SidebarMiniDash] docked in [SidebarShell] serves as
  /// the ambient/escalation surface instead.
  Widget _mainPane({bool isNarrow = true}) {
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
      // B3a Task 11 / F4: wrap kanban in a Stack so the bottom sheet can
      // overlay at the bottom without pushing kanban content up.
      // F1-Fix1: only mount _BoardBottomSheet on narrow (mobile) layout;
      // desktop uses SidebarMiniDash in SidebarShell instead.
      // F4: the kanban layer is wrapped in a Consumer so a tap on the kanban
      // area (when the sheet is expanded) collapses the sheet back to ambient.
      BoardSelected() => isNarrow
          ? Stack(
              children: [
                Positioned.fill(
                  child: Consumer<BottomSheetController>(
                    builder: (context, bsc, child) => GestureDetector(
                      // Tap on kanban behind when sheet is expanded → collapse.
                      onTap: bsc.state == SheetState.channelsExpanded
                          ? bsc.collapseToAmbient
                          : null,
                      behavior: HitTestBehavior.translucent,
                      child: child,
                    ),
                    child: KanbanView(
                      tasks: _filteredTasksForKanban(),
                      onTaskTap: (task) =>
                          setState(() => _selected = TaskSelected(task.id)),
                      onNewTask: () =>
                          setState(() => _selected = const GeneralSelected()),
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _BoardBottomSheet(
                    tasks: _filteredTasksForKanban(),
                    latestNarratorText: _latestNarratorText,
                    client: widget.client,
                    onOpenChannel: (channelId, name) => setState(() {
                      _selected = DirectChannelSelected(channelId, name);
                    }),
                  ),
                ),
              ],
            )
          : KanbanView(
              tasks: _filteredTasksForKanban(),
              onTaskTap: (task) =>
                  setState(() => _selected = TaskSelected(task.id)),
              onNewTask: () =>
                  setState(() => _selected = const GeneralSelected()),
            ),
    };
  }

  /// Returns tasks filtered to the active project, or all tasks if none selected.
  List<Task> _filteredTasksForKanban() {
    if (_activeProjectId == null) return _tasks;
    return _tasks.where((t) => t.projectId == _activeProjectId).toList();
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
    final tc = context.tc;
    final hasError = lastError != null;
    final color = hasError ? tc.red : tc.yellow;
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
                    style: TextStyle(color: tc.fgXdim, fontSize: 11),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ] else ...[
                  const SizedBox(height: 2),
                  Text(
                    "Task submission will fail until at least one worker joins. Reads + billing keep working.",
                    style: TextStyle(color: tc.fgXdim, fontSize: 11),
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
    final tc = context.tc;
    final isSheet = scrollController != null;
    return Container(
      width: isSheet ? null : 240,
      color: tc.sheet,
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
                BoardSelected() => 'MEMBERS',
              },
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: tc.fgDim,
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
    final tc = context.tc;
    // Sprint 49 B7: DM / scheduled_agent channels don't have agent rosters.
    // BoardSelected also has no task-specific roster.
    if (selected is GeneralSelected ||
        selected is DirectChannelSelected ||
        selected is BoardSelected) {
      return ListView(
        controller: scrollController,
        children: [
          _MemberTile(
            role: tallyMember,
            status: 'online',
            statusColor: tc.green,
          ),
        ],
      );
    }
    final taskId = (selected as TaskSelected).taskId;
    final task = tasks.where((t) => t.id == taskId).cast<Task?>().firstOrNull;
    final agents = _agentListFor(task);
    if (agents.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          'Tally is still picking the team.',
          style: TextStyle(color: tc.fgDim, fontSize: 12),
        ),
      );
    }
    return ListView.builder(
      controller: scrollController,
      itemCount: agents.length,
      itemBuilder: (context, i) {
        final a = agents[i];
        final tc = context.tc;
        return _MemberTile(
          role: agentRoleOf(a.roleName),
          status: a.status,
          statusColor: switch (a.status) {
            'working' => tc.cyan,
            'done' => tc.green,
            'failed' => tc.red,
            _ => tc.fgDimmer,
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
    final tc = context.tc;
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
                        // ring color matches the panel surface so the dot
                        // appears to float above the avatar bg.
                        border: Border.all(color: tc.sheet, width: 2),
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
                        style: TextStyle(
                          color: tc.fg,
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
                        style: TextStyle(
                          color: tc.fgDim,
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

// ─────────────────────────────────────────────────────────────
// F1-Fix5: close bar for the desktop right pane.
// ─────────────────────────────────────────────────────────────

/// A slim 36 px bar at the top of the desktop right pane that shows the
/// current channel/task name and a close button (✕) that collapses the
/// pane back to board-only view.
///
/// Uses TCTokens so it follows the active theme.
class _RightPaneCloseBar extends StatelessWidget {
  final VoidCallback onClose;
  const _RightPaneCloseBar({required this.onClose});

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: tc.elev,
        border: Border(bottom: BorderSide(color: tc.border, width: 1)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Expanded(child: const SizedBox.shrink()),
          GestureDetector(
            onTap: onClose,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Tooltip(
                message: 'Close panel',
                child: Icon(
                  Icons.close,
                  size: 16,
                  color: tc.fgXdim,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// F4: draggable bottom-sheet overlay for the Board view.
// ─────────────────────────────────────────────────────────────

/// Collapsed height — just the ambient mini-dash content.
const double _sheetCollapsedHeight = 152.0;

/// Expanded height as a fraction of the viewport (matches mockup Screen 3).
const double _sheetExpandedFraction = 0.76;

/// Draggable bottom sheet overlay for the Board view (mobile narrow layout).
///
/// Snaps between two heights:
///   - collapsed: [_sheetCollapsedHeight] px — shows [AmbientMiniDash]
///   - expanded:  [_sheetExpandedFraction] × viewport — shows [ChannelsSheet]
///
/// During takeover (escalation) the sheet is locked-height — user must resolve
/// or skip the escalation before dragging is re-enabled.
///
/// Gesture rules:
///   - While dragging: sheet follows finger 1:1 within [collapsed, expanded].
///   - On release: velocity < −200 → snap to expanded; > 200 → snap to
///     collapsed; otherwise snap to nearest.
///   - Tap on drag handle in collapsed state → expand; in expanded → collapse.
///   - Tap on kanban behind (when expanded) → collapse.
///
/// Example:
/// ```dart
/// _BoardBottomSheet(
///   tasks: kanbanTasks,
///   latestNarratorText: narrator,
///   client: orchClient,
///   onOpenChannel: (id, name) => setState(() => _selected = DirectChannelSelected(id, name)),
/// )
/// ```
class _BoardBottomSheet extends StatefulWidget {
  final List<Task> tasks;
  final String? latestNarratorText;
  final TallyOrchClient client;
  final void Function(int channelId, String name) onOpenChannel;

  const _BoardBottomSheet({
    required this.tasks,
    required this.latestNarratorText,
    required this.client,
    required this.onOpenChannel,
  });

  @override
  State<_BoardBottomSheet> createState() => _BoardBottomSheetState();
}

class _BoardBottomSheetState extends State<_BoardBottomSheet> {
  /// Non-null while the user is actively dragging.
  /// null = controller drives height via AnimatedContainer.
  double? _dragHeight;

  double _expandedHeight(BuildContext context) =>
      MediaQuery.of(context).size.height * _sheetExpandedFraction;

  /// Picks the nearest snap point given current height and velocity.
  double _snapTarget(double currentHeight, double velocity, BuildContext context) {
    final expanded = _expandedHeight(context);
    if (velocity < -200) return expanded;       // fast upward → expand
    if (velocity > 200) return _sheetCollapsedHeight;  // fast downward → collapse
    // No strong velocity — snap to nearest.
    final midpoint = (_sheetCollapsedHeight + expanded) / 2;
    return currentHeight >= midpoint ? expanded : _sheetCollapsedHeight;
  }

  void _snapAndUpdateController(double target, BuildContext context) {
    final controller = context.read<BottomSheetController>();
    setState(() => _dragHeight = null);
    if (target >= _expandedHeight(context) * 0.9) {
      controller.expandChannels();
    } else {
      controller.collapseToAmbient();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<BottomSheetController>();

    if (controller.state == SheetState.hidden) return const SizedBox.shrink();

    final expanded = _expandedHeight(context);

    // Takeover state — locked height, no drag allowed.
    if (controller.state == SheetState.takeover &&
        controller.activeEscalation != null) {
      final esc = controller.activeEscalation!;
      final task = widget.tasks.firstWhere(
        (t) => t.id == esc.taskId,
        orElse: () => Task.fromJson({
          'id': esc.taskId,
          'description': '(task)',
          'status': 'recovering',
          'created_at': 0.0,
          'updated_at': 0.0,
        }),
      );
      return EscalationSheet(
        escalation: esc,
        queueIndex: 0,
        queueSize: controller.queueSize,
        taskTitle: task.channelTitle,
        channelName: 'general',
        onReply: (option) async {
          try {
            await widget.client.postMessage(
              channelId: esc.channelId,
              text: option,
              kind: 'message',
              payload: {'in_response_to_escalation': esc.id},
            );
          } catch (_) {
            return;
          }
          if (context.mounted) {
            context.read<BottomSheetController>().resolveActive();
          }
        },
        onSkip: controller.skip,
        onOpen: () => widget.onOpenChannel(esc.channelId, 'general'),
      );
    }

    // Determine target height driven by the controller when not dragging.
    final controllerHeight = controller.state == SheetState.channelsExpanded
        ? expanded
        : _sheetCollapsedHeight;

    // Current display height: drag-driven when the user is holding the finger,
    // controller-driven otherwise.
    final displayHeight = _dragHeight ?? controllerHeight;

    // Build sheet content.  At intermediate drag positions show both ambient
    // content (mini-dash) regardless of state so the drag handle is always
    // visible.  The channels list fades in as the sheet rises.
    final done = widget.tasks
        .where((t) => t.status == 'completed' || t.status == 'failed')
        .length;
    final open = widget.tasks.length - done;
    final running = widget.tasks.where((t) => t.status == 'running').toList();

    // Fraction from collapsed to expanded — used to decide which content to show.
    final fraction = ((displayHeight - _sheetCollapsedHeight) /
            (expanded - _sheetCollapsedHeight))
        .clamp(0.0, 1.0);
    // Show channels list when the sheet is more than halfway up.
    final showChannels = fraction > 0.5;

    return GestureDetector(
      // Drag start: capture current height so we can delta from it.
      onVerticalDragUpdate: (details) {
        final current = _dragHeight ?? controllerHeight;
        setState(() {
          _dragHeight = (current - details.delta.dy)
              .clamp(_sheetCollapsedHeight, expanded);
        });
      },
      onVerticalDragEnd: (details) {
        final current = _dragHeight ?? controllerHeight;
        final velocity = details.primaryVelocity ?? 0;
        final target = _snapTarget(current, velocity, context);
        _snapAndUpdateController(target, context);
      },
      // Tap on the handle band — toggle between expanded / collapsed.
      onTap: () {
        if (controller.state == SheetState.channelsExpanded) {
          _snapAndUpdateController(_sheetCollapsedHeight, context);
        } else {
          _snapAndUpdateController(expanded, context);
        }
      },
      // Tap outside is handled by the parent Stack — see [_mainPane].
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        height: displayHeight,
        child: showChannels
            ? ChannelsSheet(
                channels: controller.channels,
                needsAttention: {
                  for (final e in controller.queue) e.channelId,
                },
                escalationCountByChannel: {
                  for (final e in controller.queue)
                    e.channelId: (controller.queue
                            .where((q) => q.channelId == e.channelId)
                            .length),
                },
                onChannelTap: (ch) => widget.onOpenChannel(ch.id, ch.name),
                onCollapse: () =>
                    _snapAndUpdateController(_sheetCollapsedHeight, context),
              )
            : AmbientMiniDash(
                openCount: open,
                doneCount: done,
                taskRows: [
                  for (final t in running.take(2))
                    MiniTaskRow(title: t.channelTitle, progress: 0.5),
                ],
                narratorText: widget.latestNarratorText,
              ),
      ),
    );
  }
}

