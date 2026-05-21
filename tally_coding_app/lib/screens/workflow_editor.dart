// tally_coding_app/lib/screens/workflow_editor.dart
//
// Sprint 48: workflow editor.  Opens with a team_spec (nodes_v1 form)
// pre-loaded; user can drag agent nodes from the left rail palette,
// edit per-node config, draw edges with conditions, and Save to
// PATCH /tasks/{id}/team_spec.  Save does NOT trigger dispatch — the
// user must Approve the proposal card in #general afterward.
//
// B4 ships the scaffold; B5 wires in vyuh_node_flow's FlowEditor +
// per-node config dialog; B6 adds per-edge config.
import 'package:flutter/material.dart';
import '../api.dart';

class WorkflowEditorScreen extends StatefulWidget {
  final TallyOrchClient client;
  final String taskId;
  final Map<String, dynamic> initialTeamSpec;
  const WorkflowEditorScreen({
    super.key,
    required this.client,
    required this.taskId,
    required this.initialTeamSpec,
  });

  @override
  State<WorkflowEditorScreen> createState() => _WorkflowEditorScreenState();
}

class _WorkflowEditorScreenState extends State<WorkflowEditorScreen> {
  late Map<String, dynamic> _spec;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _spec = Map<String, dynamic>.from(widget.initialTeamSpec);
    _spec['nodes'] ??= [];
    _spec['edges'] ??= [];
    _spec['format'] = 'nodes_v1';
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.client.updateTaskTeamSpec(taskId: widget.taskId, teamSpec: _spec);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Save failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Edit team for ${widget.taskId.substring(0, 8)}'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Saving…' : 'Save'),
          ),
        ],
      ),
      body: Row(
        children: [
          SizedBox(
            width: 200,
            child: Container(
              color: const Color(0xFF2B2D31),
              child: const _PalettePlaceholder(),
            ),
          ),
          Expanded(child: _CanvasPlaceholder(spec: _spec, onChange: (s) => setState(() => _spec = s))),
        ],
      ),
    );
  }
}

class _PalettePlaceholder extends StatelessWidget {
  const _PalettePlaceholder();
  @override
  Widget build(BuildContext context) {
    return const Center(child: Text('Palette\n(B5)', textAlign: TextAlign.center));
  }
}

class _CanvasPlaceholder extends StatelessWidget {
  final Map<String, dynamic> spec;
  final void Function(Map<String, dynamic>) onChange;
  const _CanvasPlaceholder({required this.spec, required this.onChange});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        'Canvas placeholder.\nnodes: ${(spec['nodes'] as List?)?.length ?? 0}\nedges: ${(spec['edges'] as List?)?.length ?? 0}',
        textAlign: TextAlign.center,
      ),
    );
  }
}
