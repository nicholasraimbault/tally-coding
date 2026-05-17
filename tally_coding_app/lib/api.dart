import 'dart:convert';

import 'package:http/http.dart' as http;

class Task {
  final String id;
  final String description;
  final String status;
  final Map<String, dynamic>? result;
  final String? error;
  final double createdAt;
  final double updatedAt;

  Task({
    required this.id,
    required this.description,
    required this.status,
    this.result,
    this.error,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Task.fromJson(Map<String, dynamic> j) => Task(
        id: j['id'] as String,
        description: j['description'] as String,
        status: j['status'] as String,
        result: j['result'] as Map<String, dynamic>?,
        error: j['error'] as String?,
        createdAt: (j['created_at'] as num).toDouble(),
        updatedAt: (j['updated_at'] as num).toDouble(),
      );

  bool get isTerminal => status == 'completed' || status == 'failed';
}

class TallyOrchClient {
  final Uri baseUrl;
  final http.Client _http;

  TallyOrchClient({required this.baseUrl, http.Client? client})
      : _http = client ?? http.Client();

  Future<List<Task>> listTasks({int limit = 100}) async {
    final resp = await _http.get(baseUrl.resolve('/tasks?limit=$limit'));
    if (resp.statusCode != 200) {
      throw Exception('list tasks failed: ${resp.statusCode} ${resp.body}');
    }
    final List<dynamic> raw = jsonDecode(resp.body);
    return raw.map((e) => Task.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Task> getTask(String id) async {
    final resp = await _http.get(baseUrl.resolve('/tasks/$id'));
    if (resp.statusCode != 200) {
      throw Exception('get task failed: ${resp.statusCode} ${resp.body}');
    }
    return Task.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<Task> submitTask(String description) async {
    final resp = await _http.post(
      baseUrl.resolve('/tasks'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'description': description}),
    );
    if (resp.statusCode != 200) {
      throw Exception('submit task failed: ${resp.statusCode} ${resp.body}');
    }
    return Task.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  /// One-shot fetch of events with seq > sinceSeq. Used as a fallback when SSE
  /// is unavailable; live clients should prefer [streamEvents].
  Future<List<Map<String, dynamic>>> listEvents(String taskId, {int sinceSeq = -1}) async {
    final resp = await _http.get(baseUrl.resolve('/tasks/$taskId/events?since_seq=$sinceSeq'));
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
      ..headers['cache-control'] = 'no-cache';
    final resp = await _http.send(req);
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
    final resp = await _http.get(baseUrl.resolve('/tasks/$taskId/files'));
    if (resp.statusCode != 200) {
      throw Exception('list files failed: ${resp.statusCode} ${resp.body}');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['entries'] as List).cast<Map<String, dynamic>>();
  }

  /// Read a single file from a task's workspace. Returns the decoded body
  /// (server delivers base64; we decode to UTF-8 string here for the viewer).
  Future<({String content, int size, bool truncated})> readFile(String taskId, String path) async {
    final resp = await _http.get(baseUrl.resolve('/tasks/$taskId/files/$path'));
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
