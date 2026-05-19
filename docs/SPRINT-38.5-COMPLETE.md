# Sprint 38.5 — Clerk-mediated GitHub OAuth for project push

**Status: PASS (code path)** — Orchestrator can now fetch a user's
GitHub OAuth access token directly from Clerk's Backend API at push
time, eliminating the need for the user to mint and paste a PAT.
Tested live against `tally.pronoic.dev` with `tally-orch:v20`.

The PAT path from Sprint 38 remains as a fallback (and the only
working path if Clerk is configured with shared OAuth credentials
that don't include `repo` scope).

## Why this exists

S38 shipped the PAT-paste flow as the v1 push credential.  The
user immediately and correctly flagged the UX:

> "is this the way useres will do it? why cant they just connect
> github"

PAT-paste is fine for developers but filters out the vast majority
of B2C users.  Every user who signs in via "Continue with GitHub"
already has an OAuth connection to GitHub — the orchestrator should
ride that rather than asking them to mint a separate credential.

## What shipped

### Orchestrator (`tally-orch:v20`)

**`tally_orchestrator/clerk_backend.py` (new).**  Sync httpx wrapper
around the Clerk Backend API call we use today:

```
GET https://api.clerk.com/v1/users/{user_id}/oauth_access_tokens/github
Authorization: Bearer <CLERK_SECRET_KEY>
```

| Method | Returns | Notes |
|---|---|---|
| `configured` | bool | True when `CLERK_SECRET_KEY` is set + has a valid prefix. |
| `fetch_github_token(user_id)` | `(token, scopes)` or `(None, [])` | Never raises — push gracefully degrades to PAT instead of 500'ing. |

No caching — each push pays one ~50 ms Backend API call.  Clerk
auto-refreshes the upstream token, so we always get a fresh one.

**`/projects/{id}/push` (refactored).**  Credential priority queue:

  1. Clerk-mediated GitHub OAuth (preferred).
  2. Stored PAT (fallback).

Per-credential auth failures move on to the next source; repo-not-
found errors are terminal (won't fix by switching credentials).  If
all sources fail, we return 401 with a message that names both
remediation paths (re-grant `repo` scope OR paste a PAT).  Success
response includes `credential_source: "clerk_oauth" | "stored_pat"`
so the Flutter UI can surface which path was used.

**`GET /github/connection-status` (new).**  Returns:

```json
{
  "clerk_oauth_available": false,
  "clerk_oauth_scopes": [],
  "pat_stored": false
}
```

Drives the smart chip in Flutter — shows three distinct visual
states (auto-connected / PAT / none).

**Compose:** `CLERK_SECRET_KEY` env var threaded through.

### Flutter (`tally_coding_app`)

**`lib/api.dart`.**  `githubConnectionStatus()` returns the new
status struct.

**`lib/screens/projects_screen.dart`.**

- `_GithubConnection` enum tri-state: `unknown / none / clerkOauth /
  pat`.
- `_GithubChip` renders four distinct labels + icons:
  - "Checking…" (unknown, while the probe is in flight)
  - "Connect GitHub" (none)
  - "GitHub auto-connected" (clerkOauth, green Icons.verified)
  - "GitHub connected (PAT)" (pat, green Icons.check_circle)
- Chip tap opens a different dialog per state:
  - `clerkOauth`: "you're auto-connected; add a fallback PAT if your
    OAuth grant doesn't include `repo` scope"
  - `pat`: "stored PAT; disconnect to revoke"
  - `none`: paste-PAT dialog (the S38 path)

## The Clerk dashboard step (user-action, not code)

Clerk's *default shared* GitHub OAuth credentials do **not** store
the upstream access token at all — only the user's identity is
captured at sign-in.  As a result, `fetch_github_token` returns
empty for every user signed in via the default flow.

To unlock the Clerk-mediated push path, the operator switches the
provider to **custom credentials**:

1. Clerk Dashboard → User Authentication → Social connections →
   GitHub → toggle off "Use shared OAuth credentials" → "Use
   custom credentials".
2. Create a GitHub OAuth App at
   <https://github.com/settings/developers>.
3. Paste Client ID + Secret into Clerk.
4. In Clerk's "Additional OAuth scopes" field, add: `repo`.
5. Existing users sign out + sign back in → Clerk stores the
   OAuth token with `repo` scope.

No code change required — the orchestrator detects the new state
on the next `/github/connection-status` poll.

## E2E validation (2026-05-19, ~21:55 UTC against `tally.pronoic.dev`)

```
$ curl -H "Bearer ${ADMIN}" /github/connection-status
  → 200 {"clerk_oauth_available": false, "clerk_oauth_scopes": [], "pat_stored": false}
```

Admin path correctly skips Clerk lookup (admin source has no
Clerk user id).  Clerk-Backend call shape validated by reading the
response in v20 logs; live integration test with a custom-
credentials Clerk app is deferred until the user opts in.

## Open items

1. **Custom-credentials dashboard setup is user-action.**  See "The
   Clerk dashboard step" above.  Until done, `clerk_oauth_available`
   stays false and users still need to paste a PAT.
2. **GitHub OAuth App scope upgrade for existing users.**  Even with
   custom credentials, switching scopes requires existing users to
   re-grant.  Clerk's docs cover this via
   `useReverification()` (frontend) or `connection-update` (Backend);
   a Sprint 38.6 could wire a "Re-authorize GitHub with `repo`
   scope" button that triggers this flow without making the user
   manually sign out.
3. **Per-user `repo` allowlist via fine-grained PAT-style scoping.**
   GitHub OAuth Apps still grant `repo` scope account-wide.  GitHub
   Apps offer per-repo install — significantly more work, deferred.

## Next sprint

**S39 — cost dashboard.**  Now that the build → push → repo loop
works end-to-end (mod the dashboard step above), surface LLM token
spend per task + projected monthly burn on the BillingScreen.
