// tally_coding_app/lib/screens/workflow_editor.dart
//
// Sprint 48 B5+B6: wires in vyuh_node_flow's NodeFlowEditor + per-node config dialog
// (B5) and per-edge condition + max_iterations config dialog (B6).
// Sprint 49 B2: adds persistentAgentId constructor field; shows Trigger palette
// node when in persistent-agent context; Trigger carries cronSchedule +
// eventTriggers; save routes to updatePersistentAgent vs updateTaskTeamSpec.
//
// Data flow:
//   initialTeamSpec (nodes_v1 JSON)
//     → _specToNodes / _specToConnections  (on init)
//     → NodeFlowController<_AgentNodeData, _EdgeData>
//     → NodeFlowEditor (interactive canvas with drag, connect, pan, zoom)
//     → NodeEvents.onTap → _NodeConfigDialog / _TriggerConfigDialog
//     → ConnectionEvents.onTap → _EdgeConfigDialog → mutates conn.data + label
//     → NodeEvents.onDragStop, ConnectionEvents.onCreated/onDeleted → _syncSpec
//     → Save → PATCH /tasks/{id}/team_spec  (task context)
//           OR PATCH /persistent_agents/{id} (persistent-agent context)
//
// Palette: Draggable<String> items targeting DragTarget wrapping the canvas.
// Fallback "+ Add" buttons work without drag support.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:vyuh_node_flow/vyuh_node_flow.dart';

import '../api.dart';

// ---------------------------------------------------------------------------
// Per-edge data model (carried as Connection<C>.data)
// ---------------------------------------------------------------------------
class _EdgeData {
  /// One of: 'always' | 'if_succeeded' | 'if_failed'
  String condition;

  /// Optional iteration cap for back-edges (null means no limit).
  int? maxIterations;

  _EdgeData({this.condition = 'always', this.maxIterations});
}

// ---------------------------------------------------------------------------
// Per-node data model (carried as Node<T>.data)
// ---------------------------------------------------------------------------
class _AgentNodeData implements NodeData {
  _AgentNodeData({
    required this.kind,
    this.role = '',
    this.model = '',
    this.spec = '',
    this.workerAffinity = 'any',
    this.cronSchedule = '',
    this.eventTriggers = const <Map<String, dynamic>>[],
  });

  final String kind; // 'agent' | 'output' | 'trigger'
  String role;
  String model;
  String spec;
  String workerAffinity;
  // Trigger-only fields (unused when kind != 'trigger').
  String cronSchedule;
  List<Map<String, dynamic>> eventTriggers;

