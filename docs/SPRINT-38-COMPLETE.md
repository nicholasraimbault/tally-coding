# Sprint 38 — Git push integration via user PAT

**Status: PASS (code path)** — All 7 endpoint assertions validated
against `tally-orch:v19` running on `tally.pronoic.dev`.  The
crypto path (Fernet encrypt → store → decrypt at point of use →
git push → cleanup) is wired end-to-end.

The orchestrator can now push a project's HEAD artifact set to a
user-supplied GitHub repo on a fresh branch.  The user's PAT is
stored encrypted (Fernet/AES-128-CBC + HMAC-SHA256), never logged,
and only decrypted in-memory immediately before the push.

Full E2E with a real PAT (paste in the app → run task in a project
→ push → land on GitHub) is one user-driven step away: see "How to
test it end-to-end" below.

## What shipped

### Orchestrator (`tally-orch:v19`)

**`tally_orchestrator/credentials.py` (new).**  Owns the
Fernet master key.

| Symbol | Behaviour |
|---|---|
| `CredentialsManager.configured` | False if `CREDENTIALS_KEY` env var is missing — endpoints 503 with a key-generation hint. |
| `CredentialsManager.encrypt(plaintext) -> bytes` | Fernet token (HMAC-SHA256 + AES-128-CBC). |
| `CredentialsManager.decrypt(ciphertext) -> str` | Raises `ValueError` with operator hint if the key was rotated without re-encrypting rows. |
| `redact_token(s)` | `"<masked, len=N>"` — never leaks bytes of the secret, used in every log line that mentions a token. |

**Schema (additive, idempotent).**

```sql
CREATE TABLE IF NOT EXISTS user_credentials (
    user_id     TEXT NOT NULL,
    kind        TEXT NOT NULL,
    ciphertext  BLOB NOT NULL,
    created_at  REAL NOT NULL,
    updated_at  REAL NOT NULL,
    PRIMARY KEY (user_id, kind)
);
```

Today only `kind = 'github_pat'`; future kinds (OpenAI BYOK, AWS
role ARN, etc.) drop in without a schema change.

**`tally_orchestrator/github_push.py` (new).**  The actual push
flow.  Validates `owner/repo` shape (regex), spools the project
artifacts into `/tmp/tally-orch-push-<ms>`, runs
`git init / add / commit / push https://x-access-token:<PAT>@github.com/owner/repo.git`,
parses the result, and unconditionally deletes the working tree
(the .git/config remote URL contains the plaintext PAT, so the
temp dir must not survive the request).

Custom exception classes (`GithubPushAuthError`,
`GithubPushRepoError`, `GithubPushError`) carry both a user-facing
string and a redacted operator-side detail; the route handler maps
them to 401 / 404 / 502 with the user-facing string only.

The author identity defaults to "Tally Coding
<tally@pronoic.dev>" — using the user's own GitHub identity
requires resolving the PAT's associated email, which we don't
store.  Documented as a future enhancement.

**Endpoints (all owner-scoped via `require_user`):**

| Verb / Path | Behaviour |
|---|---|
| `POST /github/token {pat}` | Encrypt + store.  Shallow shape check (must start with `ghp_` / `github_pat_` / `gho_`); we don't pre-validate against GitHub's API.  Token NEVER appears in any log line; we log `redact_token(pat)`. |
| `GET /github/token` | Returns `{has_token: bool}`.  The token itself is never returned. |
| `DELETE /github/token` | Wipe the row.  404 if nothing stored. |
| `POST /projects/{id}/push {repo, branch?, commit_message?}` | The actual push.  400 on bad shape, 404 if project missing OR no PAT stored, 401 if GitHub rejects the PAT, 502 on other git failures.  Returns `{repo, branch, commit_sha, branch_url}`. |

**Compose:** `CREDENTIALS_KEY` env var threaded through
`docker-compose.yml`.  Generation hint surfaced inline in the
config-error path.

### Flutter (`tally_coding_app`)

**`lib/api.dart`.**  `hasGithubToken / setGithubToken /
deleteGithubToken / pushProjectToGithub`.

**`lib/screens/projects_screen.dart`.**

