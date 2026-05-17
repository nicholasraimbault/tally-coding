import 'package:flutter/material.dart';

/// Directories that are almost always noise (build caches, vcs metadata).
/// Collapsed by default in the tree; user can still expand them.
const _kNoiseDirs = {
  '__pycache__',
  '.pytest_cache',
  '.git',
  '.venv',
  'venv',
  'node_modules',
  '.mypy_cache',
  '.ruff_cache',
};

class FileTreeNode {
  final String name;
  final String? path; // null for the synthetic root
  final bool isDir;
  final int? size;
  final Map<String, FileTreeNode> _children = {};

  FileTreeNode({required this.name, required this.isDir, this.path, this.size});

  List<FileTreeNode> get children {
    final list = _children.values.toList()
      ..sort((a, b) {
        if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    return list;
  }

  /// Build a tree from the flat /files entries the orchestrator returns.
  /// Each entry: {"path": "a/b/c", "size": N, "is_dir": bool}.
  static FileTreeNode build(List<Map<String, dynamic>> entries) {
    final root = FileTreeNode(name: '', isDir: true);
    for (final e in entries) {
      final fullPath = e['path'] as String;
      final parts = fullPath.split('/');
      var cur = root;
      for (var i = 0; i < parts.length; i++) {
        final part = parts[i];
        final isLast = i == parts.length - 1;
        final existing = cur._children[part];
        if (existing != null) {
          cur = existing;
          continue;
        }
        // For non-leaf parts we infer dir; for the leaf, trust the is_dir flag.
        final node = FileTreeNode(
          name: part,
          isDir: !isLast || (e['is_dir'] as bool? ?? false),
          path: isLast ? fullPath : parts.sublist(0, i + 1).join('/'),
          size: isLast ? (e['size'] as int?) : null,
        );
        cur._children[part] = node;
        cur = node;
      }
    }
    return root;
  }
}

class FileTreeView extends StatelessWidget {
  final FileTreeNode root;
  final void Function(String path) onFileTap;
  const FileTreeView({super.key, required this.root, required this.onFileTap});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: root.children.map((n) => _Node(node: n, depth: 0, onFileTap: onFileTap)).toList(),
    );
  }
}

class _Node extends StatelessWidget {
  final FileTreeNode node;
  final int depth;
  final void Function(String path) onFileTap;
  const _Node({required this.node, required this.depth, required this.onFileTap});

  String _humanSize(int? bytes) {
    if (bytes == null) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final pad = EdgeInsetsDirectional.only(start: 16.0 * depth);

    if (node.isDir) {
      final initiallyExpanded = !_kNoiseDirs.contains(node.name);
      return Padding(
        padding: pad,
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 8),
          childrenPadding: EdgeInsets.zero,
          initiallyExpanded: initiallyExpanded,
          leading: Icon(Icons.folder, size: 18, color: cs.tertiary),
          title: Text(
            node.name,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: _kNoiseDirs.contains(node.name) ? cs.onSurfaceVariant : cs.onSurface,
            ),
          ),
          subtitle: Text('${node.children.length} item${node.children.length == 1 ? "" : "s"}',
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
          children: node.children.map((n) => _Node(node: n, depth: depth + 1, onFileTap: onFileTap)).toList(),
        ),
      );
    }

    // File leaf.
    return Padding(
      padding: pad,
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        leading: Icon(Icons.description, size: 16, color: cs.onSurfaceVariant),
        title: Text(node.name, style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
        trailing: Text(_humanSize(node.size),
            style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant)),
        onTap: () => onFileTap(node.path!),
      ),
    );
  }
}