  @override
  NodeData clone() => _AgentNodeData(
    kind: kind,
    role: role,
    model: model,
    spec: spec,
    workerAffinity: workerAffinity,
    cronSchedule: cronSchedule,
    eventTriggers: List<Map<String, dynamic>>.from(eventTriggers),
  );
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------
const _roles = ['Coder', 'Reviewer', 'Tester', 'Architect', 'Solo Coder'];
const _affinities = ['any', 'tee', 'local', 'local_if_available'];

// ---------------------------------------------------------------------------
// Spec ↔ vyuh_node_flow mappers
// ---------------------------------------------------------------------------
List<Node<_AgentNodeData>> _specToNodes(Map<String, dynamic> spec) {
  final rawNodes = (spec['nodes'] as List<dynamic>?) ?? [];
  final result = <Node<_AgentNodeData>>[];
  for (var i = 0; i < rawNodes.length; i++) {
    final n = rawNodes[i] as Map<String, dynamic>;
    final id = (n['id'] as String?) ?? 'n$i';
    final kind = (n['kind'] as String?) ?? 'agent';
    final data = _AgentNodeData(
      kind: kind,
      role: (n['role'] as String?) ?? '',
      model: (n['model'] as String?) ?? '',
      spec: (n['spec'] as String?) ?? '',
      workerAffinity: (n['worker_affinity'] as String?) ?? 'any',
      cronSchedule: (n['cron_schedule'] as String?) ?? '',
      eventTriggers:
          (n['event_triggers'] as List?)?.cast<Map<String, dynamic>>() ??
          const <Map<String, dynamic>>[],
    );
    // Lay nodes out horizontally if no saved position present.
    final xPos = (n['__x'] as num?)?.toDouble() ?? (i * 220.0 + 60);
    final yPos = (n['__y'] as num?)?.toDouble() ?? 120.0;
    result.add(
      Node<_AgentNodeData>(
        id: id,
        type: kind,
        position: Offset(xPos, yPos),
        data: data,
        ports: _portsForKind(kind),
      ),
    );
  }
  return result;
}

List<Port> _portsForKind(String kind) {
  // Trigger nodes start the flow — they have no input port.
  if (kind == 'trigger') {
    return [
      Port(
        id: 'out',
        name: 'out',
        position: PortPosition.right,
        type: PortType.output,
        multiConnections: true,
      ),
    ];
  }
  return [
    Port(
      id: 'in',
      name: 'in',
      position: PortPosition.left,
      type: PortType.input,
      multiConnections: true,
    ),
    Port(
      id: 'out',
      name: 'out',
      position: PortPosition.right,
      type: PortType.output,
      multiConnections: true,
    ),
  ];
}

List<Connection<_EdgeData>> _specToConnections(Map<String, dynamic> spec) {
  final rawEdges = (spec['edges'] as List<dynamic>?) ?? [];
  final result = <Connection<_EdgeData>>[];
  for (var i = 0; i < rawEdges.length; i++) {
    final e = rawEdges[i] as Map<String, dynamic>;
    final from = e['from'] as String?;
    final to = e['to'] as String?;
    if (from == null || to == null) continue;
    final condition = (e['condition'] as String?) ?? 'always';
    final maxIter = e['max_iterations'] as int?;
    final data = _EdgeData(condition: condition, maxIterations: maxIter);
    result.add(
      Connection<_EdgeData>(
        id: 'e_${from}_${to}_$i',
        sourceNodeId: from,
        sourcePortId: 'out',
        targetNodeId: to,
        targetPortId: 'in',
        data: data,
        label: _edgeLabel(data),
      ),
    );
  }
  return result;
}

/// Builds the visible connection label from edge data, or null for the default
/// (unlabelled 'always' with no iteration cap).
ConnectionLabel? _edgeLabel(_EdgeData data) {
  final showCondition = data.condition != 'always';
  final showMax = data.maxIterations != null;
  if (!showCondition && !showMax) return null;
  final parts = [
    if (showCondition) data.condition,
    if (showMax) '×${data.maxIterations}',
  ];
  return ConnectionLabel.center(text: parts.join(' '));
}

/// Reads current controller state back into nodes_v1 format.
/// Preserves __x/__y so reopening the editor keeps positions.
Map<String, dynamic> _controllerToSpec(
  NodeFlowController<_AgentNodeData, _EdgeData> controller,
  Map<String, dynamic> existingSpec,
) {
  final nodes = controller.nodes.values.map((node) {
    final d = node.data;
    return <String, dynamic>{
      'id': node.id,
      'kind': d.kind,
      if (d.kind == 'agent') 'role': d.role,
      if (d.kind == 'agent') 'model': d.model,
      if (d.kind == 'agent') 'spec': d.spec,
      if (d.kind == 'agent') 'worker_affinity': d.workerAffinity,
      if (d.kind == 'output') 'role': d.role,
      if (d.kind == 'output') 'model': d.model,
      if (d.kind == 'trigger') 'cron_schedule': d.cronSchedule,
      if (d.kind == 'trigger') 'event_triggers': d.eventTriggers,
      '__x': node.position.value.dx,
      '__y': node.position.value.dy,
    };
  }).toList();

  final edges = controller.connections.map((conn) {
    final data = conn.data;
    final entry = <String, dynamic>{
      'from': conn.sourceNodeId,
      'to': conn.targetNodeId,
      'condition': data?.condition ?? 'always',
    };
    if (data?.maxIterations != null) {
      entry['max_iterations'] = data!.maxIterations;
    }
    return entry;
  }).toList();

  return <String, dynamic>{
    ...existingSpec,
    'nodes': nodes,
    'edges': edges,
    'format': 'nodes_v1',
  };
}

// ---------------------------------------------------------------------------
// WorkflowEditorScreen
// ---------------------------------------------------------------------------
class WorkflowEditorScreen extends StatefulWidget {
  final TallyOrchClient client;

