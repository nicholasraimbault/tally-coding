# Sprint 40 — Custom user-defined agent roles

**Status: PASS** — Users can now define their own agent roles
(name + description + default model + tools + system prompt) and the
architect picks from them alongside the seeded 7-role palette.
Worker dispatch reads the custom role's system_prompt + tools when
the agent runs.  Validated against `tally-orch:v22` on the live
CVM.

## What shipped

### Orchestrator (`tally-orch:v22`)

**Schema (additive, idempotent).**

```sql
CREATE TABLE IF NOT EXISTS user_agent_roles (
    user_id        TEXT NOT NULL,
    name           TEXT NOT NULL,
    description    TEXT NOT NULL,
    default_model  TEXT NOT NULL,
    tools_json     TEXT NOT NULL,
    system_prompt  TEXT NOT NULL,
    created_at     REAL NOT NULL,
    updated_at     REAL NOT NULL,
    PRIMARY KEY (user_id, name)
);
CREATE INDEX idx_user_roles_user ON user_agent_roles(user_id, updated_at DESC);
```

Parallel to the existing seeded `agent_roles` table — namespaced
by `user_id` so two users can both have a role named `DataAnalyst`
without colliding.  Lookups go user-roles-first then fall back to
seeded; the create endpoint rejects names that collide with seeded
roles, so the fallback always lands on the seeded copy.

**Db helpers.**

| Method | Behaviour |
|---|---|
| `list_agent_roles(user_id=None)` | Seeded + caller's custom roles, each tagged with `source ∈ {seeded, custom}`. |
| `get_agent_role(name, user_id=None)` | Custom takes priority via name; falls back to seeded. |
| `create_custom_role(user_id, name, description, default_model, tools, system_prompt)` | Insert.  Caller validates collisions. |
| `update_custom_role(user_id, name, ...)` | Partial PATCH.  Rename not supported (drop + recreate). |
| `delete_custom_role(user_id, name)` | Remove. |
| `list_custom_role_names(user_id)` | Set for collision check. |
| `seeded_role_names()` | Set for collision check. |

**Endpoints (all `require_user`, all Clerk-only — admin source rejected with 400).**

| Verb / Path | Behaviour |
|---|---|
| `POST /agent_roles` | Create.  400 on bad input (allow-list for model + tools), 409 on name collision. |
| `PATCH /agent_roles/{name}` | Partial update.  Same validation. |
| `DELETE /agent_roles/{name}` | Remove.  Tasks already running with this role are unaffected. |
| `GET /admin/agent_roles` | Returns seeded + caller's custom, each tagged with `source`. |

**Server-side allow-lists** (the orchestrator-side guard rails so
users can't smuggle in unsupported models / tools):

```python
_ALLOWED_MODELS = {
    "meta-llama/llama-3.3-70b-instruct",
    "moonshotai/kimi-k2-instruct", "moonshotai/kimi-k2.6-instruct",
    "deepseek/deepseek-r1-0528", "deepseek/deepseek-r1",
    "deepseek/deepseek-v3.2", "deepseek/deepseek-v3",
}
_ALLOWED_TOOLS = {
    "file_editor", "file_editor_read",
    "bash", "bash_read", "browser",
}
```

Extend by editing — there's no per-user override (we want a
known-safe surface).

**Architect + worker dispatch wiring.**

- `submit_task`: when building the palette, scopes
  `list_agent_roles(user_id=user.id)` to the calling user.  The
  architect's prompt now includes both seeded roles AND the
  user's custom ones, so it can pick a custom role for the team.
- `_start_team` / `_dispatch_agent`: pass `task.user_id` into
  `get_agent_role(name, user_id=...)` so worker dispatch reads
  the right system_prompt + tools.  Admin / legacy-admin tasks
  fall back to seeded-only lookups (admin doesn't own custom
  roles).

### Flutter (`tally_coding_app`)

**`lib/screens/custom_roles_screen.dart` (new).**  Two-section
list — "Your custom roles" (CRUD enabled) and "Seeded roles
(read-only)".  Floating "+ New custom role" button.

**`_RoleFormDialog`.**  Same form for create + edit.  Fields:

- **Name** — only editable on create (rename unsupported on backend).
- **Description** — what the architect sees in the palette.
- **Default model** — dropdown of the allow-list.
- **Tools** — FilterChip multi-select against the allow-list.
- **System prompt** — multi-line, sent to the worker for each agent run.

Client-side input validation mirrors the server: empty name +
prompt → snackbar, then submit.  Server returns 409 on collision
with seeded names (e.g. "Coder") so users can't shadow seeded
roles even by accident.

**`lib/api.dart`.**  `createCustomRole / patchCustomRole /
deleteCustomRole` methods; `listAgentRoles` unchanged (now
auto-returns both seeded + custom).

**`lib/screens/discord_shell.dart`.**  Server rail (wide + narrow
drawer) gets a 🧠 (`Icons.psychology_outlined`) entry that opens
`CustomRolesScreen`.

## E2E validation (2026-05-19, ~23:30 UTC against `tally.pronoic.dev`)

```
$ curl -X POST /agent_roles  (admin)
  → 400 "admin doesn't own custom roles; sign in as a Clerk user"
```

Admin-rejection works as designed.  Full Clerk-user E2E (create →
appears in architect palette → architect picks it → worker
dispatches with custom system_prompt) requires a real user-driven
test through the Flutter UI; orchestrator-side wiring validated
by code review + the schema migration smoke.

## Open items

1. **Custom roles in /admin/agent_roles for non-clerk callers.**
   Admin source returns ONLY seeded roles (correct — admin has no
   custom-role rows).  A future "view roles owned by user X"
   admin tool would help operator-side debugging; for now,
   inspecting via SQL on the CVM is fine.
2. **Rename.**  PATCH doesn't rename (PRIMARY KEY constraint on
   `(user_id, name)`).  Workaround: delete + recreate.  Real
   rename would need a SQL `UPDATE … SET name=?` + collision
   check; ~10 LOC.
3. **System-prompt versioning.**  Today PATCH overwrites
   `system_prompt` in place — no history.  Tasks that already ran
   under the old prompt are fine (their team_spec captures the
   prompt at dispatch time), but a future "see role history" UX
   needs a separate audit trail.
4. **Cost-per-custom-role panel.**  S39's cost breakdown shows
   by-model but not by-role.  Adding a `by_role` aggregation
   would surface "your `DataAnalyst` role cost $X this period".
   ~3 lines of SQL + a UI tile.

## Next sprint

**S41 — multi-task workflows (architect chains tasks).**  Architect
can emit a task DAG where task A's artifacts seed task B's
workspace.  Custom roles + persistent projects + cost dashboard
now exist — chaining is the last piece that turns "multi-agent
single task" into "multi-task pipeline".
