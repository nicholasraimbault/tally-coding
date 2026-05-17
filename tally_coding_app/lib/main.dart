import 'package:flutter/material.dart';

import 'api.dart';
import 'config.dart';
import 'screens/config_screen.dart';
import 'screens/discord_shell.dart';

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
    // Sprint 25: Discord-dark theme. Background colors are applied at the
    // widget level for the four panels; this theme covers fallback chrome
    // (dialogs, buttons, text-field defaults).
    final theme = ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF7C5CFC),
        brightness: Brightness.dark,
        surface: const Color(0xFF313338),
      ),
      scaffoldBackgroundColor: const Color(0xFF1E1F22),
      useMaterial3: true,
      fontFamily: 'sans-serif',
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
    // Dev / screenshot use: -DTALLY_OPEN_TASK_ID=<task_id> jumps directly
    // to that channel on startup (handy when the smoke test needs to land
    // on a specific task view).
    const openTaskId = String.fromEnvironment('TALLY_OPEN_TASK_ID');
    return MaterialApp(
      title: 'Tally Coding',
      theme: theme,
      debugShowCheckedModeBanner: false,
      home: DiscordShellScreen(
        client: client,
        initialTaskId: openTaskId.isNotEmpty ? openTaskId : null,
      ),
      builder: (context, child) => _ConfigInheritedWidget(
        store: _store,
        onReset: _resetConfig,
        child: child!,
      ),
    );
  }

  void _resetConfig() async {
    await _store.clear();
    if (!mounted) return;
    setState(() => _config = const Config(url: '', token: ''));
  }
}

/// Lets descendant widgets (e.g. the server-rail sign-out button) reset
/// the saved config without dragging the boot state around explicitly.
class _ConfigInheritedWidget extends InheritedWidget {
  final ConfigStore store;
  final VoidCallback onReset;
  const _ConfigInheritedWidget({required this.store, required this.onReset, required super.child});

  static _ConfigInheritedWidget? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ConfigInheritedWidget>();

  @override
  bool updateShouldNotify(_ConfigInheritedWidget old) => false;
}

void resetTallyConfig(BuildContext context) {
  _ConfigInheritedWidget.of(context)?.onReset();
}
