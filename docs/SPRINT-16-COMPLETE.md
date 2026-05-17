# Sprint 16 — Parallel cold-start via per-deploy image builds

**Status: PASS** — `pool=2` cold-start now ~2m 50s wall-clock (down
from ~6m in Sprint 14's serial workaround). Each provision builds and
pushes a digest-distinct image to GHCR, which gives parallel deploys
enough configuration divergence to coexist on Phala without tripping
the centralized KMS's "this app_id already has an active CVM with a
different configuration" rejection.

## The earlier blocker

Sprint 14 had a parallel-provisioning workaround that didn't work:

```
duplicate key value violates unique constraint "ix_dstack_app_nonces_address"
Key (address)=(351e475e...) already exists.
```

Two `phala deploy` calls with the same docker-compose content raced
for the same App ID. Phala's KMS has `UNIQUE(dstack_app_nonces.address)`
where `address == app_id`, so the loser failed. Sprint 14 punted to
serial provisioning (~3 min per worker, ~6 min for pool=2).

## Why per-deploy *image tags* alone weren't enough

The first instinct from the Sprint 14 docs was "push per-deploy image
tags." I tried it (Sprint 16 first iteration): `docker tag` + `docker
push` of `v10-<team_id>`, then substitute the new tag into the
per-deploy compose's `image:` field. **It didn't work.** The second
parallel deploy still ran into Phala, but with a new error:

```
[Commit CVM Provision] This app_id already has an active CVM with a
different configuration. Provision again to get a new app_id, or use
the existing CVM.
```

The reason: Phala derives the App ID by resolving `image:` to its
registry digest. Two tags pointing at the same manifest digest
produce the same App ID. The KMS race went away (because the deploys
hit slightly different timing) but Phala now noticed the two CVMs
wanted the same App ID with different env (different `TEAM_ID`,
`WORKER_PRIVKEY_HEX`) and rejected the second.

## The fix that worked: digest-distinct per-deploy builds

Build a one-line image layer on top of `v10` per provision:

```Dockerfile
FROM ghcr.io/nicholasraimbault/tally-spike-day4-worker:v10
LABEL tally.deploy_id="<team_id>"
```

The `LABEL` has no runtime effect, but it adds a new layer → new
manifest → new digest. Each `docker build` finishes in ~1 s (no
underlying-layer rebuild), and `docker push` of the new manifest +
tiny layer takes another ~1 s. Both parallel provisions push their
own image and then race into `phala deploy` with digest-distinct
references. Phala still ends up putting both CVMs under the same App
ID (so digest isn't the *only* App ID input), but it now lets the
second CVM in as a sibling rather than rejecting it.

```python
def _ensure_unique_image_tag(self, team_id: str) -> str:
    safe = re.sub(r"[^a-zA-Z0-9_.-]", "-", team_id)
    new_ref = f"ghcr.io/nicholasraimbault/tally-spike-day4-worker:v10-{safe}"
    subprocess.run(["docker", "pull", BASE_IMAGE], ...)
    dockerfile = f"FROM {BASE_IMAGE}\nLABEL tally.deploy_id=\"{team_id}\"\n"
    subprocess.run(["docker", "build", "-t", new_ref, "-"], input=dockerfile, ...)
    subprocess.run(["docker", "push", new_ref], ...)
    return new_ref
```

`_build_compose_file` substitutes the per-team ref into the compose:

```python
content = re.sub(
    r"image:\s*ghcr\.io/nicholasraimbault/tally-spike-day4-worker:[a-zA-Z0-9_.-]+",
    f"image: {image_ref}",
    content,
)
```

`_resolve_pool` and `Orchestrator.scale_pool` reverted from serial
`for i in range(n)` back to parallel `asyncio.gather(...)`.

## Timing (cold-start, fresh DB, no cached worker)

| Sprint | Provision | Wall-clock for pool=2 |
|--------|-----------|-----------------------|
| 14     | serial    | ~6 min                |
| 16     | parallel  | **~2m 50s**           |

Wall-clock per worker is unchanged (~2m 30s for the Phala CVM to come
up + emit identity + bootstrap MLS). The win is that both happen
concurrently.

## E2E run (12:23-12:26 CDT 2026-05-17)

```
12:23:26  service started; TALLY_POOL_SIZE=2
12:23:31  pushed per-deploy image v10-...-a4d1a7 (digest-distinct)
12:23:31  pushed per-deploy image v10-...-2127cf (digest-distinct)
12:23:31  provisioning worker tally-worker-...-a4d1a7
12:23:31  provisioning worker tally-worker-...-2127cf
12:26:14  worker 4ef69ac8 ready: identity=MdcLQAIYW714...
12:26:15  worker e0d34b6c ready: identity=w6miFelCEHDr...
12:26:16  bootstrap[MdcLQAIY]: MLS session established
12:26:16  bootstrap[w6miFelC]: MLS session established
12:26:16  ready; pool=2, processor loop started
```

Concurrent dispatch follow-up:

| task     | worker      | elapsed |
|----------|-------------|---------|
| 2afede69 | w6miFelCEHDr | 20.8 s  |
| d0cfe76d | MdcLQAIYW714 | 15.9 s  |

Two tasks → two workers → both `completed` with non-overlapping
`worker_identity` values. No regression from the Sprint 14 / 15 E2Es.

## Files committed

- `services/orchestrator/tally_orchestrator/worker_pool.py`:
  - `BASE_IMAGE` module-level constant.
  - `_ensure_unique_image_tag(team_id)` — pull, build (with `LABEL`),
    push (~2 s for a warm host).
  - `_build_compose_file(team_id, image_ref)` — rewrite `image:` line.
  - `provision()` calls `_ensure_unique_image_tag` before `_deploy`.
- `services/orchestrator/tally_orchestrator/service.py`:
  - `_resolve_pool` and `Orchestrator.scale_pool` revert to parallel
    `asyncio.gather` over `pool.provision`.

No worker image, no SDK, no CLI changes. Existing `v10` is the base;
`v10-*` aliases land in GHCR per provision.

## Open items

1. **GHCR tag accumulation.** Each provision pushes a tag that
   never gets cleaned up. After ~weeks of churn the project will
   have hundreds of stale `v10-tally-auto-...` tags. A nightly
   sweep that deletes tags whose corresponding `workers.cvm_id`
   row is `status='retired'` and >24 h old would clean this up.
2. **Local docker daemon required.** `pool.provision` shells out
   to `docker build` + `docker push` on the orchestrator host.
   For a hosted SaaS deployment we'd run this inside a CI-style
   sidecar; for now it's fine because the orchestrator already
   shells out to `phala deploy` (same trust boundary).
3. **`docker login` to ghcr.io is assumed.** First-time setup needs
   `gh auth token | docker login ghcr.io -u ... --password-stdin`.
   Not automated; would be part of a `tally-orch` install script.

## Next sprint candidates

1. **Clerk OIDC** — real multi-user auth (currently single bearer
   token; tunnel-only deployment).
2. **Mobile build** of `tally_coding_app` for Android.
3. **Persist result wakes in tally-workers** so a recovered
   orchestrator can pick up where it left off.
4. **GHCR tag GC** — nightly sweep of stale `v10-tally-auto-*` tags
   tied to retired workers.
