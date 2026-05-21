# Sprint 50 — Workspace finale (closes Discord-shaped vision)

**Status:** Code complete + deployed on `tally.pronoic.dev`
**Dates:** 2026-05-21 (spec) → 2026-05-21 (ship)
**Effort:** 24 commits, 32 files, +4,855 / -42 lines
**Image:** `tally-orch:v30` (deployed to Phala CVM `app_c3b5481b…`)
**Branch:** `feat/sprint-50-workspace-finale`
**Branch tags:** `s50-phase-a-done`, `s50-phase-b-done`, `s50-deployed-v30`, `s50-phase-c-done`, `s50-complete`

**This sprint closes the holistic Discord-shaped workspace vision (Sprints 47-50).**

## What shipped

### Locked decisions

| | |
|---|---|
| Scope | All 4 subsystems in one sprint. |
| Custom-channel membership | Workspace humans + Tally + persistent agents. |
| Workspace creation | Free, with 20-per-user soft cap. |
| Tool allowlist UI | Per-node in `WorkflowEditorScreen` via `FilterChip` widgets. |
| Role management UI | Dedicated `WorkspaceSettingsScreen`. |

### Backend (10 new routes + 1 migration)

| Route | Behavior |
|---|---|
| `POST /workspaces` | Create. 20-per-user soft cap (429 `workspace_limit`). |
| `GET /me/workspaces` | List caller's memberships (skips soft-deleted). |
| `PATCH /workspaces/{id}` | Update name + settings_json JSON-merge. Owner-only. |
| `GET /workspaces/{id}/members` | List. Member-only access (returns empty for non-members). |
| `POST /workspaces/{id}/members` | Invite. Admin+ only, role whitelist (no owner). |
| `DELETE /workspaces/{id}/members/{user_id}` | Remove. Admin+, owner protected. |
| `PATCH /workspaces/{id}/members/{user_id}` | Change role. Owner/Admin permission matrix. |
| `POST /channels` | `kind='custom'` creation with atomic members. Admin+ only. |
| `POST /channels/{id}/members` | Add member to custom channel. Admin+ only. |
| `DELETE /channels/{id}/members/{user_id}` | Remove from custom channel. Admin+ only. |

**Schema:** one idempotent migration — `workspaces.deleted_at REAL` for soft-delete support.

**`Db` helpers (5 new):** `create_workspace` (explicit method mirroring backfill), `list_workspace_members`, `add_workspace_member`, `update_workspace_member_role`, `remove_workspace_member`.

**Tool allowlist enforcement:** `_effective_tools_for_node(role_tools, node_allowlist)` pure helper added at module level; wired into `Orchestrator._dispatch_agent` for both flat and `nodes_v1` team_specs. None allowlist = all role tools; `[]` = deliberately no tools; explicit list = intersection.

### Frontend

**`TallyOrchClient` additions (10 methods):** `createWorkspace`, `listMyWorkspaces`, `updateWorkspace`, `listWorkspaceMembers`, `inviteWorkspaceMember`, `removeWorkspaceMember`, `updateWorkspaceMemberRole`, `createCustomChannel`, `addChannelMember`, `removeChannelMember`.

**`WorkspaceContext` `InheritedWidget`:** new top-level provider for the active `workspace_id`. Set by `main.dart` after Clerk auth. Persists across app restarts via `shared_preferences`. Replaces 5 hardcoded `workspace_id: 1` sites across `discord_shell.dart`, `general_channel.dart`, `task_channel.dart`. Includes a `activeIdOrDefault(context)` safety fallback for transient widgets that may render outside the provider tree.

**`ServerRail` widget (new):** Discord-style far-left rail. Tally "T" indicator at top, one icon per `/me/workspaces` entry (initial letter, pill→square animation when active), "+ Create workspace" tile at bottom. Tap → updates `WorkspaceContext.onChange`.

**`WorkspaceSettingsScreen` (new):** 3 sections — Branding (name + icon URL), Members (list + role dropdown gated by Sprint 47 permission matrix, "+ Invite" button opens `_InviteMemberDialog`), Danger zone (Leave workspace for non-owners, Delete workspace for owners; both currently surface a Sprint 51 TODO SnackBar because the backend `/leave` and `DELETE` routes are deferred).

**`NewChannelModal` (new):** Dialog with name TextField + 3 chip groups (Humans / Tally / Persistent agents). Submit → `createCustomChannel` → returns the new channel dict via `Navigator.pop`.

**Channel rail extension:** added "CHANNELS" category above TASKS (lists `kind='custom'` channels + "+ New channel" tile opening `NewChannelModal`). Added a workspace-settings gear icon in the rail header.

**Tool allowlist UI:** in `WorkflowEditorScreen._NodeConfigDialog` (Sprint 48), added a "Tools" section below the spec TextField when `kind='agent'`. Renders a `Wrap` of `FilterChip` widgets, one per tool in the hardcoded `_toolsByRole` map. "Use all role tools" reset button. Persists into `team_spec.nodes[i].tool_allowlist` (null = all, list = explicit).

