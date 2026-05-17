import 'package:flutter/material.dart';

import '../config.dart';

class ConfigScreen extends StatefulWidget {
  final Config initial;
  final ConfigStore store;
  final VoidCallback onSaved;
  const ConfigScreen({
    super.key,
    required this.initial,
    required this.store,
    required this.onSaved,
  });

  @override
  State<ConfigScreen> createState() => _ConfigScreenState();
}

class _ConfigScreenState extends State<ConfigScreen> {
  late final TextEditingController _url;
  late final TextEditingController _token;
  bool _tokenVisible = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: widget.initial.url.isEmpty ? 'http://127.0.0.1:8080' : widget.initial.url);
    _token = TextEditingController(text: widget.initial.token);
  }

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final url = _url.text.trim();
    final token = _token.text.trim();
    if (url.isEmpty || token.isEmpty) return;
    setState(() => _saving = true);
    await widget.store.save(Config(url: url, token: token));
    if (!mounted) return;
    widget.onSaved();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Connect to tally-orch')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Point the app at a running tally-orch service and paste its bearer token.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _url,
              decoration: const InputDecoration(
                labelText: 'Service URL',
                hintText: 'http://192.168.x.y:8080',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.dns),
              ),
              keyboardType: TextInputType.url,
              autocorrect: false,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _token,
              decoration: InputDecoration(
                labelText: 'API token',
                hintText: 'Paste TALLY_API_TOKEN from the service host',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.vpn_key),
                suffixIcon: IconButton(
                  icon: Icon(_tokenVisible ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _tokenVisible = !_tokenVisible),
                ),
              ),
              obscureText: !_tokenVisible,
              autocorrect: false,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              icon: _saving
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.check),
              label: Text(_saving ? 'Saving…' : 'Save and connect'),
              onPressed: _saving ? null : _save,
            ),
            const SizedBox(height: 16),
            Text(
              'The URL and token are stored via flutter_secure_storage (libsecret on Linux, Keychain on iOS/macOS). The token never appears in logs and is sent only as an Authorization: Bearer header.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
