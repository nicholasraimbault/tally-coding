/// Sprint 25: task channel — the main-pane view when a task is selected.
///
/// Same SSE stream + agent timeline + workspace tree as the old
/// TaskDetailScreen, but embedded as a panel (no AppBar) and themed for
/// the Discord shell. Each agent's events get a colored band so the
/// Planner → Coder → Reviewer flow is readable as a chat.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../api.dart';
import '../services/notifications_ws.dart';
import '../widgets/cap_abort_dialog.dart';
import '../widgets/channel_header.dart';
import '../widgets/message_composer.dart';
import '../widgets/message_feed.dart';
import '../widgets/task_cost_ticker.dart';
import 'billing_screen.dart';
import 'file_tree.dart';
import 'workflow_editor.dart';

class TaskChannelScreen extends StatefulWidget {
  final TallyOrchClient client;
  final NotificationsWsClient wsClient;
  /// Sprint 47: task-context path — resolves channel via listChannels(task_id).
  final String? taskId;
  /// Sprint 49 B7: direct channel path — bypasses task resolution.
  /// Used for kind='dm' and kind='scheduled_agent' channels.
  final int? directChannelId;
  /// Sprint 49 B7: display title for non-task channels (DMs, scheduled agents).
  final String? channelTitle;
  const TaskChannelScreen({
    super.key,
    required this.client,
    required this.wsClient,
    this.taskId,
    this.directChannelId,
    this.channelTitle,
  }) : assert(taskId != null || directChannelId != null,
            'Either taskId or directChannelId must be provided');

  @override
  State<TaskChannelScreen> createState() => _TaskChannelScreenState();
}

class _TaskChannelScreenState extends State<TaskChannelScreen> {
  Task? _task;
  // SSE-based event state: kept only to drive the cost ticker + cap-abort
  // dialog via status_change frames. The event list rendering is gone.
  StreamSubscription? _framesSub;
  String? _error;
  List<Map<String, dynamic>>? _files;
  String? _filesError;
  bool _filesLoading = false;
  int _perTaskCap = 100; // default until getCaps() resolves

  // Sprint 47 B7: chat message state (REST + WS)
  List<Map<String, dynamic>> _messages = [];
  int _lastMessageId = 0;
  int? _channelId;

  @override
  void initState() {
    super.initState();
    // Sprint 49 B7: for direct-channel mode (DM / scheduled_agent) skip the
    // task-fetch, SSE stream, and cap lookup — none make sense without a taskId.
    if (widget.taskId != null) {
      _fetchInitial();
      _connectStream();
      _fetchCaps();
    }
    _resolveChannelAndLoad();
  }

  Future<void> _fetchCaps() async {
    try {
      final caps = await widget.client.getCaps();
      if (!mounted) return;
      setState(() {
        _perTaskCap = (caps['per_task_cap_credits'] as num?)?.toInt() ?? 100;
      });
    } catch (_) {/* non-critical — keep default */}
  }

  @override
  void dispose() {
    _framesSub?.cancel();
    // Clear the WS callback so the channel doesn't leak across route transitions.
    widget.wsClient.onNewMessage = null;
    super.dispose();
  }