**`NewDmModal` People tab:** the Sprint 49 hardcoded `admin` entry replaced with `listWorkspaceMembers(workspaceId)` filtered to `member_kind='human'`. The TODO from Sprint 49 is now closed.

### Testing

- Orchestrator: 45 new pytest tests across 6 new files (`test_workspace_deleted_at_migration`, `test_workspace_crud`, `test_workspace_settings`, `test_workspace_members`, `test_custom_channels`, `test_tool_allowlist`). Full suite: **239 passed in 7.84s**.
- Flutter: 9 new test files (`api_workspaces`, `api_workspace_members`, `api_custom_channel`, `workspace_context`, `server_rail`, `workspace_settings_screen`, `new_channel_modal`, plus 1 escalation test from Sprint 49 B8 still in suite). **54 pass / 1 pre-existing FAIL** (the `DiscordShellScreen renders the four-column layout` failure tracked since Sprint 47, unrelated).

### Verification

Live smoke against `tally.pronoic.dev`:

| Step | Result |
|---|---|
| `GET /health` | 200, `status: ok` |
| `POST /workspaces` | 200, returns new workspace id=5 with role='owner' |
| `GET /me/workspaces` | 200, lists both admin's original workspace (id=1) + the new s50 smoke workspace (id=5) |
| `POST /workspaces/5/members {user_id:'bob',role:'member'}` | 200, ok |
| `POST /channels` `{workspace_id:5,kind:'custom',name:'ops',members:[...admin,tally]}` | 200, returns channel id=36 |

## Sprint 51 carry-overs (intentionally deferred)

- **Leave workspace endpoint** — `DELETE /workspaces/{id}/members/self` or similar; settings UI currently shows SnackBar TODO.
- **Delete workspace endpoint** — `DELETE /workspaces/{id}` with proper cleanup; settings UI currently shows SnackBar TODO.
- **Workspace ownership transfer** — `POST /workspaces/{id}/transfer-ownership` (Sprint 50 explicitly excludes "owner" from settable roles).
- **Clerk user resolution at invite time** — Sprint 50 trusts the caller's `user_id`; Sprint 51+ can add a Clerk GET /users/{id} validation.
- **Cross-workspace DMs** — identity ramifications; Sprint 51+.
- **Workspace icon file upload** — Sprint 50 takes URL strings only; presigned S3 deferred.
- **Workspace audit log** — mentioned in Sprint 47 permission matrix; not built.
- **Channel archival UI** — `archived_at` column exists from Sprint 47; UI deferred.
- **`_ServerRail` (lowercase) cleanup** — Sprint 50 prepended the new `ServerRail` widget; the old Sprint 47 placeholder `_ServerRail` (a few icon buttons) is still present in `discord_shell.dart`. Functional but visually duplicative.
- **`widget_test.dart::DiscordShellScreen renders the four-column layout`** — pre-existing test failure from Sprint 47; the test pumps an unrealistic HTTP-failing harness. Should either be deleted or rewritten with proper mocks.

## Discord-shaped vision: complete

Sprints 47-50 collectively shipped:

| Sprint | Highlights |
|---|---|
| **47** | Chat foundation: 5 new tables, 6 message routes, WebSocket new_message, agent context injection, MessageFeed + MessageComposer Flutter widgets, replaced task_channel SSE renderer |
| **48** | Workflow editor + pre-dispatch confirm: vyuh_node_flow canvas, team_proposal cards, status='proposed', approve/cancel/PATCH team_spec routes, nodes_v1 graph executor with edge conditions |
| **49** | Persistent agents + DMs + escalation: cron + HMAC webhooks, Tally deterministic responder, DM channel kind, persistent agent scheduler, auto-pause on 3 failures |
| **50** | Workspace finale: custom channels, multi-workspace switching, 4-tier role management, agent tool allowlist UI, real workspace member endpoints |

Cumulative: ~100 commits, ~18,000 net lines added, all 4 image versions deployed to the Phala CVM, all routes pytest-covered. The Tally Coding workspace runtime now matches the holistic vision locked on 2026-05-20.

## References

- Parent design: [`superpowers/specs/2026-05-20-discord-shaped-workspace-design.md`](superpowers/specs/2026-05-20-discord-shaped-workspace-design.md)
- Sprint 50 spec: [`superpowers/specs/2026-05-21-sprint-50-workspace-finale-design.md`](superpowers/specs/2026-05-21-sprint-50-workspace-finale-design.md)
- Sprint 50 plan: [`superpowers/plans/2026-05-21-sprint-50-workspace-finale.md`](superpowers/plans/2026-05-21-sprint-50-workspace-finale.md)
- Sprints 47-49 completion docs: [`SPRINT-47-COMPLETE.md`](SPRINT-47-COMPLETE.md) / 48 / 49
- CVM: `app_c3b5481b3f33551af6270a21145df613160bf063`
- Image: `ghcr.io/nicholasraimbault/tally-orch:v30` (digest `sha256:06a2b6e2c46b7e3eb6a942d7b33d1be6fc3dff1b7a31cab5947b13a475d66741`)
