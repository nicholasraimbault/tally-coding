import 'package:flutter/material.dart';

import 'api.dart';
import 'config.dart';
import 'screens/config_screen.dart';
import 'screens/task_detail.dart';
import 'screens/task_list.dart';

void main() {
  runApp(const _Boot());
}

class _Boot extends StatefulWidget {
  const _Boot();
  @override
  State<_Boot> createState() => _BootState();
}

class _BootState extends State<_Boot> {
  final _store = ConfigStore();
  Config? _config;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final c = await _store.load();
    if (!mounted) return;
    setState(() {
      _config = c;
      _loading = false;
    });
  }

  void _onConfigSaved() async {
    final c = await _store.load();
    if (!mounted) return;
    setState(() => _config = c);
  }

  @override
  Widget build(BuildContext context) {
    final theme = ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF7C5CFC),
        brightness: Brightness.dark,
      ),
      useMaterial3: true,
    );

    if (_loading) {
      return MaterialApp(
        theme: theme,
        home: const Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }

    final c = _config!;
    if (!c.isComplete) {
      return MaterialApp(
        theme: theme,
        home: ConfigScreen(initial: c, store: _store, onSaved: _onConfigSaved),
      );
    }

    final client = TallyOrchClient(baseUrl: Uri.parse(c.url), token: c.token);
    // Optional deep-link (dev/screenshot use): open a specific task on startup.
    final openTaskId = const String.fromEnvironment('TALLY_OPEN_TASK_ID');
    return MaterialApp(
      title: 'Tally Coding',
      theme: theme,
      home: openTaskId.isNotEmpty
          ? TaskDetailScreen(client: client, taskId: openTaskId)
          : TaskListScreen(client: client),
      builder: (context, child) => _ConfigInheritedWidget(store: _store, onReset: _resetConfig, child: child!),
    );
  }

  void _resetConfig() async {
    await _store.clear();
    if (!mounted) return;
    setState(() => _config = const Config(url: '', token: ''));
  }
}

/// Lets descendant widgets (e.g. a Settings button) reset the saved config
/// without dragging the boot state around explicitly.
class _ConfigInheritedWidget extends InheritedWidget {
  final ConfigStore store;
  final VoidCallback onReset;
  const _ConfigInheritedWidget({required this.store, required this.onReset, required super.child});

  static _ConfigInheritedWidget? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ConfigInheritedWidget>();

  @override
  bool updateShouldNotify(_ConfigInheritedWidget old) => false;
}

/// Public-ish helper so screens can show a "Reconnect" / "Sign out" button.
void resetTallyConfig(BuildContext context) {
  _ConfigInheritedWidget.of(context)?.onReset();
}