  Future<void> _fetchInitial() async {
    final tid = widget.taskId;
    if (tid == null) return;
    try {
      final t = await widget.client.getTask(tid);
      if (!mounted) return;
      setState(() => _task = t);
      if (t.isTerminal && _files == null && !_filesLoading) _fetchFiles();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  Future<void> _fetchFiles() async {
    final tid = widget.taskId;
    if (tid == null || _filesLoading) return;
    setState(() => _filesLoading = true);
    try {
      final entries = await widget.client.listFiles(tid);
      if (!mounted) return;
      setState(() {
        _files = entries;
        _filesError = null;
        _filesLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _filesError = e.toString();
        _filesLoading = false;
      });
    }
  }

  // Sprint 47 B7: The SSE stream is kept ONLY to drive status_change events
  // (cost ticker chip, cap-abort dialog, task status header). The per-event
  // agent-timeline rendering has been replaced by MessageFeed + WS.
  // Sprint 49 B7: only called when widget.taskId is set.
  void _connectStream() {
    final tid = widget.taskId;
    if (tid == null) return;
    _framesSub?.cancel();
    _framesSub = widget.client.streamFrames(tid, sinceSeq: -1).listen(
      (frame) {
        if (!mounted) return;
        setState(() {
          if (frame.name == 'status_change') {
            final t = _task;
            final newStatus = frame.data['status'] as String;
            final ts = (frame.data['ts'] as num?)?.toDouble() ??
                DateTime.now().millisecondsSinceEpoch / 1000.0;
            if (t != null) {
              _task = Task(
                id: t.id,
                description: t.description,
                status: newStatus,
                result: t.result,
                error: t.error,
                createdAt: t.createdAt,
                updatedAt: ts,
                teamSpec: t.teamSpec,
              );
            }
            if (newStatus == 'completed' || newStatus == 'failed') {
              _fetchInitial();
            }
            if (newStatus == 'aborted_cost_cap') {
              final detail = frame.data['extra'] as Map<String, dynamic>? ?? {};
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                showDialog(
                  context: context,
                  builder: (_) => CapAbortDialog(
                    reason: detail['reason'] as String? ?? 'per_task_cap',
                    costCredits: (detail['cost_credits'] as num?)?.toInt() ?? 0,
                    capCredits: (detail['cap_credits'] as num?)?.toInt() ?? 0,
                    onViewPartial: () {
                      Navigator.pop(context);
                      // artifacts are already visible in the channel body
                    },
                    onRaiseCapAndRetry: () {
                      Navigator.pop(context);
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => BillingScreen(client: widget.client),
                        ),
                      );
                    },
                  ),
                );
              });
            }
          }
          _error = null;
        });
      },
      onError: (e) {
        if (!mounted) return;
        setState(() => _error = 'stream: $e');
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) _connectStream();
        });
      },
      cancelOnError: true,
    );
  }

  // ─── Sprint 47 B7: channel resolution + message loading + WS subscription ───

  Future<void> _resolveChannelAndLoad() async {
    try {
      // Sprint 49 B7: direct-channel path — no task lookup needed.
      if (widget.directChannelId != null) {
        _channelId = widget.directChannelId;
        await _loadMessages();
        _subscribeToWs();
        return;
      }
      // Sprint 47: task-channel path — resolve channel from task_id.
      final channels = await widget.client.listChannels(workspaceId: 1);
      final mine = channels.firstWhere(
        (c) => c['task_id'] == widget.taskId,
        orElse: () => const {},
      );
      if (mine.isNotEmpty) {
        _channelId = mine['id'] as int;
        await _loadMessages();
        _subscribeToWs();
      }
    } catch (e) {
      debugPrint('task_channel: failed to resolve channel: $e');
    }
  }

  Future<void> _loadMessages() async {
    if (_channelId == null) return;
    final msgs = await widget.client.getMessages(channelId: _channelId!);
    if (!mounted) return;
    setState(() {
      _messages = msgs;
      _lastMessageId = msgs.isNotEmpty ? (msgs.first['id'] as int) : 0;
    });
  }

  void _subscribeToWs() {
    widget.wsClient.onNewMessage = (channelId, messageId) async {
      if (channelId != _channelId) return;
      try {
        final newMsgs = await widget.client.getMessages(
          channelId: _channelId!,
          sinceId: _lastMessageId,
        );
        if (!mounted) return;
        setState(() {
          _messages = [...newMsgs, ..._messages];
          if (newMsgs.isNotEmpty) _lastMessageId = newMsgs.first['id'] as int;
        });
      } catch (e) {
        debugPrint('task_channel: ws refresh failed: $e');
      }
    };
  }

  Future<void> _send(String text) async {
    if (_channelId == null) return;
    await widget.client.postMessage(channelId: _channelId!, text: text);
    // Optimistic refresh — WS will deliver but eagerly refresh in case WS is slow.
    await _loadMessages();
  }

  Future<void> _openFileViewer(String path) async {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: const Color(0xFF313338),
        insetPadding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800, maxHeight: 600),
          child: _FileViewerDialog(
            client: widget.client,
            // _openFileViewer is only reachable in task-context mode,
            // so widget.taskId is guaranteed non-null here.
            taskId: widget.taskId!,
            path: path,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = _task;
    // Sprint 49 B7: direct-channel mode (DM / scheduled_agent) — no task
    // context, so skip the task header widgets and go straight to the feed.
    if (widget.directChannelId != null) {
      return Container(
        color: const Color(0xFF313338),
        child: Column(
          children: [
            ChannelHeader(
              glyph: '#',
              name: widget.channelTitle ?? 'channel',
              description: '',
            ),
            Expanded(child: _directBody()),
          ],
        ),
      );
    }
    final tid = widget.taskId!;
    return Container(
      color: const Color(0xFF313338),
      child: Column(
        children: [
          ChannelHeader(
            glyph: '#',
            name: t?.id.substring(0, 8) ?? tid.substring(0, 8),
            description: t?.description ?? 'Loading…',
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TaskCostTicker(
                  client: widget.client,
                  taskId: tid,
                  perTaskCapCredits: _perTaskCap,
                  taskStatus: t?.status ?? 'pending',
                ),
                const SizedBox(width: 8),
                if (t != null)
                  _HeaderTrailing(
                    task: t,
                    onSaveTemplate: () => _promptSaveTemplate(t),
                    onBranch: () => _promptBranch(t),
                  ),
              ],
            ),
          ),
          Expanded(child: _body(t)),
        ],
      ),
    );
  }

  /// Sprint 49 B7: body for direct-channel mode — MessageFeed + Composer,
  /// no task status, result card, workspace, or error container.
  Widget _directBody() {
    return Column(
      children: [
        Expanded(
          child: MessageFeed(
            messages: _messages,
            onAnswerPrompt: (messageId, value) async {
              if (_channelId == null) return;
              try {
                await widget.client.postMessage(
                  channelId: _channelId!,
                  kind: 'interactive_prompt_response',
                  payload: {'value': value},
                  replyToId: messageId,
                );
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Answer failed: $e')),
                  );
                }
              }
            },
            onTeamProposalAction: (taskId, action) async {
              // Team proposals are unlikely in DM/scheduled channels,
              // but wire up a no-op so MessageFeed compiles cleanly.
            },
          ),
        ),
        MessageComposer(
          onSend: _send,
          placeholder: 'Message…',
        ),
      ],
    );
  }

  /// Sprint 41: branch off a completed task — submit a new task whose
  /// first agent inherits the parent's artifacts as seed_files.
  /// Only called when widget.taskId is non-null (task-context mode).
  Future<void> _promptBranch(Task parent) async {
    final desc = await showDialog<String>(
      context: context,
      builder: (ctx) => _BranchTaskDialog(parent: parent),
    );
    if (desc == null || desc.trim().isEmpty || !mounted) return;
    try {
      final child = await widget.client.submitTask(
        desc.trim(),
        parentTaskId: parent.id,
        projectId: parent.projectId,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Branched: new task #${child.id.substring(0, 8)} inherits '
            '${parent.id.substring(0, 8)}\'s workspace.',
          ),
          backgroundColor: const Color(0xFF57F287),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e')),
      );
    }
  }

  Future<void> _promptSaveTemplate(Task t) async {
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => const _SaveTemplateDialog(),
    );
    if (result == null || !mounted) return;
    final parts = result.split('\n');
    final name = parts.first.trim();
    final note = parts.length > 1 ? parts.sublist(1).join('\n').trim() : null;
    try {
      await widget.client.saveTemplate(
        name: name,
        sourceTaskId: t.id,
        note: note?.isEmpty == true ? null : note,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Saved team as `$name`'),
          backgroundColor: const Color(0xFF57F287),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Save failed: $e'),
          backgroundColor: const Color(0xFFED4245),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  // Sprint 48 B7: look up the team_proposal payload for a given taskId so the
  // editor can be pre-populated with the current team_spec from the message.
  Map<String, dynamic>? _findTeamProposalPayload(String taskId) {
    for (final m in _messages) {
      if (m['kind'] != 'team_proposal') continue;
      try {
        final p = jsonDecode(m['payload_json'] as String) as Map<String, dynamic>;
        if (p['task_id'] == taskId) return p;
      } catch (_) {}
    }
    return null;
  }

  // Sprint 47 B7: body is now MessageFeed (REST + WS messages) + MessageComposer.
  // The old SSE agent-timeline (_events, _renderTimeline) is fully replaced.
  // Result card, workspace card, and error container still render below the
  // feed so completed/failed task artifacts remain accessible.
  Widget _body(Task? t) {
    if (t == null) {
      return Center(
        child: _error != null
            ? Text('Error: $_error', style: const TextStyle(color: Color(0xFF99AAB5)))
            : const CircularProgressIndicator(),
      );
    }
    return Column(
      children: [
        Expanded(
          child: MessageFeed(
            messages: _messages,
            onAnswerPrompt: (messageId, value) async {
              if (_channelId == null) return;
              try {
                await widget.client.postMessage(
                  channelId: _channelId!,
                  kind: 'interactive_prompt_response',
                  payload: {'value': value},
                  replyToId: messageId,
                );
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Answer failed: $e')),
                  );
                }
              }
            },
            // Sprint 48 B7: wire team_proposal card actions to API + editor.
            onTeamProposalAction: (taskId, action) async {
              switch (action) {
                case 'approve':
                  try {
                    await widget.client.approveTask(taskId: taskId);
                    if (mounted) await _loadMessages();
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Approve failed: $e')),
                      );
                    }
                  }
                case 'edit':
                  final payload = _findTeamProposalPayload(taskId);
                  if (payload == null) return;
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => WorkflowEditorScreen(
                        client: widget.client,
                        taskId: taskId,
                        initialTeamSpec:
                            Map<String, dynamic>.from(payload['team_spec'] as Map),
                      ),
                    ),
                  );
                  if (mounted) await _loadMessages();
                case 'cancel':
                  try {
                    await widget.client.cancelTask(taskId: taskId);
                    if (mounted) await _loadMessages();
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Cancel failed: $e')),
                      );
                    }
                  }
              }
            },
          ),
        ),
        // Result card + workspace card below the feed for terminal tasks.
        if (t.isTerminal && t.result != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: _ResultCard(result: t.result!),
          ),
        if (t.isTerminal)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: _WorkspaceCard(
              files: _files,
              filesError: _filesError,
              loading: _filesLoading,
              onRefresh: _fetchFiles,
              onFileTap: _openFileViewer,
            ),
          ),
        if (t.status == 'failed' && t.error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFED4245).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFFED4245).withValues(alpha: 0.4)),
              ),
              child: SelectableText(
                t.error!,
                style: const TextStyle(
                  color: Color(0xFFFFAAAA),
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
              ),
            ),
          ),
        MessageComposer(
          onSend: _send,
          placeholder: 'Message…',
        ),
      ],
    );
  }
}

