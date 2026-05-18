import 'dart:convert';

import 'package:http/http.dart' as http;

class UnauthorizedException implements Exception {
  const UnauthorizedException();
  @override
  String toString() => 'unauthorized (set or fix the bearer token)';
}

class Task {
  final String id;
  final String description;
  final String status;
  final Map<String, dynamic>? result;
  final String? error;
  final double createdAt;
  final double updatedAt;
  /// Sprint 25: the architect-picked team for this task (null on legacy
  /// single-agent submissions). Shape:
  /// `{agents: [{role, model, spec, agent_idx}], workflow, reasoning}`.
  final Map<String, dynamic>? teamSpec;

  Task({
    required this.id,
    required this.description,
    required this.status,
    this.result,
    this.error,
    required this.createdAt,
    required this.updatedAt,
    this.teamSpec,
  });

  factory Task.fromJson(Map<String, dynamic> j) => Task(
        id: j['id'] as String,
        description: j['description'] as String,
        status: j['status'] as String,
        result: j['result'] as Map<String, dynamic>?,
        error: j['error'] as String?,
        createdAt: (j['created_at'] as num).toDouble(),
        updatedAt: (j['updated_at'] as num).toDouble(),
        teamSpec: j['team_spec'] as Map<String, dynamic>?,
      );

  bool get isTerminal => status == 'completed' || status == 'failed';

  /// One-line title for use in the channel list. First sentence of the
  /// description, capped at ~50 chars, with `…` if truncated.
  String get channelTitle {
    final firstLine = description.split(RegExp(r'[\n.]')).first.trim();
    final t = firstLine.isEmpty ? description.trim() : firstLine;
    if (t.length <= 50) return t;
    return '${t.substring(0, 50)}…';
  }
}

class TallyOrchClient {
  final Uri baseUrl;
  final String token;
  final http.Client _http;

  TallyOrchClient({required this.baseUrl, this.token = '', http.Client? client})
      : _http = client ?? http.Client();

  Map<String, String> get _authHeaders =>
      token.isEmpty ? const {} : {'authorization': 'Bearer $token'};

