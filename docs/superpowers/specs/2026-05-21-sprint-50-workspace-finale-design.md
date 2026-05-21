# Sprint 50 — Custom channels + multi-workspace + role mgmt + tool allowlist

**Date:** 2026-05-21
**Builds on:** Sprint 47 (chat foundation), Sprint 48 (workflow editor), Sprint 49 (persistent agents + DMs)
**Parent spec:** [`2026-05-20-discord-shaped-workspace-design.md`](2026-05-20-discord-shaped-workspace-design.md)
**Closes:** the holistic Discord-shaped workspace vision (sprints 47-50)

## Locked decisions (from brainstorm)

| | |
|---|---|
| Scope | **All 4 subsystems in one sprint.** Closes the holistic vision. Custom channels + multi-workspace UI + agent tool allowlist + 4-tier role management. ~60h. |
| Custom-channel membership | **Workspace humans + Tally + persistent agents.** Most flexible. Same permission model as today's channel_members. |
| Workspace creation | **Free, with 20-per-user soft cap.** Per-user quota (Sprint 46) already caps spend; workspace count doesn't multiply costs. The cap is a database-bloat defense, raisable later. |
| Tool allowlist UI | **Per-node in `WorkflowEditorScreen`.** Each agent node carries its own `tool_allowlist` in `team_spec.nodes[i]`. Per-fire, per-agent granularity. No new DB columns. |
| Role management UI | **Dedicated `WorkspaceSettingsScreen` with member list + role dropdown.** Owner can change any role; Admin can change Manager/Member; nobody else can edit roles (per Sprint 47 permission matrix). |

## Backend changes

### 1. New endpoints

| Route | Behavior |
|---|---|
| `POST /workspaces` | Create a workspace owned by the caller. Enforces 20-per-user soft cap (429 with `error: 'workspace_limit'` if exceeded). Auto-creates `#general` + `#backlog` channels + owner + Tally workspace_members + channel_members. Same shape as Sprint 47 backfill produces. |
| `GET /me/workspaces` | List all workspaces the caller is a member of. Returns `[{id, name, role, created_at}]`. Used by the server-rail UI. |
| `PATCH /workspaces/{id}` | Update workspace branding/settings. Body merges into `settings_json`. Owner-only. |
| `GET /workspaces/{id}/members` | List `workspace_members` rows. Returns `[{user_id, member_kind, role, joined_at}]`. Workspace-member-only access. |
| `POST /workspaces/{id}/members` | Invite a user. Body: `{user_id, role}`. Admin+ only. Sprint 50 trusts the caller's user_id (no Clerk roundtrip — deferred to Sprint 51). |
| `DELETE /workspaces/{id}/members/{user_id}` | Remove a member. Admin+ only. Can't remove the owner. |
| `PATCH /workspaces/{id}/members/{user_id}` | Change role. Body: `{role}`. Owner can change any role; Admin can change Manager/Member; cannot change to/from Owner role (ownership transfer is a Sprint 51 route). |
| `POST /channels` | Sprint 47 declared this implicitly; Sprint 50 makes it explicit for `kind='custom'`. Body: `{workspace_id, kind: 'custom', name, members: [{kind, id}, ...]}`. Caller must be Admin+. Members added as channel_members atomically. |
| `POST /channels/{id}/members` | Add a member to a custom channel. Body: `{member_kind, user_id?, persistent_agent_id?}`. Admin+ only. |
| `DELETE /channels/{id}/members/{user_id}` | Remove from custom channel. Admin+ only. |

### 2. Schema

**No new tables.** Sprint 47's schema already supports it all (workspaces / workspace_members / channels with `kind='custom'` / channel_members).

**One additive migration**: `workspaces.deleted_at REAL` (idempotent `ALTER TABLE`) — mirrors `persistent_agents.deleted_at`. Soft-deleted workspaces don't count toward the 20-cap.

### 3. Multi-workspace context

Routes don't change signatures — the Flutter UI sends the *active* workspace_id (selected from the server rail) as the existing query/path param. For routes that resolve workspace implicitly (e.g., `POST /channels/dm` uses `owner_user_id` lookup), Sprint 50 adds an optional `workspace_id` body parameter to disambiguate.