/// Sprint 29/41: header trailing controls — branch-this-task button
/// (S41) + "save this team" bookmark (S29) + status badge.  Both
/// action buttons are visible only on completed tasks.
class _HeaderTrailing extends StatelessWidget {
  final Task task;
  final VoidCallback onSaveTemplate;
  final VoidCallback onBranch;
  const _HeaderTrailing({
    required this.task,
    required this.onSaveTemplate,
    required this.onBranch,
  });

  @override
  Widget build(BuildContext context) {
    final canSave = task.isTerminal && task.teamSpec != null;
    final canBranch = task.status == 'completed';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (canBranch)
          IconButton(
            tooltip: 'Branch a new task from this one (inherits the workspace)',
            icon: const Icon(Icons.fork_right, size: 18, color: Color(0xFF8E9297)),
            onPressed: onBranch,
          ),
        if (canSave)
          IconButton(
            tooltip: 'Save this team as a template',
            icon: const Icon(Icons.bookmark_add_outlined, size: 18,
                color: Color(0xFF8E9297)),
            onPressed: onSaveTemplate,
          ),
        _StatusBadge(status: task.status),
      ],
    );
  }
}

class _BranchTaskDialog extends StatefulWidget {
  final Task parent;
  const _BranchTaskDialog({required this.parent});

