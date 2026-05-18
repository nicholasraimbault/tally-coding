# Sprint 29 — "Save this team" templates emerge

**Status: PASS** — Users can promote a completed task's team to a
named template; Tally weighs saved teams when picking the next team
and either reuses one verbatim or builds fresh.  This is the locked
roadmap's "emergent feature" milestone: templates are not a
foundational primitive, they arise from real user behaviour.

## What was built

### Backend

**`team_templates` table.**  Name PK, JSON team_spec, source_task_id
back-pointer, optional note, `created_at` / `last_used_at` /
`use_count` for usage analytics + future ranking.

**`Db` helpers** — `create_template`, `list_templates`,
`get_template`, `delete_template`, `touch_template`.  `touch_template`
bumps `last_used_at` + `use_count`; the orchestrator calls it when
the architect picks a template.

**HTTP endpoints** (bearer-token gated):
- `POST /templates {name, source_task_id, note?}` — copy the task's
  team_spec, save under `name`.  409 on name collision.  Light input
  sanitization (≤64 chars, no `/`, no control chars).
- `GET /templates` — list, sorted by `use_count desc, created_at desc`.
- `GET /templates/{name}` — single template lookup.
- `DELETE /templates/{name}` — remove by name.

### Architect

`architect_team` takes a new `templates` kwarg; the prompt grows a
section that surfaces saved teams (capped at 12 to keep token budget
in check) with their agent shape + use_count.  Instructions tell the
model:

> If one of these saved teams is a CLEAN MATCH for the current task,
> reuse it: emit its agents/stages/workflow verbatim AND set
> `"template_used": "<name>"` in the output. Otherwise build fresh
> and omit `template_used`.  Prefer fresh-build when the task shape
> is novel — forced reuse is worse than a tailored team.

Validator carries `template_used` through only when the name matches
a real template; the orchestrator bumps `use_count` on the first
dispatch.

### POST /tasks integration

After the architect call, if `team_spec.template_used` is set the
orchestrator `touch_template`s the saved entry — so the use stats
reflect real reuse, not just user pins.

### Flutter

Task channel header gains a bookmark button when the task is
`completed` + has a `team_spec`.  Tap → modal asks for a name + an
optional note → `POST /templates` → snackbar on success / collision
error.

The team-summary line under the task description now reads
`Tally picked 4 agent(s): … · via template \`pytest-team\``
when the architect reused a saved team, so it's visible without
clicking through.

## E2E validation (2026-05-18, ~04:18-04:19 UTC)

```
$ POST /templates {name: pytest-team, source_task_id: 11afc0028fea…}
  → saved: pytest-team
  → shape: Planner → Coder → Reviewer → Tester (stages [[0], [1], [2,3]])

$ POST /tasks  (similar shape: "Write string_utils.py with reverse(s). Add a pytest test.")
  → template_used: pytest-team
  → agents:        Planner → Coder → Reviewer → Tester
  → stages:        [[0], [1], [2, 3]]

$ GET  /templates/pytest-team
  → use_count: 1
  → last_used_at: 1779064747.47…

$ POST /tasks  (different shape: security review, no coding)
  → template_used: None
  → agents:        Planner → SecReviewer → DocWriter
  → reasoning:     "Sequential workflow is chosen because each agent's
                    output depends on the previous one's analysis."
```

Tally correctly reused `pytest-team` for a matching task, didn't
reuse for a non-matching one, and `use_count` ticked up.

## Cost shape

The architect prompt grows by ~80 tokens per saved template (cap 12 →
≤960 extra prompt tokens).  At Llama-3.3-70B Red Pill prices that's
fractions of a cent per task; cheap relative to the value of a clean
reuse.

## Open items

1. **No template-edit endpoint.**  Today you `DELETE` then re-`POST`
   to tweak a saved team.  A `PATCH /templates/{name}` would be
   easy when there's demand.
2. **Templates aren't shared across users.**  Coupled with Sprint 32
   (multi-user / Clerk OIDC).  Schema doesn't have an `owner`
   column yet — the migration is small.
3. **No template-suggested-name auto-fill.**  The Flutter dialog
   asks for a name; ideally Tally would suggest one based on the
   task's shape (e.g. "py-test-team" for Planner+Coder+Reviewer+Tester
   teams that produced `.py` + pytest output).  Punt to a polish
   sprint.
4. **No surfacing of saved templates in `#general`.**  The
   architect uses them invisibly.  A future polish would let the
   user type "use my fast-pytest team" and have Tally honour it.

## Next sprint

**Sprint 30 — Visual team builder.**  An n8n-style canvas behind the
⚙ icon for editing topologies by hand.  Same JSON engine as Tally's
output, so a hand-edited team can also be saved as a template.