  /// Task-context (Sprint 48): pass this when editing a task's team spec.
  final String? taskId;

  /// Persistent-agent context (Sprint 49 B2): pass this instead of taskId
  /// when editing a persistent agent's workflow. Exactly one of taskId /
  /// persistentAgentId must be non-null.
  final int? persistentAgentId;

  final Map<String, dynamic> initialTeamSpec;

  const WorkflowEditorScreen({
    super.key,
    required this.client,
    this.taskId,
    this.persistentAgentId,
    required this.initialTeamSpec,
  }) : assert(
         taskId != null || persistentAgentId != null,
         'Either taskId or persistentAgentId must be provided',
       );

  @override
  State<WorkflowEditorScreen> createState() => _WorkflowEditorScreenState();
}

class _WorkflowEditorScreenState extends State<WorkflowEditorScreen> {
  late Map<String, dynamic> _spec;
  late NodeFlowController<_AgentNodeData, _EdgeData> _controller;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _spec = Map<String, dynamic>.from(widget.initialTeamSpec);
    _spec['nodes'] ??= <dynamic>[];
    _spec['edges'] ??= <dynamic>[];
    _spec['format'] = 'nodes_v1';

    _controller = NodeFlowController<_AgentNodeData, _EdgeData>(
      nodes: _specToNodes(_spec),
      connections: _specToConnections(_spec),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _syncSpec() {
    final updated = _controllerToSpec(_controller, _spec);
    if (mounted) setState(() => _spec = updated);
  }

  Future<void> _save() async {
    if (_saving) return;
    _syncSpec();
    setState(() => _saving = true);
    try {
      if (widget.taskId != null) {
        await widget.client.updateTaskTeamSpec(
          taskId: widget.taskId!,
          teamSpec: _spec,
        );
      } else if (widget.persistentAgentId != null) {
        // Sprint 49 B2: persistent-agent context — send team_spec via PATCH.
        await widget.client.updatePersistentAgent(
          id: widget.persistentAgentId!,
          patch: <String, dynamic>{'team_spec': _spec},
        );
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _onNodeTap(Node<_AgentNodeData> node) async {
    final data = node.data;

    if (data.kind == 'trigger') {
      final updated = await showDialog<_AgentNodeData>(
        context: context,
        builder: (_) => _TriggerConfigDialog(initial: data),
      );
      if (updated == null || !mounted) return;
      data
        ..cronSchedule = updated.cronSchedule
        ..eventTriggers = updated.eventTriggers;
      _syncSpec();
      return;
    }

    final updated = await showDialog<_AgentNodeData>(
      context: context,
      builder: (_) => _NodeConfigDialog(initial: data),
    );
    if (updated == null || !mounted) return;
    data
      ..role = updated.role
      ..model = updated.model
      ..spec = updated.spec
      ..workerAffinity = updated.workerAffinity;
    _syncSpec();
  }

  Future<void> _onConnectionTap(Connection<_EdgeData> conn) async {
    final initial = conn.data ?? _EdgeData();
    final result = await showDialog<_EdgeData>(
      context: context,
      builder: (_) => _EdgeConfigDialog(initial: initial),
    );
    if (result == null || !mounted) return;

    // Mutate the data in-place (data fields are non-final).
    if (conn.data != null) {
      conn.data!.condition = result.condition;
      conn.data!.maxIterations = result.maxIterations;
    }

    // Update the visible label reactively via the observable setter.
    conn.label = _edgeLabel(result);

    _syncSpec();
  }

  void _addNode(String kind, Offset canvasPosition) {
    final id = '${kind}_${DateTime.now().millisecondsSinceEpoch}';
    final node = Node<_AgentNodeData>(
      id: id,
      type: kind,
      position: canvasPosition,
      data: _AgentNodeData(
        kind: kind,
        role: kind == 'output' ? 'Output' : '',
      ),
      ports: _portsForKind(kind),
    );
    _controller.addNode(node);
    _syncSpec();
  }

  bool get _hasTriggerNode =>
      _controller.nodes.values.any((n) => n.data.kind == 'trigger');

  bool get _hasOutputNode =>
      _controller.nodes.values.any((n) => n.data.kind == 'output');

  @override
  Widget build(BuildContext context) {
    // Events are passed to NodeFlowEditor (the public API) not set on controller
    // directly, so we rebuild when _spec changes and the widget tree refreshes.
    final events = NodeFlowEvents<_AgentNodeData, _EdgeData>(
      node: NodeEvents<_AgentNodeData>(
        onTap: _onNodeTap,
        onDragStop: (_) => _syncSpec(),
        onDeleted: (_) => _syncSpec(),
      ),
      connection: ConnectionEvents<_AgentNodeData, _EdgeData>(
        onTap: _onConnectionTap,
        onCreated: (_) => _syncSpec(),
        onDeleted: (_) => _syncSpec(),
      ),
    );

    final titleText = widget.taskId != null
        ? 'Edit team for ${widget.taskId!.substring(0, 8)}'
        : 'Edit workflow for agent #${widget.persistentAgentId}';

    return Scaffold(
      appBar: AppBar(
        title: Text(titleText),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Saving…' : 'Save'),
          ),
        ],
      ),
      body: Row(
        children: [
          // ── Left rail: palette ─────────────────────────────────────────
          SizedBox(
            width: 200,
            child: Container(
              color: const Color(0xFF2B2D31),
              child: _Palette(
                hasOutputNode: _hasOutputNode,
                hasTriggerNode: _hasTriggerNode,
                showTrigger: widget.persistentAgentId != null,
                onAddFallback: (kind) {
                  _addNode(
                    kind,
                    Offset(80 + math.Random().nextDouble() * 100, 120),
                  );
                },
              ),
            ),
          ),
          // ── Canvas ────────────────────────────────────────────────────
          Expanded(
            child: _FlowCanvas(
              controller: _controller,
              events: events,
              onDropKind: (kind, localPosition) {
                if (kind == 'output' && _hasOutputNode) return;
                if (kind == 'trigger' && _hasTriggerNode) return;
                _addNode(kind, localPosition);
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _Palette — drag sources + fallback "Add" buttons
// ---------------------------------------------------------------------------
class _Palette extends StatelessWidget {
  final bool hasOutputNode;
  final bool hasTriggerNode;

  /// Whether to show the Trigger palette item (true in persistent-agent context).
  final bool showTrigger;
  final void Function(String kind) onAddFallback;

  const _Palette({
    required this.hasOutputNode,
    required this.hasTriggerNode,
    required this.showTrigger,
    required this.onAddFallback,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text(
            'PALETTE',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
        ),
        if (showTrigger) ...[
          _PaletteItem(
            kind: 'trigger',
            label: 'Trigger',
            icon: Icons.alarm,
            color: const Color(0xFFED4245),
            // Trigger is a singleton — disable when already present.
            disabled: hasTriggerNode,
            onAddFallback: onAddFallback,
          ),
          const SizedBox(height: 6),
        ],
        _PaletteItem(
          kind: 'agent',
          label: 'Agent',
          icon: Icons.smart_toy_outlined,
          color: const Color(0xFF5865F2),
          disabled: false,
          onAddFallback: onAddFallback,
        ),
        const SizedBox(height: 6),
        _PaletteItem(
          kind: 'output',
          label: 'Output',
          icon: Icons.output_outlined,
          color: const Color(0xFF57F287),
          // Output is a singleton — disable when already present.
          disabled: hasOutputNode,
          onAddFallback: onAddFallback,
        ),
        const Padding(
          padding: EdgeInsets.only(top: 16),
          child: Text(
            'Drag onto canvas or tap + to add.',
            style: TextStyle(color: Colors.white24, fontSize: 10),
          ),
        ),
      ],
    );
  }
}

class _PaletteItem extends StatelessWidget {
  final String kind;
  final String label;
  final IconData icon;
  final Color color;
  final bool disabled;
  final void Function(String) onAddFallback;

  const _PaletteItem({
    required this.kind,
    required this.label,
    required this.icon,
    required this.color,
    required this.disabled,
    required this.onAddFallback,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveColor = disabled ? Colors.white24 : color;
    final tile = ListTile(
      dense: true,
      leading: Icon(icon, color: effectiveColor, size: 20),
      title: Text(
        label,
        style: TextStyle(
          color: disabled ? Colors.white24 : Colors.white,
          fontSize: 13,
        ),
      ),
      trailing: disabled
          ? null
          : IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              icon: const Icon(Icons.add, color: Colors.white54, size: 18),
              onPressed: () => onAddFallback(kind),
              tooltip: 'Add $label node',
            ),
    );

    if (disabled) return tile;

    return Draggable<String>(
      data: kind,
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: 16),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ],
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: tile),
      child: tile,
    );
  }
}

// ---------------------------------------------------------------------------
// _FlowCanvas — DragTarget wrapper around NodeFlowEditor
// ---------------------------------------------------------------------------
class _FlowCanvas extends StatelessWidget {
  final NodeFlowController<_AgentNodeData, _EdgeData> controller;
  final NodeFlowEvents<_AgentNodeData, _EdgeData> events;
  final void Function(String kind, Offset localPosition) onDropKind;

  const _FlowCanvas({
    required this.controller,
    required this.events,
    required this.onDropKind,
  });

  @override
  Widget build(BuildContext context) {
    return DragTarget<String>(
      onAcceptWithDetails: (details) {
        final box = context.findRenderObject() as RenderBox?;
        final localPos = box?.globalToLocal(details.offset) ?? details.offset;
        onDropKind(details.data, localPos);
      },
      builder: (context, candidateData, _) {
        return Stack(
          children: [
            NodeFlowEditor<_AgentNodeData, _EdgeData>(
              controller: controller,
              theme: NodeFlowTheme.dark,
              events: events,
              nodeBuilder: (ctx, node) => _AgentNodeWidget(node: node),
            ),
            // Highlight drop zone while dragging over canvas.
            if (candidateData.isNotEmpty)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: const Color(0xFF5865F2).withValues(alpha: 0.5),
                        width: 2,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// _AgentNodeWidget — renders a single node in the canvas
// ---------------------------------------------------------------------------
class _AgentNodeWidget extends StatelessWidget {
  final Node<_AgentNodeData> node;

  const _AgentNodeWidget({required this.node});

  @override
  Widget build(BuildContext context) {
    final data = node.data;
    final isOutput = data.kind == 'output';
    final isTrigger = data.kind == 'trigger';
    final accentColor = isTrigger
        ? const Color(0xFFED4245)
        : isOutput
            ? const Color(0xFF57F287)
            : const Color(0xFF5865F2);

    return Observer(
      builder: (_) {
        final selected = node.isSelected;
        return Container(
          constraints: const BoxConstraints(minWidth: 150, minHeight: 72),
          decoration: BoxDecoration(
            color: const Color(0xFF2B2D31),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? accentColor : const Color(0xFF40444B),
              width: selected ? 2 : 1,
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isTrigger
                        ? Icons.alarm
                        : isOutput
                            ? Icons.output_outlined
                            : Icons.smart_toy_outlined,
                    color: accentColor,
                    size: 13,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    isTrigger ? 'Trigger' : isOutput ? 'Output' : 'Agent',
                    style: TextStyle(
                      color: accentColor,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
              if (isTrigger) ...[
                const SizedBox(height: 4),
                if (data.cronSchedule.isNotEmpty)
                  Text(
                    data.cronSchedule,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                if (data.eventTriggers.isNotEmpty)
                  Text(
                    '${data.eventTriggers.length} event trigger'
                    '${data.eventTriggers.length == 1 ? '' : 's'}',
                    style: const TextStyle(color: Colors.white54, fontSize: 10),
                  ),
                if (data.cronSchedule.isEmpty && data.eventTriggers.isEmpty)
                  const Text(
                    'Tap to configure',
                    style: TextStyle(color: Colors.white38, fontSize: 10),
                  ),
              ] else ...[
                if (data.role.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    data.role,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
                if (data.model.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    data.model,
                    style: const TextStyle(color: Colors.white38, fontSize: 10),
                  ),
                ],
                if (data.role.isEmpty && !isOutput)
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Text(
                      'Tap to configure',
                      style: TextStyle(color: Colors.white38, fontSize: 10),
                    ),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// _EdgeConfigDialog — per-edge config: condition dropdown + max_iterations
// ---------------------------------------------------------------------------
class _EdgeConfigDialog extends StatefulWidget {
  final _EdgeData initial;

  const _EdgeConfigDialog({required this.initial});

  @override
  State<_EdgeConfigDialog> createState() => _EdgeConfigDialogState();
}

class _EdgeConfigDialogState extends State<_EdgeConfigDialog> {
  late String _condition;
  late TextEditingController _maxIterCtrl;

  @override
  void initState() {
    super.initState();
    _condition = widget.initial.condition;
    _maxIterCtrl = TextEditingController(
      text: widget.initial.maxIterations?.toString() ?? '',
    );
  }

  @override
  void dispose() {
    _maxIterCtrl.dispose();
    super.dispose();
  }

  void _save() {
    final maxIter = int.tryParse(_maxIterCtrl.text.trim());
    Navigator.of(context).pop(
      _EdgeData(condition: _condition, maxIterations: maxIter),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edge condition'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _condition,
              decoration: const InputDecoration(
                labelText: 'When to fire',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: const [
                DropdownMenuItem(value: 'always', child: Text('Always')),
                DropdownMenuItem(
                  value: 'if_succeeded',
                  child: Text('If predecessor succeeded'),
                ),
                DropdownMenuItem(
                  value: 'if_failed',
                  child: Text('If predecessor failed'),
                ),
              ],
              onChanged: (v) {
                if (v != null) setState(() => _condition = v);
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _maxIterCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Max iterations',
                hintText: 'Leave blank for no limit (back-edges only)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// _TriggerConfigDialog — per-trigger config: cronSchedule + eventTriggers
// ---------------------------------------------------------------------------
class _TriggerConfigDialog extends StatefulWidget {
  final _AgentNodeData initial;

  const _TriggerConfigDialog({required this.initial});

  @override
  State<_TriggerConfigDialog> createState() => _TriggerConfigDialogState();
}

class _TriggerConfigDialogState extends State<_TriggerConfigDialog> {
  late TextEditingController _cronCtrl;
  late List<Map<String, dynamic>> _triggers;
  late List<TextEditingController> _nameCtrlList;

  // Common cron presets for quick entry.
  static const _commonCrons = <Map<String, String>>[
    {'label': 'every minute', 'value': '* * * * *'},
    {'label': 'every hour', 'value': '0 * * * *'},
    {'label': 'daily 9am', 'value': '0 9 * * *'},
    {'label': 'weekdays 9am', 'value': '0 9 * * 1-5'},
    {'label': 'nightly 9pm', 'value': '0 21 * * *'},
  ];

  @override
  void initState() {
    super.initState();
    _cronCtrl = TextEditingController(text: widget.initial.cronSchedule);
    _triggers = List<Map<String, dynamic>>.from(
      widget.initial.eventTriggers.map((t) => Map<String, dynamic>.from(t)),
    );
    _nameCtrlList = _triggers
        .map((t) => TextEditingController(text: (t['name'] as String?) ?? ''))
        .toList();
  }

  @override
  void dispose() {
    _cronCtrl.dispose();
    for (final c in _nameCtrlList) {
      c.dispose();
    }
    super.dispose();
  }

  void _addEventTrigger() {
    setState(() {
      _triggers.add(<String, dynamic>{
        'kind': 'http',
        'name': 'webhook ${_triggers.length + 1}',
      });
      _nameCtrlList.add(
        TextEditingController(text: 'webhook ${_triggers.length}'),
      );
    });
  }

  void _removeEventTrigger(int index) {
    setState(() {
      _nameCtrlList[index].dispose();
      _nameCtrlList.removeAt(index);
      _triggers.removeAt(index);
    });
  }

  void _save() {
    // Flush name controller text back into trigger maps before returning.
    for (var i = 0; i < _triggers.length; i++) {
      _triggers[i]['name'] = _nameCtrlList[i].text.trim();
    }
    Navigator.of(context).pop(
      _AgentNodeData(
        kind: 'trigger',
        cronSchedule: _cronCtrl.text.trim(),
        eventTriggers: List<Map<String, dynamic>>.from(_triggers),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Trigger config'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Cron schedule',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              TextField(
                controller: _cronCtrl,
                decoration: const InputDecoration(
                  hintText: '0 9 * * *  (leave blank to disable)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final pat in _commonCrons)
                    ActionChip(
                      label: Text(
                        pat['label']!,
                        style: const TextStyle(fontSize: 11),
                      ),
                      onPressed: () =>
                          setState(() => _cronCtrl.text = pat['value']!),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              const Text(
                'Event triggers',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              for (int i = 0; i < _triggers.length; i++)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.webhook, size: 20),
                  title: TextField(
                    controller: _nameCtrlList[i],
                    decoration: const InputDecoration(
                      labelText: 'name',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                  subtitle: _triggers[i].containsKey('id')
                      ? SelectableText(
                          'ID: ${_triggers[i]['id']}'
                          '${_triggers[i].containsKey('secret') ? '\nSecret: ${_triggers[i]['secret']}' : ''}',
                          style: const TextStyle(
                            fontSize: 10,
                            color: Color(0xFF949BA4),
                          ),
                        )
                      : const Text(
                          'Save → server will generate id + secret',
                          style: TextStyle(
                            fontSize: 10,
                            color: Color(0xFF949BA4),
                          ),
                        ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    tooltip: 'Remove trigger',
                    onPressed: () => _removeEventTrigger(i),
                  ),
                ),
              TextButton.icon(
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add event trigger'),
                onPressed: _addEventTrigger,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// _NodeConfigDialog — per-node config: role, model, spec, worker_affinity
// ---------------------------------------------------------------------------
class _NodeConfigDialog extends StatefulWidget {
  final _AgentNodeData initial;

  const _NodeConfigDialog({required this.initial});

  @override
  State<_NodeConfigDialog> createState() => _NodeConfigDialogState();
}

class _NodeConfigDialogState extends State<_NodeConfigDialog> {
  late String _role;
  late String _workerAffinity;
  late TextEditingController _modelCtrl;
  late TextEditingController _specCtrl;

  @override
  void initState() {
    super.initState();
    final initialRole = widget.initial.role;
    _role = (_roles.contains(initialRole) && initialRole.isNotEmpty)
        ? initialRole
        : _roles.first;
    final initialAffinity = widget.initial.workerAffinity;
    _workerAffinity = _affinities.contains(initialAffinity)
        ? initialAffinity
        : 'any';
    _modelCtrl = TextEditingController(text: widget.initial.model);
    _specCtrl = TextEditingController(text: widget.initial.spec);
  }

  @override
  void dispose() {
    _modelCtrl.dispose();
    _specCtrl.dispose();
    super.dispose();
  }

  void _save() {
    Navigator.of(context).pop(
      _AgentNodeData(
        kind: widget.initial.kind,
        role: _role,
        model: _modelCtrl.text.trim(),
        spec: _specCtrl.text.trim(),
        workerAffinity: _workerAffinity,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isOutput = widget.initial.kind == 'output';
    return AlertDialog(
      title: Text(isOutput ? 'Configure Output node' : 'Configure Agent node'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!isOutput) ...[
                const Text('Role'),
                const SizedBox(height: 4),
                DropdownButtonFormField<String>(
                  initialValue: _role,
                  items: _roles
                      .map((r) => DropdownMenuItem(value: r, child: Text(r)))
                      .toList(),
                  onChanged: (v) => setState(() => _role = v!),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
              ],
              const Text('Model'),
              const SizedBox(height: 4),
              TextField(
                controller: _modelCtrl,
                decoration: const InputDecoration(
                  hintText: 'e.g. gpt-4o, claude-3-5-sonnet',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              const Text('Spec (prompt / instructions)'),
              const SizedBox(height: 4),
              TextField(
                controller: _specCtrl,
                maxLines: 5,
                decoration: const InputDecoration(
                  hintText: 'Agent instructions…',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              const Text('Worker affinity'),
              const SizedBox(height: 4),
              DropdownButtonFormField<String>(
                initialValue: _workerAffinity,
                items: _affinities
                    .map((a) => DropdownMenuItem(value: a, child: Text(a)))
                    .toList(),
                onChanged: (v) => setState(() => _workerAffinity = v!),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