  @override
  State<_BranchTaskDialog> createState() => _BranchTaskDialogState();
}

class _BranchTaskDialogState extends State<_BranchTaskDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF2B2D31),
      title: const Text('Branch a new task', style: TextStyle(color: Colors.white)),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'The new task\'s first agent will start with the same '
              'workspace this task ended with.  Describe what should happen next.',
              style: const TextStyle(color: Color(0xFFB9BBBE), fontSize: 12),
            ),
            const SizedBox(height: 8),
            Text(
              'Parent: ${widget.parent.description}',
              style: const TextStyle(color: Color(0xFF8E9297), fontSize: 11),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _ctrl,
              autofocus: true,
              maxLines: 5,
              minLines: 3,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'New task description',
                labelStyle: TextStyle(color: Color(0xFFB9BBBE)),
                alignLabelWithHint: true,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(_ctrl.text),
          child: const Text('Branch'),
        ),
      ],
    );
  }
}

class _SaveTemplateDialog extends StatefulWidget {
  const _SaveTemplateDialog();
  @override
  State<_SaveTemplateDialog> createState() => _SaveTemplateDialogState();
}

class _SaveTemplateDialogState extends State<_SaveTemplateDialog> {
  final _nameCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();

  void _save() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop('$name\n${_noteCtrl.text}');
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF2B2D31),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Save this team as a template',
                style: TextStyle(color: Colors.white, fontSize: 16,
                    fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              const Text(
                "Tally will reuse this team verbatim when a future task is a "
                "clean match, otherwise it'll build fresh.",
                style: TextStyle(color: Color(0xFF8E9297), fontSize: 12, height: 1.4),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _nameCtrl,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Name',
                  labelStyle: TextStyle(color: Color(0xFF8E9297)),
                  hintText: 'e.g. fast-pytest, fullstack-fe-be',
                  hintStyle: TextStyle(color: Color(0xFF4F545C)),
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _save(),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _noteCtrl,
                minLines: 1,
                maxLines: 3,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: const InputDecoration(
                  labelText: 'Note (optional)',
                  labelStyle: TextStyle(color: Color(0xFF8E9297)),
                  hintText: 'When does this team shine?',
                  hintStyle: TextStyle(color: Color(0xFF4F545C)),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel',
                        style: TextStyle(color: Color(0xFF8E9297))),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF7C5CFC),
                    ),
                    icon: const Icon(Icons.bookmark_add, size: 16),
                    label: const Text('Save'),
                    onPressed: _save,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final String status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final (color, icon, label) = switch (status) {
      'completed' => (Color(0xFF57F287), Icons.check_circle, 'completed'),
      'failed' => (Color(0xFFED4245), Icons.error, 'failed'),
      'running' => (Color(0xFF5865F2), Icons.play_arrow, 'running'),
      'pending' => (Color(0xFFFEE75C), Icons.schedule, 'pending'),
      _ => (Color(0xFF8E9297), Icons.help, status),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 14),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  final Map<String, dynamic> result;
  const _ResultCard({required this.result});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF2B2D31),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF1E1F22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Result',
            style: TextStyle(color: Color(0xFFC4C9CE), fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 1.1),
          ),
          const SizedBox(height: 6),
          SelectableText(
            const JsonEncoder.withIndent('  ').convert(result),
            style: const TextStyle(color: Color(0xFFDCDDDE), fontFamily: 'monospace', fontSize: 11, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _WorkspaceCard extends StatelessWidget {
  final List<Map<String, dynamic>>? files;
  final String? filesError;
  final bool loading;
  final VoidCallback onRefresh;
  final ValueChanged<String> onFileTap;
  const _WorkspaceCard({
    required this.files,
    required this.filesError,
    required this.loading,
    required this.onRefresh,
    required this.onFileTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF2B2D31),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF1E1F22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.folder, color: Color(0xFF8E9297), size: 16),
              const SizedBox(width: 6),
              const Text(
                'Workspace',
                style: TextStyle(color: Color(0xFFC4C9CE), fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 1.1),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.refresh, size: 16, color: Color(0xFF8E9297)),
                onPressed: loading ? null : onRefresh,
              ),
            ],
          ),
          if (loading && files == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (filesError != null && files == null)
            Text(filesError!, style: const TextStyle(color: Color(0xFFED4245), fontSize: 12))
          else if (files != null)
            FileTreeView(
              root: FileTreeNode.build(files!),
              onFileTap: onFileTap,
            ),
        ],
      ),
    );
  }
}