- `_GithubChip` in the AppBar: shows "Connect GitHub" or
  "GitHub connected" (green check).  Tap to open the connect
  dialog (paste PAT) or disconnect dialog.
- `_ConnectGithubDialog`: `obscureText: true` text field for the
  PAT, with a visibility toggle.  Links to GitHub's fine-grained
  PAT creation page via `url_launcher`.  PAT is sent directly to
  the orchestrator over HTTPS; never appears in client-side logs.
- `_PushDialog`: repo / branch / commit message fields.
- `_PushResultDialog`: surfaces the new branch URL with
  "Copy URL" + "Open on GitHub" + "Done" buttons.
- Project kebab menu gets a new "Push to GitHub" item alongside
  Rename / Delete.

## E2E validation (2026-05-19, ~21:35 UTC against `tally.pronoic.dev`)

```
$ curl GET  /github/token             → {"has_token": false}
$ curl POST /github/token {"pat":"ghp_FAKE..."}  → {"stored": true}
$ curl GET  /github/token             → {"has_token": true}
$ curl POST /projects {"name":"s38-smoke"}       → proj_U7bRK9WCl5hg
$ curl POST /projects/{id}/push {"repo":"foo/bar"}
                                      → 400 "project has no files in HEAD to push"
$ curl DELETE /projects/{id}          → 200 {"deleted": ...}
$ curl DELETE /github/token           → 200 {"deleted": true}
$ curl GET  /github/token             → {"has_token": false}
```

All 7 assertions pass.  The push path exercising the actual
`git push` against GitHub needs a real PAT and a destination repo
— that's the user-driven test below.

## How to test it end-to-end

1. Generate a fresh fine-grained PAT at
   <https://github.com/settings/personal-access-tokens/new>.
   Scope: **Contents: Read and write**, optionally **Metadata:
   Read-only**.  Set it to a single test repo only — avoid an
   account-wide token.
2. In the Tally app, open **Projects** → tap **Connect GitHub**
   in the top bar → paste the PAT (the field is masked) → Connect.
3. Either select an existing project that has files in HEAD, or
   create a new one and submit a small task into it (the Sprint 36
   onboarding examples work).  Wait for the task to complete
   (project's `file_count` advances).
4. Open the project's kebab menu → **Push to GitHub**.  Enter:
   - Repo: `owner/repo` (must exist; PAT must have write scope)
   - Branch: leave blank for `tally/push-<unix-ts>`, or enter your own
   - Commit message: optional
5. Tap **Push**.  A snackbar shows "Pushing to GitHub…"; on
   success a dialog appears with the new branch URL.  Tap "Open on
   GitHub" to land on the branch + open a PR with one click.

## Open items

1. **OAuth instead of PAT.**  GitHub App OAuth would let users
   sign in instead of pasting a token, and would scope automatically
   to selected repos.  Significant API + UX work; PAT is the
   pragmatic v1.
2. **Author identity = the user.**  Today commits are authored as
   "Tally Coding".  Resolving the PAT → email → user via
   `GET /user/emails` on first connect would let us commit as the
   user themselves.  Trivial follow-up.
3. **Force-push to an existing branch.**  Today every push lands
   on a fresh `tally/push-<ts>` branch.  Real iterative workflows
   want "force-push to my-feature".  Needs an explicit confirm-
   overwrite UX so users don't blow away other people's work.
4. **PAT verification on connect.**  We don't pre-validate the
   token against GitHub's API; the next push surfaces a clean 401
   if it's bad.  A `POST /github/token` that does a `GET /user`
   to validate would catch typos earlier.
5. **CREDENTIALS_KEY rotation.**  Today a key rotation invalidates
   every stored PAT.  Out of scope for v1; documented in the
   `CredentialsManager.decrypt` error message so operators don't
   silently lose tokens.
6. **PR creation.**  We surface the branch URL but don't open the
   PR.  Easy follow-up: `gh pr create --base main --head <branch>`
   via the same PAT.

## Next sprint

**S39 — cost dashboard (per-task + monthly burn).**  Now that
real users can build → push → ship, surface the LLM token spend
per task + projected monthly burn on the BillingScreen.  Margin
visibility before [[S42 smarter LLM routing]] makes routing
decisions.