  Future<List<Task>> listTasks({int limit = 100}) async {
    final resp = await _http.get(baseUrl.resolve('/tasks?limit=$limit'), headers: _authHeaders);
    _checkAuth(resp);
    if (resp.statusCode != 200) {
      throw Exception('list tasks failed: ${resp.statusCode} ${resp.body}');
    }
    final List<dynamic> raw = jsonDecode(resp.body);
    return raw.map((e) => Task.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Task> getTask(String id) async {
    final resp = await _http.get(baseUrl.resolve('/tasks/$id'), headers: _authHeaders);
    _checkAuth(resp);
    if (resp.statusCode != 200) {
      throw Exception('get task failed: ${resp.statusCode} ${resp.body}');
    }
    return Task.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<Task> submitTask(String description, {Map<String, dynamic>? teamSpec}) async {
    final resp = await _http.post(
      baseUrl.resolve('/tasks'),
      headers: {'content-type': 'application/json', ..._authHeaders},
      body: jsonEncode({
        'description': description,
        if (teamSpec != null) 'team_spec': teamSpec,
      }),
    );
    _checkAuth(resp);
    if (resp.statusCode != 200) {
      throw Exception('submit task failed: ${resp.statusCode} ${resp.body}');
    }
    return Task.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  /// Sprint 29: promote a completed task's team_spec to a named template.
  /// Sprint 30: alternatively pass a hand-built team_spec straight from
  /// the visual builder. Exactly one of [sourceTaskId] or [teamSpec]
  /// must be provided.
  Future<Map<String, dynamic>> saveTemplate({
    required String name,
    String? sourceTaskId,
    Map<String, dynamic>? teamSpec,
    String? note,
  }) async {
    assert((sourceTaskId == null) ^ (teamSpec == null),
        'pass exactly one of sourceTaskId or teamSpec');
    final resp = await _http.post(
      baseUrl.resolve('/templates'),
      headers: {'content-type': 'application/json', ..._authHeaders},
      body: jsonEncode({
        'name': name,
        if (sourceTaskId != null) 'source_task_id': sourceTaskId,
        if (teamSpec != null) 'team_spec': teamSpec,
        if (note != null && note.isNotEmpty) 'note': note,
      }),
    );
    _checkAuth(resp);
    if (resp.statusCode == 409) {
      throw Exception('template `$name` already exists');
    }
    if (resp.statusCode != 200) {
      throw Exception('save template failed: ${resp.statusCode} ${resp.body}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// Sprint 30: agent role palette for the visual team builder. Returns
  /// the orchestrator's `agent_roles` table — name + description +
  /// default_model + tools (list) + system_prompt. The builder uses
  /// `name` for the dropdown and `default_model` to pre-fill new
  /// agents.
  Future<List<Map<String, dynamic>>> listAgentRoles() async {
    final resp = await _http.get(
      baseUrl.resolve('/admin/agent_roles'),
      headers: _authHeaders,
    );
    _checkAuth(resp);
    if (resp.statusCode != 200) {
      throw Exception('list agent roles failed: ${resp.statusCode} ${resp.body}');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['roles'] as List).cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> listTemplates() async {
    final resp = await _http.get(baseUrl.resolve('/templates'), headers: _authHeaders);
    _checkAuth(resp);
    if (resp.statusCode != 200) {
      throw Exception('list templates failed: ${resp.statusCode} ${resp.body}');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['templates'] as List).cast<Map<String, dynamic>>();
  }

  Future<void> deleteTemplate(String name) async {
    final resp = await _http.delete(
      baseUrl.resolve('/templates/$name'),
      headers: _authHeaders,
    );
    _checkAuth(resp);
    if (resp.statusCode != 200) {
      throw Exception('delete template failed: ${resp.statusCode} ${resp.body}');
    }
  }

  void _checkAuth(http.Response resp) {
    if (resp.statusCode == 401) {
      throw const UnauthorizedException();
    }
  }

  /// One-shot fetch of events with seq > sinceSeq. Used as a fallback when SSE
  /// is unavailable; live clients should prefer [streamFrames].
  Future<List<Map<String, dynamic>>> listEvents(String taskId, {int sinceSeq = -1}) async {
    final resp = await _http.get(baseUrl.resolve('/tasks/$taskId/events?since_seq=$sinceSeq'), headers: _authHeaders);
    _checkAuth(resp);
    if (resp.statusCode != 200) {
      throw Exception('list events failed: ${resp.statusCode} ${resp.body}');
    }
    final List<dynamic> raw = jsonDecode(resp.body);
    return raw.cast<Map<String, dynamic>>();
  }

  /// Server-Sent Events stream of frames (task_event + status_change). Each
  /// yielded record is `(name, data)` so the consumer can route by event name.
  Stream<({String name, Map<String, dynamic> data})> streamFrames(String taskId, {int sinceSeq = -1}) async* {
    final req = http.Request('GET', baseUrl.resolve('/tasks/$taskId/stream?since_seq=$sinceSeq'))
      ..headers['accept'] = 'text/event-stream'
      ..headers['cache-control'] = 'no-cache'
      ..headers.addAll(_authHeaders);
    final resp = await _http.send(req);
    if (resp.statusCode == 401) {
      throw const UnauthorizedException();
    }
    if (resp.statusCode != 200) {
      throw Exception('stream connect failed: ${resp.statusCode}');
    }
    String buffer = '';
    String? currentEventName;
    final dataLines = <String>[];

    await for (final chunk in resp.stream.transform(utf8.decoder)) {
      buffer += chunk;
      while (true) {
        final nl = buffer.indexOf('\n');
        if (nl < 0) break;
        var line = buffer.substring(0, nl);
        buffer = buffer.substring(nl + 1);
        if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
        if (line.isEmpty) {
          // End of one SSE message. Emit any frame with a name + data.
          if (currentEventName != null && dataLines.isNotEmpty) {
            final data = dataLines.join('\n');
            try {
              yield (name: currentEventName, data: jsonDecode(data) as Map<String, dynamic>);
            } catch (_) {
              // Malformed; skip.
            }
          }
          currentEventName = null;
          dataLines.clear();
        } else if (line.startsWith(':')) {
          // Comment / keepalive — ignore.
        } else if (line.startsWith('event:')) {
          currentEventName = line.substring(6).trimLeft();
        } else if (line.startsWith('data:')) {
          dataLines.add(line.substring(5).trimLeft());
        }
      }
    }
  }

  /// Workspace file listing for a completed (or running) task. Returns
  /// {"entries": [{"path", "size", "is_dir"}, ...]}.
  Future<List<Map<String, dynamic>>> listFiles(String taskId) async {
    final resp = await _http.get(baseUrl.resolve('/tasks/$taskId/files'), headers: _authHeaders);
    _checkAuth(resp);
    if (resp.statusCode != 200) {
      throw Exception('list files failed: ${resp.statusCode} ${resp.body}');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['entries'] as List).cast<Map<String, dynamic>>();
  }

  /// Read a single file from a task's workspace. Returns the decoded body
  /// (server delivers base64; we decode to UTF-8 string here for the viewer).
  Future<({String content, int size, bool truncated})> readFile(String taskId, String path) async {
    final resp = await _http.get(baseUrl.resolve('/tasks/$taskId/files/$path'), headers: _authHeaders);
    _checkAuth(resp);
    if (resp.statusCode != 200) {
      throw Exception('read file failed: ${resp.statusCode} ${resp.body}');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final bytes = base64.decode(body['content_b64'] as String);
    final text = utf8.decode(bytes, allowMalformed: true);
    return (
      content: text,
      size: (body['size'] as num).toInt(),
      truncated: body['truncated'] as bool? ?? false,
    );
  }

  void close() => _http.close();
}
