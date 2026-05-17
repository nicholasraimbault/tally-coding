import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Persistent client config: the base URL of the tally-orch service and the
/// bearer token used to auth against it. Stored as a 0600 JSON file under the
/// platform's application-support directory (e.g. ~/.local/share/tally_coding_app
/// on Linux, ~/Library/Application Support on macOS).
///
/// Not encrypted at rest — comparable to a `~/.config/foo/token` pattern.
/// Adequate for a spike against the user's own LAN service; revisit with a
/// real secure-storage backend when the app moves to mobile or multi-user.
class Config {
  final String url;
  final String token;
  const Config({required this.url, required this.token});

  bool get isComplete => url.isNotEmpty && token.isNotEmpty;

  Map<String, dynamic> toJson() => {'url': url, 'token': token};
  factory Config.fromJson(Map<String, dynamic> j) =>
      Config(url: (j['url'] as String?) ?? '', token: (j['token'] as String?) ?? '');
}

class ConfigStore {
  static const _filename = 'tally-orch.config.json';

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File('${dir.path}/$_filename');
  }

  Future<Config> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return const Config(url: '', token: '');
      final text = await f.readAsString();
      return Config.fromJson(jsonDecode(text) as Map<String, dynamic>);
    } catch (_) {
      return const Config(url: '', token: '');
    }
  }

  Future<void> save(Config c) async {
    final f = await _file();
    await f.writeAsString(jsonEncode(c.toJson()));
    // 0600 — owner read/write only. Best-effort: on Windows this is a no-op.
    if (!Platform.isWindows) {
      try {
        await Process.run('chmod', ['600', f.path]);
      } catch (_) {/* non-fatal */}
    }
  }

  Future<void> clear() async {
    try {
      final f = await _file();
      if (await f.exists()) await f.delete();
    } catch (_) {/* non-fatal */}
  }
}
