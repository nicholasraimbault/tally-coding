# Sprint 47 — Chat foundation + permission groundwork

**Status:** Code complete + deployed on `tally.pronoic.dev`
**Dates:** 2026-05-20 (spec) → 2026-05-20 (ship)
**Effort:** 26 commits, 25 files, +2,180 / -577 lines
**Image:** `tally-orch:v27` (deployed to Phala CVM `app_c3b5481b…`)
**Branch:** `feat/sprint-47-chat-foundation`
**Branch tags:** `s47-phase-a-done`, `s47-phase-b-done`, `s47-deployed-v27`

## What shipped

### Workspace data model (5 new tables)

- `workspaces` — owner_user_id, plan_slug, stripe_customer_id, settings_json
- `workspace_members` — workspace_id × (human user_id | agent_id), role (owner / admin / manager / member / tally / agent)
- `channels` — workspace_id, kind (`general` / `backlog` / `task` / `scheduled_agent` / `custom` / `dm`), name, task_id, persistent_agent_id, auto_jump_in_for_tally, archived_at
- `channel_members` — channel_id × member with optional `role_override` (channel_admin / read_only)
- `messages` — channel_id, author_kind (`human` / `agent` / `tally` / `system`), kind (`text` / `interactive_prompt` / `interactive_prompt_response`), payload_json, reply_to_id, edited_at

All tables idempotent (`CREATE TABLE IF NOT EXISTS`), with 9 supporting indexes.

### Backfill

`Db._backfill_workspaces_and_channels()` runs once per `Db.__init__`:

- Every distinct `user_id` in `tasks` / `quotas` gets a workspace + owner `workspace_members` row + auto-created `#general` and `#backlog` channels (with owner `channel_members` rows).
- Every existing `tasks` row gets a `kind='task'` channel + owner `channel_members` row. `archived_at` is set to `task.updated_at` for `completed` / `failed` tasks.
- Production rollout backfilled the admin workspace + 9 existing task channels.

### Permission model (`channels.py`)

- Workspace-wide role (`workspace_members.role`) + per-channel override (`channel_members.role_override`).
- Effective role resolution: override if set → workspace role → `None` (non-member).
- Predicates: `can_post_in_channel(role)`, `can_dispatch_task(role)`, `can_manage_members(role)`.

### REST routes (6 new on the orchestrator)

| Route | Behavior |
|---|---|
| `GET /channels?workspace_id=N&include_archived=bool` | List visible channels. Workspace-isolation guard: returns `[]` if caller isn't a `workspace_members` row. Member-scoped: `general`/`backlog` open to workspace members; others require `channel_members` row. |
| `GET /channels/{id}/messages?limit=N&since_id=N` | Paginated history, newest-first. `limit` clamped `[1, 200]` at route + helper layer (DoS guard); `since_id ≥ 1` validated. 403 for non-members. |
| `POST /channels/{id}/messages` | Role-gated send via `can_post_in_channel`. 404 if channel missing, 403 if non-member/read-only, 400 if `kind=text` and body.text empty. Body.text wins over payload.text (documented in docstring). Fires fire-and-forget WebSocket broadcast (task tracked in module-level set to survive GC). |
| `PATCH /channels/{id}/messages/{message_id}` | Author-only edit. PATCH-semantic payload merge (not replace): caller-supplied keys win, existing keys preserved. `edited_at` set on success. 400 if neither text nor payload provided. |
| `POST /channels/{id}/read` | Sets `channel_members.last_read_message_id = MAX(current, body)` (prevents regression on out-of-order calls). |
| `POST /channels/{id}/members/{user_id}/role_override` | Admin/Owner only. Whitelist: `channel_admin`, `read_only`, or `null` (clears). 404 if target not in channel_members. |

### WebSocket extension

- Existing `/ws/notifications` adds a third event kind alongside Sprint 46's `hello`/`new_notification`:
  ```json
  {"type": "new_message", "channel_id": N, "message_id": N}
  ```
- `_broadcast_new_message(channel_id, message_id)` fires after each successful `POST /messages` and any other message insert; queries `channel_members` once and dispatches the frame to every WebSocket in the existing `_ACTIVE_WS` registry whose user is a member.
- Per-socket exception isolation — one disconnected client doesn't tank the broadcast.

### Orchestrator agent-context inclusion

- `agents.last_user_msg_ts` new column (idempotent ALTER TABLE).
- `Orchestrator._dispatch_agent` calls `fetch_user_messages_since(channel, since=agent.last_user_msg_ts)` immediately before constructing the worker payload. Any new user messages in the task channel are appended to the agent's spec as a `## User intervention (since last step)` block before being sent to the LLM, then `last_user_msg_ts` is bumped via `UPDATE agents SET last_user_msg_ts=?`.
- `Db.list_agents` SELECT extended to include `last_user_msg_ts` so the dispatcher reads it reliably.

### Inline channel creation in `Db.create_task`

- Sprint 47 hooks `Db.create_task` to insert the task's channel + owner `channel_members` row at the same time as the task row (no longer waiting for the next `Db.__init__` backfill cycle). Backfill still runs idempotently on the LEFT-JOIN guard.