### 4. Tool allowlist enforcement

In `Orchestrator._dispatch_agent`, after looking up `role.tools`, intersect with `team_spec.nodes[i].tool_allowlist` if set:

```python
role_tools = role.get("tools", [])
node_allowlist = node.get("tool_allowlist")
effective_tools = (
    [t for t in role_tools if t in node_allowlist]
    if node_allowlist is not None
    else role_tools
)
```

Pass `effective_tools` in the worker payload. Unknown tool names in `node_allowlist` are silently dropped (already filtered by the intersection). Empty resulting list is allowed — that's a deliberate "no tools" agent.

### 5. Workspace-creation soft cap

```python
existing_count = db._conn.execute(
    "SELECT COUNT(*) FROM workspaces WHERE owner_user_id=? AND deleted_at IS NULL",
    (user.id,),
).fetchone()[0]
if existing_count >= 20:
    raise HTTPException(429, {"error": "workspace_limit", "limit": 20, "current": existing_count})
```

### 6. Member invitation — Sprint 50 picks "trust the caller"

`POST /workspaces/{id}/members` doesn't Clerk-resolve the user_id. The caller (already a Clerk-authenticated workspace admin) supplies the user_id; we trust it. Bounded by 20-workspace cap + per-workspace role check. Sprint 51 can add Clerk roundtrip if false invites surface.

## Frontend changes

### 1. Server rail (multi-workspace)

The Sprint 47 mockup had a far-left rail with workspace icons. Sprint 50 lights it up:
- Top: "T" icon for Tally (visual home indicator)
- Middle: one icon per workspace from `GET /me/workspaces`
- Bottom: "+ Create workspace" tile → `_CreateWorkspaceDialog` → POST /workspaces → switches active context to the new workspace

The active `workspace_id` lives in a `WorkspaceContext` `InheritedWidget` set by `main.dart` after Clerk auth. Every existing screen that currently hardcodes `workspace_id: 1` reads from this provider instead. **This is a non-trivial refactor** — Sprint 47/48/49 hardcoded `workspace_id: 1` in many places. Sprint 50 finds + replaces each call site.

Active workspace_id persists in `shared_preferences` across app restarts.

### 2. Custom channel creation

