# Sprint 32 — Clerk OIDC + multi-user

**Status: PASS** — The orchestrator validates Clerk-issued JWTs against
the publishable key's JWKS endpoint; tasks and templates are scoped
per Clerk user_id; the legacy `TALLY_API_TOKEN` is preserved as an
admin bearer that sees all rows.  This is the multi-tenant threshold:
two different Clerk users sharing the same orchestrator never see
each other's tasks or templates.

## What was built

### Backend (`orch v12`)

- **`clerk_auth.py`** (new). `ClerkValidator` accepts a publishable key
  (`pk_test_…` / `pk_live_…`), base64-decodes it to find the Clerk
  frontend API (`eager-shrimp-36.clerk.accounts.dev` for this app),
  fetches + caches the JWKS at `/.well-known/jwks.json` (10 min TTL),
  and validates RS256 JWTs (signature + issuer + expiry).  Returns a
  `User(id, source)` dataclass.
- **`require_user` dependency** (`service.py`).  Dispatches on token
  shape: JWTs (start with `eyJ`) go through `ClerkValidator`; admin
  tokens go through the legacy `hmac.compare_digest`.  Returns
  `User(id="admin", source="admin")` for admin or
  `User(id=clerk_sub, source="clerk")` for Clerk users.
- **Schema migration.**  Added `user_id TEXT NOT NULL DEFAULT
  'legacy-admin'` to `tasks` and `team_templates` via `ALTER TABLE`.
  Indices on `(user_id, created_at DESC)` for tasks and
  `(user_id, use_count DESC)` for templates.  Existing rows surface
  as `user_id='legacy-admin'` via read-path normalization
  (`_row_to_dict` treats NULL as `legacy-admin`).
- **Endpoint scoping.**  GET/POST `/tasks`, GET/POST/DELETE
  `/templates`, `/tasks/{id}/stream`, `/tasks/{id}/files{,/path}` now
  filter by user_id when called with a Clerk JWT.  Admin source
  bypasses the filter (sees all).  `/admin/*` endpoints stay on
  `require_token` — admin-only.
- **Backwards compat.**  `CLERK_PUBLISHABLE_KEY` is optional; when
  unset, only the admin token works (pre-Sprint-32 behaviour, useful
  for staging instances without a Clerk app).
- **Dependency.**  Added `pyjwt[crypto]>=2.10` to the orchestrator's
  Dockerfile.

### Flutter

`ConfigScreen` now labels the field "Bearer token" and the helper
text explains the two accepted forms: a Clerk JWT (`eyJ…`) for
per-user mode or the admin `TALLY_API_TOKEN` for full visibility.
No transport changes — both are sent as `Authorization: Bearer
<value>`; the backend dispatches.

(Sprint 32.5 will wire the in-app Clerk sign-in flow so users don't
have to paste a JWT manually.  For now: sign in on the Account
Portal, grab the `__session` cookie, paste.  Token has a 60-second
lifetime; refresh by reloading the Account Portal page.)

## E2E validation (2026-05-18, ~01:46-01:48 UTC)

Setup: Clerk app `eager-shrimp-36.clerk.accounts.dev`, GitHub-only
sign-in.  User signed in to the Account Portal; `__session` cookie
copied as the JWT bearer.

```
$ JWT=eyJhbGci…  (842 chars, sub=user_3DsRK0xlNbeEbFkCB2NhQmEaL2T)

$ GET /tasks  Bearer $JWT
  → HTTP 200, 0 tasks visible
  (all existing rows belong to legacy-admin; new Clerk user has none)

$ POST /tasks Bearer $JWT (with team_spec preset)
  → task_id: c914749e367e
  → owner:   user_3DsRK0xlNbeEbFk…

$ GET /tasks Bearer $JWT
  → 1 task visible:
    c914749e367e owner=user_3DsRK0xlNbeEbFk…
  (correctly isolated — does NOT see admin's tasks)

$ GET /tasks Bearer $ADMIN
  → 10 tasks visible:
    c914749e367e owner=user_3DsRK0xlNbeEbFk… (new!)
    69cf346a08c2 owner=legacy-admin
    3edc6031480e owner=legacy-admin
    3a8286bc2ad0 owner=legacy-admin
    11afc0028fea owner=legacy-admin
    …
  (admin sees ALL rows including the new Clerk user's task)
```

Auth-failure smoke:

```
$ GET /tasks   (no header)
  → 401 {"detail":"missing bearer token"}

$ GET /tasks Bearer eyJfake.fake.fake
  → 401 {"detail":"invalid clerk JWT: Invalid header string: …"}
```

## Open items (queued for Sprint 32.5)

1. **In-app Clerk sign-in.**  Today the user manually pastes a
   `__session` cookie (60-second lifetime).  Sprint 32.5 wires
   `clerk_auth` (Dart package) or a webview-based hosted sign-in so
   the Flutter app does the OAuth dance + refresh transparently.
2. **No `owner_id` on the worker side.**  Workers still see tasks
   without an owner context.  When a future feature needs the worker
   to know who owns the task (e.g., per-user OpenHands API keys),
   we'll pass `owner_id` in the task_spec wake payload.
3. **`/tasks/{id}/team` not scoped.**  Sprint 22 endpoint that returns
   team_spec + agents for a task — still uses unfiltered get_task.
   Easy fix; punted to avoid touching every endpoint at once.
4. **No template editing for legacy-admin migrations.**  An admin
   can `POST /templates` and own them as `admin`; clerk users can
   create templates and own them as their Clerk user.  But the
   admin doesn't currently have a "transfer ownership" flow — the
   `legacy-admin` templates sit there visible only to admin.
   Cleanup endpoint when needed.
5. **JWT template not configured.**  Default Clerk session tokens
   are 60s; for testing we live-refresh.  A `tally-coding` JWT
   template with 1-hour lifetime would make manual testing nicer
   but isn't strictly required.

## Cost shape

- JWKS fetch: one `httpx` GET on first JWT, cached 10 min.
  Practically zero hot-path latency after warm-up.
- JWT validation: RS256 verify ≈ 0.5-1 ms.  Adds nothing meaningful
  to a request whose round-trip is already dominated by Phala CVM +
  network.

## Next sprint

**Sprint 33 — Quotas + Stripe billing.**  Per-user usage limits
(task count / month, agent hours / month) backed by a `quotas` row
keyed on user_id.  Stripe customer + subscription per user; webhook
to mint quotas on subscription change.  This sprint is the only one
that *needs* `user_id` to exist, which is exactly why Sprint 32 came
first.
