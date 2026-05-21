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
  /// Sprint 37: persistent-project id (null on one-off tasks).
  final String? projectId;
  /// Sprint 41: parent task id (null when this task isn't branched
  /// off a previous one).  Surfaced as a "branched from <task>" pill.
  final String? parentTaskId;
  /// Sprint 41: ids of direct children (tasks branched off this one).
  final List<String> childTaskIds;

  Task({
    required this.id,
    required this.description,
    required this.status,
    this.result,
    this.error,
    required this.createdAt,
    required this.updatedAt,
    this.teamSpec,
    this.projectId,
    this.parentTaskId,
    this.childTaskIds = const [],
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
        projectId: j['project_id'] as String?,
        parentTaskId: j['parent_task_id'] as String?,
        childTaskIds: ((j['child_task_ids'] as List?) ?? const []).cast<String>(),
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

/// Bearer-token provider — either a static admin token (`() async => "TL_…"`)
/// or a Clerk session that mints fresh JWTs on demand.  api.dart fetches
/// the token immediately before each HTTP call so short-lived Clerk
/// session JWTs (60s lifetime) never expire mid-request.
typedef BearerProvider = Future<String?> Function();

class TallyOrchClient {
  final Uri baseUrl;
  final BearerProvider _provider;
  final http.Client _http;

  TallyOrchClient({
    required this.baseUrl,
    required BearerProvider provider,
    http.Client? client,
  })  : _provider = provider,
        _http = client ?? http.Client();

  /// Backwards-compat factory for the legacy static-token path
  /// (admin token from the .env / pre-Sprint-32.5 paste flow).
  factory TallyOrchClient.fromToken({
    required Uri baseUrl,
    required String token,
    http.Client? client,
  }) {
    return TallyOrchClient(
      baseUrl: baseUrl,
      provider: () async => token,
      client: client,
    );
  }

  Future<Map<String, String>> get _authHeaders async {
    final token = await _provider();
    if (token == null || token.isEmpty) return const {};
    return {'authorization': 'Bearer $token'};
  }

  Future<List<Task>> listTasks({int limit = 100}) async {
    final resp = await _http.get(baseUrl.resolve('/tasks?limit=$limit'), headers: await _authHeaders);
    _checkAuth(resp);
    if (resp.statusCode != 200) {
      throw Exception('list tasks failed: ${resp.statusCode} ${resp.body}');
    }
    final List<dynamic> raw = jsonDecode(resp.body);
    return raw.map((e) => Task.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Task> getTask(String id) async {
    final resp = await _http.get(baseUrl.resolve('/tasks/$id'), headers: await _authHeaders);
    _checkAuth(resp);
    if (resp.statusCode != 200) {
      throw Exception('get task failed: ${resp.statusCode} ${resp.body}');
    }
    return Task.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<Task> submitTask(
    String description, {
    Map<String, dynamic>? teamSpec,
    String? projectId,
    String? parentTaskId,
  }) async {
    final resp = await _http.post(
      baseUrl.resolve('/tasks'),
      headers: {'content-type': 'application/json', ...(await _authHeaders)},
      body: jsonEncode({
        'description': description,
        if (teamSpec != null) 'team_spec': teamSpec,
        if (projectId != null) 'project_id': projectId,
        if (parentTaskId != null) 'parent_task_id': parentTaskId,
      }),
    );
    _checkAuth(resp);
    if (resp.statusCode != 200) {
      throw Exception('submit task failed: ${resp.statusCode} ${resp.body}');
    }
    return Task.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  // ── Sprint 37: persistent projects ────────────────────────────────────────

  Future<List<Map<String, dynamic>>> listProjects() async {
    final resp = await _http.get(
      baseUrl.resolve('/projects'),
      headers: await _authHeaders,
    );
    _checkAuth(resp);
    if (resp.statusCode != 200) {
      throw Exception('list projects failed: ${resp.statusCode} ${resp.body}');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['projects'] as List).cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> getProject(String id) async {
    final resp = await _http.get(
      baseUrl.resolve('/projects/$id'),
      headers: await _authHeaders,
    );
    _checkAuth(resp);
    if (resp.statusCode != 200) {
      throw Exception('get project failed: ${resp.statusCode} ${resp.body}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> createProject({
    required String name,
    String? description,
  }) async {
    final resp = await _http.post(
      baseUrl.resolve('/projects'),
      headers: {'content-type': 'application/json', ...(await _authHeaders)},
      body: jsonEncode({
        'name': name,
        if (description != null) 'description': description,
      }),
    );
    _checkAuth(resp);
    if (resp.statusCode != 200) {
      throw Exception('create project failed: ${resp.statusCode} ${resp.body}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> patchProject(
    String id, {
    String? name,
    String? description,
  }) async {
    final body = <String, dynamic>{};
    if (name != null) body['name'] = name;
    if (description != null) body['description'] = description;
    final resp = await _http.patch(
      baseUrl.resolve('/projects/$id'),
      headers: {'content-type': 'application/json', ...(await _authHeaders)},
      body: jsonEncode(body),
    );
    _checkAuth(resp);
    if (resp.statusCode != 200) {
      throw Exception('patch project failed: ${resp.statusCode} ${resp.body}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<void> deleteProject(String id) async {
    final resp = await _http.delete(
      baseUrl.resolve('/projects/$id'),
      headers: await _authHeaders,
    );
    _checkAuth(resp);
    if (resp.statusCode != 200) {
      throw Exception('delete project failed: ${resp.statusCode} ${resp.body}');
    }
  }

  // ── Sprint 40: custom user-defined agent roles ───────────────────────────

  Future<Map<String, dynamic>> createCustomRole({
    required String name,
    required String description,
    required String defaultModel,
    required List<String> tools,
    required String systemPrompt,
  }) async {
    final resp = await _http.post(
      baseUrl.resolve('/agent_roles'),
      headers: {'content-type': 'application/json', ...(await _authHeaders)},
      body: jsonEncode({
        'name': name,
        'description': description,
        'default_model': defaultModel,
        'tools': tools,
        'system_prompt': systemPrompt,
      }),
    );
    _checkAuth(resp);
    if (resp.statusCode == 409) {
      throw Exception('role name conflicts with a seeded role or your existing custom role');
    }
    if (resp.statusCode != 200) {
      throw Exception('create custom role failed: ${resp.statusCode} ${resp.body}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> patchCustomRole(
    String name, {
    String? description,
    String? defaultModel,
    List<String>? tools,
    String? systemPrompt,
  }) async {
    final body = <String, dynamic>{};
    if (description != null) body['description'] = description;
    if (defaultModel != null) body['default_model'] = defaultModel;
    if (tools != null) body['tools'] = tools;
    if (systemPrompt != null) body['system_prompt'] = systemPrompt;
    final resp = await _http.patch(
      baseUrl.resolve('/agent_roles/$name'),
      headers: {'content-type': 'application/json', ...(await _authHeaders)},
      body: jsonEncode(body),
    );
    _checkAuth(resp);
    if (resp.statusCode != 200) {
      throw Exception('patch role failed: ${resp.statusCode} ${resp.body}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<void> deleteCustomRole(String name) async {
    final resp = await _http.delete(
      baseUrl.resolve('/agent_roles/$name'),
      headers: await _authHeaders,
    );
    _checkAuth(resp);
    if (resp.statusCode != 200 && resp.statusCode != 404) {
      throw Exception('delete role failed: ${resp.statusCode} ${resp.body}');
    }
  }

  // ── Sprint 38: GitHub PAT + push ─────────────────────────────────────────

  /// Returns `{has_token: bool}`.  Never returns the token itself.
  Future<bool> hasGithubToken() async {
    final resp = await _http.get(
      baseUrl.resolve('/github/token'),
      headers: await _authHeaders,
    );
    _checkAuth(resp);
    if (resp.statusCode != 200) {
      throw Exception('github token status failed: ${resp.statusCode} ${resp.body}');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return body['has_token'] as bool? ?? false;
  }

  /// Sprint 38.5: which credential sources can push for the caller?
  /// Returns `{clerk_oauth_available, clerk_oauth_scopes, pat_stored}`.
  /// Drives the "GitHub auto-connected" UX.
  Future<Map<String, dynamic>> githubConnectionStatus() async {
    final resp = await _http.get(
      baseUrl.resolve('/github/connection-status'),
      headers: await _authHeaders,
    );
    _checkAuth(resp);
    if (resp.statusCode != 200) {
      throw Exception('github connection-status failed: ${resp.statusCode} ${resp.body}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<void> setGithubToken(String pat) async {
    final resp = await _http.post(
      baseUrl.resolve('/github/token'),
      headers: {'content-type': 'application/json', ...(await _authHeaders)},
      body: jsonEncode({'pat': pat}),
    );
    _checkAuth(resp);
    if (resp.statusCode != 200) {
      throw Exception('store github token failed: ${resp.statusCode} ${resp.body}');
    }
  }

  Future<void> deleteGithubToken() async {
    final resp = await _http.delete(
      baseUrl.resolve('/github/token'),
      headers: await _authHeaders,
    );
    _checkAuth(resp);
    if (resp.statusCode != 200 && resp.statusCode != 404) {
      throw Exception('delete github token failed: ${resp.statusCode} ${resp.body}');
    }
  }

  /// Push a project's HEAD to a GitHub repo as a new branch.  The
  /// stored PAT is used server-side; this method never sees it.
  /// Returns the push result with branch_url.
  Future<Map<String, dynamic>> pushProjectToGithub(
    String projectId, {
    required String repo,
    String? branch,
    String? commitMessage,
  }) async {
    final body = <String, dynamic>{'repo': repo};
    if (branch != null && branch.isNotEmpty) body['branch'] = branch;
    if (commitMessage != null && commitMessage.isNotEmpty) {
      body['commit_message'] = commitMessage;
    }
    final resp = await _http.post(
      baseUrl.resolve('/projects/$projectId/push'),
      headers: {'content-type': 'application/json', ...(await _authHeaders)},
      body: jsonEncode(body),
    );
    _checkAuth(resp);
    if (resp.statusCode != 200) {
      throw Exception('push project failed: ${resp.statusCode} ${resp.body}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
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
      headers: {'content-type': 'application/json', ...(await _authHeaders)},
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
      headers: await _authHeaders,
    );
    _checkAuth(resp);
    if (resp.statusCode != 200) {
      throw Exception('list agent roles failed: ${resp.statusCode} ${resp.body}');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['roles'] as List).cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> listTemplates() async {
    final resp = await _http.get(baseUrl.resolve('/templates'), headers: await _authHeaders);
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
      headers: await _authHeaders,
    );
    _checkAuth(resp);
    if (resp.statusCode != 200) {
      throw Exception('delete template failed: ${resp.statusCode} ${resp.body}');
    }
  }

  /// Sprint 34: rename / edit / replace a template in place.  All
  /// fields optional; pass only what changes.  409 on name collision.
  Future<Map<String, dynamic>> patchTemplate(
    String name, {
    String? newName,
    Map<String, dynamic>? teamSpec,
    String? note,
  }) async {
    final body = <String, dynamic>{};
    if (newName != null) body['new_name'] = newName;
    if (teamSpec != null) body['team_spec'] = teamSpec;
    if (note != null) body['note'] = note;
    final resp = await _http.patch(
      baseUrl.resolve('/templates/$name'),
      headers: {'content-type': 'application/json', ...(await _authHeaders)},
      body: jsonEncode(body),
    );
    _checkAuth(resp);
    if (resp.statusCode == 409) {
      throw Exception('a template named `$newName` already exists');
    }
    if (resp.statusCode != 200) {
      throw Exception('patch template failed: ${resp.statusCode} ${resp.body}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// Sprint 34: mint or return the existing share token for a template.
  /// The returned URL is anonymous-readable; rotate via [revokeShareToken].
  Future<String> shareTemplate(String name) async {
    final resp = await _http.post(
      baseUrl.resolve('/templates/$name/share'),
      headers: await _authHeaders,
    );
    _checkAuth(resp);
    if (resp.statusCode != 200) {
      throw Exception('share template failed: ${resp.statusCode} ${resp.body}');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return baseUrl.resolve(body['share_path'] as String).toString();
  }

  Future<void> revokeShareToken(String name) async {
    final resp = await _http.delete(
      baseUrl.resolve('/templates/$name/share'),
      headers: await _authHeaders,
    );
    _checkAuth(resp);
    if (resp.statusCode != 200 && resp.statusCode != 404) {
      throw Exception('revoke share failed: ${resp.statusCode} ${resp.body}');
    }
  }

  /// Sprint 35: poll /health to learn whether the worker pool is ready.
  /// Returns a flat snapshot: pool_ready, pool_target, pool_joined,
  /// pool_last_error.  Doesn't require auth (the orchestrator's /health
  /// is public).
  Future<Map<String, dynamic>> health() async {
    final resp = await _http.get(baseUrl.resolve('/health'));
    if (resp.statusCode != 200) {
      throw Exception('health failed: ${resp.statusCode} ${resp.body}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  void _checkAuth(http.Response resp) {
    if (resp.statusCode == 401) {
      throw const UnauthorizedException();
    }
  }

  /// One-shot fetch of events with seq > sinceSeq. Used as a fallback when SSE
  /// is unavailable; live clients should prefer [streamFrames].
  Future<List<Map<String, dynamic>>> listEvents(String taskId, {int sinceSeq = -1}) async {
    final resp = await _http.get(baseUrl.resolve('/tasks/$taskId/events?since_seq=$sinceSeq'), headers: await _authHeaders);
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
      ..headers.addAll((await _authHeaders));
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

  /// Sprint 39: LLM cost roll-up for the calling user's current period.
  /// Returns `{since_ts, total_micro_usd, total_tokens, by_kind, by_model}`.
  Future<Map<String, dynamic>> billingCost() async {
    final resp = await _http.get(
      baseUrl.resolve('/billing/cost'),
      headers: await _authHeaders,
    );
    _checkAuth(resp);
    if (resp.statusCode != 200) {
      throw Exception('billing cost failed: ${resp.statusCode} ${resp.body}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// Sprint 33-rest: usage + plan summary for the calling user.  Drives
  /// the in-app billing screen.  Returns:
  ///   {
  ///     "user_id": "...",
  ///     "plan": "free" | "pro" | "team" | "unlimited",
  ///     "plan_label": "Free",
  ///     "period_start": <unix ts>,
  ///     "tasks": {"used": int, "cap": int},
  ///     "agent_seconds": {"used": int, "cap": int},
  ///     "billing_payer_id": "..." | null,
  ///     "billing_subscription_id": "..." | null,
  ///   }
  Future<Map<String, dynamic>> billingUsage() async {
    final resp = await _http.get(
      baseUrl.resolve('/billing/usage'),
      headers: await _authHeaders,
    );
    _checkAuth(resp);
    if (resp.statusCode != 200) {
      throw Exception('billing usage failed: ${resp.statusCode} ${resp.body}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// Workspace file listing for a completed (or running) task. Returns
  /// {"entries": [{"path", "size", "is_dir"}, ...]}.
  Future<List<Map<String, dynamic>>> listFiles(String taskId) async {
    final resp = await _http.get(baseUrl.resolve('/tasks/$taskId/files'), headers: await _authHeaders);
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
    final resp = await _http.get(baseUrl.resolve('/tasks/$taskId/files/$path'), headers: await _authHeaders);
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

  // ── Sprint 46: credit-based billing ─────────────────────────────────────

  Future<Map<String, dynamic>> getCreditsBalance() async {
    final resp = await _http.get(
      baseUrl.resolve('/billing/credits'),
      headers: await _authHeaders,
    );
    if (resp.statusCode != 200) {
      throw Exception('GET /billing/credits ${resp.statusCode}: ${resp.body}');
    }
    return Map<String, dynamic>.from(jsonDecode(resp.body));
  }

  Future<Map<String, dynamic>> getCaps() async {
    final resp = await _http.get(
      baseUrl.resolve('/billing/caps'),
      headers: await _authHeaders,
    );
    if (resp.statusCode != 200) {
      throw Exception('GET /billing/caps ${resp.statusCode}: ${resp.body}');
    }
    return Map<String, dynamic>.from(jsonDecode(resp.body));
  }

  Future<Map<String, dynamic>> patchCaps({
    int? perTaskCapCredits,
    int? dailySpendCapCredits,
    int? weeklySpendCapCredits,
  }) async {
    final body = <String, dynamic>{};
    if (perTaskCapCredits != null) body['per_task_cap_credits'] = perTaskCapCredits;
    if (dailySpendCapCredits != null) body['daily_spend_cap_credits'] = dailySpendCapCredits;
    if (weeklySpendCapCredits != null) body['weekly_spend_cap_credits'] = weeklySpendCapCredits;
    final resp = await _http.patch(
      baseUrl.resolve('/billing/caps'),
      headers: {'content-type': 'application/json', ...(await _authHeaders)},
      body: jsonEncode(body),
    );
    if (resp.statusCode != 200) {
      throw Exception('PATCH /billing/caps ${resp.statusCode}: ${resp.body}');
    }
    return Map<String, dynamic>.from(jsonDecode(resp.body));
  }

  Future<Map<String, dynamic>> postCreditsCheckout({
    required int credits,
    String successUrl = 'tallycoding://billing/success',
    String cancelUrl = 'tallycoding://billing/cancel',
  }) async {
    final resp = await _http.post(
      baseUrl.resolve('/billing/credits/checkout'),
      headers: {'content-type': 'application/json', ...(await _authHeaders)},
      body: jsonEncode({
        'credits': credits,
        'success_url': successUrl,
        'cancel_url': cancelUrl,
      }),
    );
    if (resp.statusCode != 200) {
      throw Exception('POST /billing/credits/checkout ${resp.statusCode}: ${resp.body}');
    }
    return Map<String, dynamic>.from(jsonDecode(resp.body));
  }

  Future<Map<String, dynamic>> postAutoRechargeSetup({
    String successUrl = 'tallycoding://billing/auto-recharge/success',
    String cancelUrl = 'tallycoding://billing/auto-recharge/cancel',
  }) async {
    final resp = await _http.post(
      baseUrl.resolve('/billing/auto-recharge/setup'),
      headers: {'content-type': 'application/json', ...(await _authHeaders)},
      body: jsonEncode({'success_url': successUrl, 'cancel_url': cancelUrl}),
    );
    if (resp.statusCode != 200) {
      throw Exception('POST /billing/auto-recharge/setup ${resp.statusCode}: ${resp.body}');
    }
    return Map<String, dynamic>.from(jsonDecode(resp.body));
  }

  Future<Map<String, dynamic>> patchAutoRecharge({
    int? mode,
    int? blockCredits,
    int? monthlyCapMicroUsd,
  }) async {
    final body = <String, dynamic>{};
    if (mode != null) body['mode'] = mode;
    if (blockCredits != null) body['block_credits'] = blockCredits;
    if (monthlyCapMicroUsd != null) body['monthly_cap_micro_usd'] = monthlyCapMicroUsd;
    final resp = await _http.patch(
      baseUrl.resolve('/billing/auto-recharge'),
      headers: {'content-type': 'application/json', ...(await _authHeaders)},
      body: jsonEncode(body),
    );
    if (resp.statusCode != 200) {
      throw Exception('PATCH /billing/auto-recharge ${resp.statusCode}: ${resp.body}');
    }
    return Map<String, dynamic>.from(jsonDecode(resp.body));
  }

  Future<List<Map<String, dynamic>>> listNotifications({int limit = 50, int? sinceId}) async {
    final qs = <String, String>{'limit': '$limit'};
    if (sinceId != null) qs['since_id'] = '$sinceId';
    final resp = await _http.get(
      baseUrl.resolve('/notifications').replace(queryParameters: qs),
      headers: await _authHeaders,
    );
    if (resp.statusCode != 200) {
      throw Exception('GET /notifications ${resp.statusCode}: ${resp.body}');
    }
    final body = Map<String, dynamic>.from(jsonDecode(resp.body));
    return List<Map<String, dynamic>>.from(body['notifications'] as List);
  }

  Future<void> dismissNotification(int notificationId) async {
    final resp = await _http.post(
      baseUrl.resolve('/notifications/$notificationId/dismiss'),
      headers: await _authHeaders,
    );
    if (resp.statusCode != 200) {
      throw Exception('POST /notifications/$notificationId/dismiss ${resp.statusCode}');
    }
  }

  Future<List<Map<String, dynamic>>> listNotificationRules() async {
    final resp = await _http.get(
      baseUrl.resolve('/notification_rules'),
      headers: await _authHeaders,
    );
    if (resp.statusCode != 200) {
      throw Exception('GET /notification_rules ${resp.statusCode}: ${resp.body}');
    }
    final body = Map<String, dynamic>.from(jsonDecode(resp.body));
    return List<Map<String, dynamic>>.from(body['rules'] as List);
  }

  Future<Map<String, dynamic>> createNotificationRule({
    required String kind,
    required int threshold,
    bool enabled = true,
  }) async {
    final resp = await _http.post(
      baseUrl.resolve('/notification_rules'),
      headers: {'content-type': 'application/json', ...(await _authHeaders)},
      body: jsonEncode({'kind': kind, 'threshold': threshold, 'enabled': enabled}),
    );
    if (resp.statusCode != 200) {
      throw Exception('POST /notification_rules ${resp.statusCode}: ${resp.body}');
    }
    return Map<String, dynamic>.from(jsonDecode(resp.body));
  }

  Future<Map<String, dynamic>> patchNotificationRule(
    int ruleId, {
    int? threshold,
    bool? enabled,
  }) async {
    final body = <String, dynamic>{};
    if (threshold != null) body['threshold'] = threshold;
    if (enabled != null) body['enabled'] = enabled;
    final resp = await _http.patch(
      baseUrl.resolve('/notification_rules/$ruleId'),
      headers: {'content-type': 'application/json', ...(await _authHeaders)},
      body: jsonEncode(body),
    );
    if (resp.statusCode != 200) {
      throw Exception('PATCH /notification_rules ${resp.statusCode}: ${resp.body}');
    }
    return Map<String, dynamic>.from(jsonDecode(resp.body));
  }

  Future<void> deleteNotificationRule(int ruleId) async {
    final resp = await _http.delete(
      baseUrl.resolve('/notification_rules/$ruleId'),
      headers: await _authHeaders,
    );
    if (resp.statusCode != 200) {
      throw Exception('DELETE /notification_rules/$ruleId ${resp.statusCode}');
    }
  }

  Future<List<Map<String, dynamic>>> listPushDevices() async {
    final resp = await _http.get(
      baseUrl.resolve('/push/devices'),
      headers: await _authHeaders,
    );
    if (resp.statusCode != 200) {
      throw Exception('GET /push/devices ${resp.statusCode}: ${resp.body}');
    }
    final body = Map<String, dynamic>.from(jsonDecode(resp.body));
    return List<Map<String, dynamic>>.from(body['devices'] as List);
  }

  Future<Map<String, dynamic>> registerPushDevice({
    required String provider,
    String? endpointUrl,
    String? label,
    String? platform,
  }) async {
    final resp = await _http.post(
      baseUrl.resolve('/push/devices'),
      headers: {'content-type': 'application/json', ...(await _authHeaders)},
      body: jsonEncode({
        'provider': provider,
        if (endpointUrl != null) 'endpoint_url': endpointUrl,
        if (label != null) 'label': label,
        if (platform != null) 'platform': platform,
      }),
    );
    if (resp.statusCode != 200) {
      throw Exception('POST /push/devices ${resp.statusCode}: ${resp.body}');
    }
    return Map<String, dynamic>.from(jsonDecode(resp.body));
  }

  Future<void> deletePushDevice(int deviceId) async {
    final resp = await _http.delete(
      baseUrl.resolve('/push/devices/$deviceId'),
      headers: await _authHeaders,
    );
    if (resp.statusCode != 200) {
      throw Exception('DELETE /push/devices/$deviceId ${resp.statusCode}');
    }
  }

  Future<Map<String, dynamic>> getTaskCost(String taskId) async {
    final resp = await _http.get(
      baseUrl.resolve('/tasks/$taskId/cost'),
      headers: await _authHeaders,
    );
    if (resp.statusCode != 200) {
      throw Exception('GET /tasks/$taskId/cost ${resp.statusCode}');
    }
    return Map<String, dynamic>.from(jsonDecode(resp.body));
  }

  // ── Sprint 47: channels + messages ──────────────────────────────────────

  Future<List<Map<String, dynamic>>> listChannels({
    required int workspaceId,
    bool includeArchived = false,
  }) async {
    final qs = {'workspace_id': '$workspaceId'};
    if (includeArchived) qs['include_archived'] = 'true';
    final resp = await _http.get(
      baseUrl.resolve('/channels').replace(queryParameters: qs),
      headers: await _authHeaders,
    );
    if (resp.statusCode != 200) {
      throw Exception('GET /channels ${resp.statusCode}: ${resp.body}');
    }
    final body = Map<String, dynamic>.from(jsonDecode(resp.body));
    return List<Map<String, dynamic>>.from(body['channels'] as List);
  }

  Future<List<Map<String, dynamic>>> getMessages({
    required int channelId,
    int limit = 50,
    int? sinceId,
  }) async {
    final qs = <String, String>{'limit': '$limit'};
    if (sinceId != null) qs['since_id'] = '$sinceId';
    final resp = await _http.get(
      baseUrl.resolve('/channels/$channelId/messages').replace(queryParameters: qs),
      headers: await _authHeaders,
    );
    if (resp.statusCode != 200) {
      throw Exception('GET /channels/$channelId/messages ${resp.statusCode}: ${resp.body}');
    }
    final body = Map<String, dynamic>.from(jsonDecode(resp.body));
    return List<Map<String, dynamic>>.from(body['messages'] as List);
  }

  Future<Map<String, dynamic>> postMessage({
    required int channelId,
    String? text,
    String kind = 'text',
    Map<String, dynamic>? payload,
    int? replyToId,
  }) async {
    final body = <String, dynamic>{'kind': kind};
    if (text != null) body['text'] = text;
    if (payload != null) body['payload'] = payload;
    if (replyToId != null) body['reply_to_id'] = replyToId;
    final resp = await _http.post(
      baseUrl.resolve('/channels/$channelId/messages'),
      headers: {'content-type': 'application/json', ...(await _authHeaders)},
      body: jsonEncode(body),
    );
    if (resp.statusCode != 200) {
      throw Exception('POST /channels/$channelId/messages ${resp.statusCode}: ${resp.body}');
    }
    return Map<String, dynamic>.from(jsonDecode(resp.body));
  }

  Future<Map<String, dynamic>> patchMessage(
    int channelId,
    int messageId, {
    String? text,
    Map<String, dynamic>? payload,
  }) async {
    final body = <String, dynamic>{};
    if (text != null) body['text'] = text;
    if (payload != null) body['payload'] = payload;
    final resp = await _http.patch(
      baseUrl.resolve('/channels/$channelId/messages/$messageId'),
      headers: {'content-type': 'application/json', ...(await _authHeaders)},
      body: jsonEncode(body),
    );
    if (resp.statusCode != 200) {
      throw Exception('PATCH /channels/$channelId/messages/$messageId ${resp.statusCode}: ${resp.body}');
    }
    return Map<String, dynamic>.from(jsonDecode(resp.body));
  }

  Future<void> postChannelRead({
    required int channelId,
    required int lastReadMessageId,
  }) async {
    final resp = await _http.post(
      baseUrl.resolve('/channels/$channelId/read'),
      headers: {'content-type': 'application/json', ...(await _authHeaders)},
      body: jsonEncode({'last_read_message_id': lastReadMessageId}),
    );
    if (resp.statusCode != 200) {
      throw Exception('POST /channels/$channelId/read ${resp.statusCode}');
    }
  }

  Future<void> setChannelMemberRoleOverride({
    required int channelId,
    required String targetUserId,
    String? roleOverride,
  }) async {
    final resp = await _http.post(
      baseUrl.resolve('/channels/$channelId/members/$targetUserId/role_override'),
      headers: {'content-type': 'application/json', ...(await _authHeaders)},
      body: jsonEncode({'role_override': roleOverride}),
    );
    if (resp.statusCode != 200) {
      throw Exception('POST role_override ${resp.statusCode}: ${resp.body}');
    }
  }

  void close() => _http.close();
}