Add a "Channels" category at the top of the rail (above Sprint 47/49's TASKS/SCHEDULED/DMs) with a "+ New channel" tile. Tap → `_NewChannelModal`:
- Name TextField
- Kind: hardcoded to `custom` for Sprint 50
- Members section: 3 chip groups (Humans / Tally / Persistent agents) — multiselect with the caller pre-selected
- Submit → `POST /channels` → channel appears in rail under "Channels" + user navigates into it

### 3. `WorkspaceSettingsScreen` (new)

Reached from the workspace icon (right-click → "Settings") or channel-rail gear. 3 sections:

- **Branding** — name TextField + icon URL TextField. Persists via `PATCH /workspaces/{id}` JSON-merge into `settings_json`.
- **Members** — `ListView` of `workspace_members`. Each row: name + role dropdown (Owner/Admin/Manager/Member). Dropdown disabled per Sprint 47 permission matrix (Admin can edit Manager/Member; nobody edits Owner). "+ Invite member" button opens TextField for user_id + role picker.
- **Danger zone** — "Leave workspace" (any non-owner) or "Delete workspace" (owner only — soft-delete sets `deleted_at`).

### 4. Agent tool allowlist UI

In `WorkflowEditorScreen`'s `_NodeConfigDialog` (Sprint 48 B5), add a "Tools" section below the spec TextField when `kind='agent'`:
- `Wrap` of `FilterChip` widgets, one per tool from `role.tools` (fetched via existing `GET /agent-roles/{role}` or hardcoded for Sprint 50)
- Tap → toggle selection
- Default: all selected (preserves today's "use all role tools" semantics)
- Persists into `team_spec.nodes[i].tool_allowlist: list[str]`

### 5. `api.dart` additions (~10 methods)

```dart
createWorkspace({name})
listMyWorkspaces()
updateWorkspace({id, patch})
listWorkspaceMembers({workspaceId})
inviteWorkspaceMember({workspaceId, userId, role})
removeWorkspaceMember({workspaceId, userId})
updateWorkspaceMemberRole({workspaceId, userId, role})
createCustomChannel({workspaceId, name, members})
addChannelMember({channelId, memberKind, userId?, persistentAgentId?})
removeChannelMember({channelId, userId})
```

### 6. NewDmModal People tab — real members

Sprint 49 hardcoded the People tab to `admin`. Sprint 50 fetches via `listWorkspaceMembers(workspaceId: activeWorkspaceId)` and filters to `member_kind='human'`.

## Hook point changes

- **`Db.create_workspace`** (new explicit method): inserts workspaces row + owner + Tally workspace_members + general/backlog channels + Tally channel_members. Mirrors Sprint 47 backfill for one user as a callable helper.
- **`Db.list_workspace_members`** + `Db.add_workspace_member` + `Db.update_workspace_member_role` + `Db.remove_workspace_member` — straightforward DB helpers backing the new routes.
- **`Db.create_custom_channel`** — inserts channel + channel_members atomically.
- **`Orchestrator._dispatch_agent`** — intersect `role.tools` with `node.tool_allowlist`.
- **Flutter `WorkspaceContext`** provider — new top-level `InheritedWidget` set by `main.dart`. Active workspace_id read from `shared_preferences`.

## Testing

### Backend (10 new test files)

- `test_workspace_crud.py` — create + list + 20-cap (429)
- `test_workspace_settings_patch.py` — PATCH merges settings_json
- `test_workspace_members.py` — list/invite/remove/role-change + permission matrix
- `test_workspaces_deleted_at_migration.py` — column + soft delete
- `test_custom_channel_create.py` — kind='custom' + atomic members
- `test_channel_member_management.py` — add/remove channel_members
- `test_tool_allowlist_enforcement.py` — intersection logic in dispatch
- `test_member_role_permission_matrix.py` — Sprint 47 matrix enforced
- `test_multi_workspace_isolation.py` — caller in workspace A can't list members of workspace B
- `test_dm_route_workspace_id_param.py` — POST /channels/dm with workspace_id param

### Flutter (8 new test files)

- `test/api_workspaces_test.dart`
- `test/api_workspace_members_test.dart`
- `test/api_custom_channel_test.dart`
- `test/server_rail_test.dart`
- `test/workspace_settings_screen_test.dart`
- `test/new_channel_modal_test.dart`
- `test/workspace_context_test.dart`
- `test/tool_allowlist_chips_test.dart`

## Verification

After Phala deploy:
- Create a second workspace → both appear in `GET /me/workspaces`
- Try a 21st → `429 workspace_limit`
- Invite a user → row created (no Clerk validation in Sprint 50)
- Create custom channel with mixed members (admin + tally + persistent_agent) → all 3 channel_members rows
- Edit a node in WorkflowEditorScreen, deselect a tool chip, save → `team_spec.nodes[i].tool_allowlist` excludes that tool
- `run_now` the agent → dispatched payload's `tools` list matches the intersection

## Out of scope (deferred)

- **Cross-workspace DMs** — Sprint 51+
- **Workspace ownership transfer** — Sprint 51 separate route
- **Workspace icon upload** (presigned S3) — Sprint 50 only takes URL strings
- **Clerk user resolution at invite time** — Sprint 51 if false invites surface
- **Per-workspace Tally branding** — column exists, UI in Sprint 51+
- **Workspace audit log** — Sprint 47 matrix mentions it; deferred
- **Channel archival UI** — `archived_at` exists; UI in Sprint 51+

## Effort estimate

- **Backend:** ~20h
- **Flutter:** ~35h
- **Deploy/verify:** ~5h
- **Total:** ~60h

## References

- Parent design: [`2026-05-20-discord-shaped-workspace-design.md`](2026-05-20-discord-shaped-workspace-design.md)
- Sprint 47-49 completion docs: [`../../SPRINT-47-COMPLETE.md`](../../SPRINT-47-COMPLETE.md) / 48 / 49
- Sprint 47 permission matrix: parent spec §"Permission model"