### Flutter

- New widgets:
  - `MessageBubble` — author label + color (tally red / agent green / system gray / human blurple), HH:MM time, `(edited)` indicator, `SelectableText` body.
  - `InteractivePromptCard` — yellow-bordered card with the agent's question text + a `Wrap` of action buttons; tap fires `onAnswer(value)`.
  - `MessageFeed` — reverse-chronological `ListView.builder`; dispatches to `MessageBubble` for `kind=text` and `InteractivePromptCard` for `kind=interactive_prompt`; empty state.
  - `MessageComposer` — `TextField` with `TextInputAction.send` (enter-to-submit), busy-state lockout, `SnackBar` on error.
- `TallyOrchClient` extended with `listChannels`, `getMessages`, `postMessage`, `patchMessage` (named args), `postChannelRead`, `setChannelMemberRoleOverride`.
- `NotificationsWsClient` extended with `void Function(int channelId, int messageId)? onNewMessage` field; `_handleMessage` dispatches `new_message` frames to it.
- `task_channel.dart` (~540 lines removed, ~130 added): the old SSE event-stream renderer (`_renderTimeline`, six private widget classes, `_events`/`_lastSeq`/`_scrollCtrl` state) is replaced by a `MessageFeed` + `MessageComposer` body. `_resolveChannelAndLoad` looks up the task's channel via `listChannels(workspaceId: 1)`, `_subscribeToWs` wires `onNewMessage` to a delta refetch via `getMessages(since_id=...)`, `_send` calls `postMessage` then eagerly refreshes. `dispose()` clears the WS callback to prevent leaks. Sprint 46's cost ticker chip + cap-abort dialog stay in the channel header.

### Testing

- Orchestrator: 21 new pytest tests across schema (`test_workspace_schema.py`), permission (`test_permission_middleware.py`), channel routes (`test_channels_routes.py`), message routes (`test_messages_routes.py`), WebSocket broadcast (`test_message_ws.py`), agent context (`test_agent_context_inclusion.py`). Combined with Sprint 46's existing suite: **110 passed in 2.88s**.
- Flutter: 4 new test files covering `MessageBubble`, `InteractivePromptCard`, `MessageFeed`, `MessageComposer`, plus `api_channels_test.dart`. 22/23 widget tests pass (the one failure — `DiscordShellScreen renders the four-column layout` — pre-dates this branch).

### Verification

Live smoke against `tally.pronoic.dev` after the Phala roll:

| Step | Result |
|---|---|
| `GET /health` | 200, `status: ok` |
| `GET /channels?workspace_id=1` | 200, admin workspace surfaced with `#general` + `#backlog` (backfill ran on the live DB) |
| `POST /channels/1/messages` `{"text":"s47 smoke from claude"}` | 200, message id=1 returned with full shape |
| `GET /channels/1/messages` | 200, posted message round-trips |
| `GET /channels?workspace_id=1&include_archived=true` | 200, 9 archived task channels backfilled from the production task history |

## Reviewer-flagged TODOs in code (intentionally deferred)

- **404 vs 403 channel-existence leak.** All channel routes return 404 for missing channels before 403 for non-members. Once private channels (DMs / custom) land in Sprint 49–50, these paths should collapse to 403 to avoid leaking existence. TODO comments inline in `post_message`, `get_messages`.
- **Unsanitized user text in agent spec.** `_dispatch_agent` appends user message text verbatim into the LLM prompt. A malicious user message containing `## SYSTEM` markdown or instructions could attempt prompt injection. Acceptable for v1 (only the workspace's own members can post); revisit when channels admit external members.

## Deferred to later sprints

- **Sprint 48** — Workflow editor (native Flutter node-based, not literal n8n); pre-dispatch team-confirm modal.
- **Sprint 49** — Persistent scheduled agents (cron + event triggers, escalation chain, agent DM-to-user); DMs UI (data model supports from Sprint 47).
- **Sprint 50** — Custom channel creation UI; multi-workspace switching UI; agent tool allowlist UI; 4-tier role management UI.

## References

- Spec: [`superpowers/specs/2026-05-20-discord-shaped-workspace-design.md`](superpowers/specs/2026-05-20-discord-shaped-workspace-design.md)
- Plan: [`superpowers/plans/2026-05-20-sprint-47-chat-foundation.md`](superpowers/plans/2026-05-20-sprint-47-chat-foundation.md)
- Sprint 46 (cost-pricing groundwork this builds on): [`SPRINT-46-COMPLETE.md`](SPRINT-46-COMPLETE.md)
- Sprint 46.5 (Stripe overage activation): [`superpowers/specs/2026-05-20-clerk-stripe-overage-integration.md`](superpowers/specs/2026-05-20-clerk-stripe-overage-integration.md)
- CVM: `app_c3b5481b3f33551af6270a21145df613160bf063`
- Image: `ghcr.io/nicholasraimbault/tally-orch:v27` (digest `sha256:3279d13d4cc93d2d18436a5169446582d0793fe9830873b61e8472da52b276b8`)