class _FileViewerDialog extends StatefulWidget {
  final TallyOrchClient client;
  final String taskId;
  final String path;
  const _FileViewerDialog({
    required this.client,
    required this.taskId,
    required this.path,
  });

  @override
  State<_FileViewerDialog> createState() => _FileViewerDialogState();
}

class _FileViewerDialogState extends State<_FileViewerDialog> {
  String? _content;
  int? _size;
  bool _truncated = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await widget.client.readFile(widget.taskId, widget.path);
      if (!mounted) return;
      setState(() {
        _content = r.content;
        _size = r.size;
        _truncated = r.truncated;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.description, color: Color(0xFF8E9297), size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.path,
                  style: const TextStyle(
                    color: Colors.white,
                    fontFamily: 'monospace',
                    fontSize: 13,
                  ),
                ),
              ),
              if (_size != null)
                Text(
                  '$_size bytes${_truncated ? " (truncated)" : ""}',
                  style: const TextStyle(color: Color(0xFF8E9297), fontSize: 11),
                ),
              IconButton(
                icon: const Icon(Icons.close, color: Color(0xFF8E9297)),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const Divider(color: Color(0xFF1E1F22)),
          Expanded(
            child: _error != null
                ? Center(child: Text('Error: $_error', style: const TextStyle(color: Color(0xFFED4245))))
                : _content == null
                    ? const Center(child: CircularProgressIndicator())
                    : SingleChildScrollView(
                        child: SelectableText(
                          _content!,
                          style: const TextStyle(
                            color: Color(0xFFDCDDDE),
                            fontFamily: 'monospace',
                            fontSize: 12,
                            height: 1.4,
                          ),
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}
