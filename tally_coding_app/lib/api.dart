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

  void close() => _http.close();
}
