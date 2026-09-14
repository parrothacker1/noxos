# noxos-server — Task List

Last updated: 2026-09-10/11. Read [`../README.md`](../README.md) (hub) and [`../PROJECT.md`](../PROJECT.md) (architecture, source of truth — especially the "OTA distribution" section, which this repo implements) first for cross-repo context — this file is `noxos-server`'s own task history, split out from the old combined `TASKS.md` (now just an index at `../TASKS.md`). See also this repo's own [`README.md`](README.md).

## What happened, in order

**Session 4** (2026-08-16) — OTA design revised from GitHub Releases to S3-based hosting, `noxos-server` rewritten to match:
1. OTA design revised: GitHub Releases → S3 (`s3://noxos-releases/full/`, `.../patches/`), single-hop delta patches via `ota_from_target_files`. `../PROJECT.md`'s "OTA distribution" section updated to match.
2. **`noxos-server` rewritten end-to-end for the new S3-based OTA design** — `list-s3-releases.sh` replaces `fetch-releases.sh`, `build-manifest.sh` now parses both `full/` and `patches/` S3 keys and emits a `patches` array alongside `response` in each manifest. Tested locally + in CI against a new fixture (`testdata/s3-listing.json`). CI green. **Unrun end-to-end at the time** — no S3 bucket existed yet; needed `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_DEFAULT_REGION`/`NOXOS_S3_BUCKET`/`NOXOS_S3_BASE_URL` as repo secrets/variables before scheduled runs would succeed — resolved once the bucket was created (see [`../noxos-os/TASKS.md`](../noxos-os/TASKS.md), Phase 1 "Deferred until 1a-1c are proven" item 11, which also covers the dedicated `noxos-server-ci` read-only IAM user this repo's CI uses).

**2026-09-10/11** — real v1 build existed for the first time (see [`../noxos-os/TASKS.md`](../noxos-os/TASKS.md)), so the previously-deferred OTA-serving Lambda got its first real draft:
- Started drafting the live OTA-signing Lambda (`noxos-server/lambda/ota_handler.py` + tests) per the user's spec: device sends its current version, server resolves next-hop (single patch or full fallback, same logic the static manifest already used) and returns a presigned S3 URL. Deliberately **not deployed** — no IAM role, no Function URL, no manifest→S3 publish wiring, no bucket-policy change — revisit once v1 is verified end-to-end (it now is, boot-confirmed 2026-09-12, see [`../noxos-os/TASKS.md`](../noxos-os/TASKS.md)). Scoped explicitly as v1 architecture; bundled multi-version jumps (v1→v3 in one update) are real v2 scope, not a permanent non-feature.
- **Revised OTA distribution design (2026-09-10, per `../PROJECT.md`)**: the download step becomes this live signing Lambda; the manifest-generation pipeline (`list-s3-releases.sh`/`build-manifest.sh`) stays static and unchanged. Device sends its current version, the server (this Lambda) figures out what comes next and hands back a signed S3 URL — deliberately kept as v1 scope.
  - `s3://noxos-releases/full/` — periodic complete builds, for fresh installs or devices too far out of date to patch forward.
  - `s3://noxos-releases/patches/` — incremental deltas between *consecutive* full releases only, generated via AOSP's `ota_from_target_files -i old.zip new.zip patch.zip`. A patch isn't a separate build artifact — it's a diff computed from two already-built target-files packages.
  - **Manifest generation is unchanged**: the scheduled GitHub Action (now weekly, not every 6h) still lists the bucket and builds a `{response, patches}` JSON per device/channel, published to GitHub Pages exactly as before.
  - **New (drafted, not deployed): `noxos-server/lambda/ota_handler.py`.** A Lambda that reads that same manifest JSON (from S3 directly once the publish step also uploads there — not yet wired) and, given `?device=&channel=&version=`, applies the existing single-hop-patch-else-full-image resolution logic server-side instead of leaving it to the client, then returns a **presigned S3 URL** (1h expiry) for the one file the device should download next. The device applies it, then calls again with its new version to get the next hop — sequential, not bundled. Pure resolution logic (`resolve_update`) is unit-tested with plain asserts (`lambda/test_ota_handler.py`, passes in an isolated venv since boto3 isn't installed system-wide here — it ships built into the Lambda Python runtime itself, so the real deploy needs zero dependency packaging).
  - **Still not deployed, deliberately** — no IAM role, no Function URL, no manifest→S3 publish step, no bucket-policy change yet. Revisit once there's real traffic to test end-to-end against. When it is deployed, the bucket's current public `GetObject` policy on `full/`/`patches/` should be reconsidered — presigned URLs only mean something if the objects aren't already publicly readable without one.
  - **Still no N-hop patch chaining across multiple missed versions** in v1 — a device more than one release behind gets the full image, same as before. N-hop / bundled chaining is explicitly v2 scope now, not a "maybe never."
  - **No push notifications** — client polls (now calls the Lambda) on its own schedule instead of FCM (conflicts with GMS-independence) or a self-hosted UnifiedPush relay.
  - **No CDN in front of S3** — explicitly deferred, not v1 scope, user's own call ("not right now").
  - Signing stays self-controlled regardless of hosting — the "we don't trust Google's OTA channel" claim lives in who holds the keys, not in running custom server infra. A presigned URL is signed with those same self-controlled credentials, not a third party's.

## Backlog

- Deploy the `ota_handler.py` Lambda for real (IAM role, Function URL, manifest→S3 publish wiring, bucket-policy reconsideration for presigned-URL-only access) — drafted, not started.
- CI action version bumps (matches the same Node 20 / `setup-java` deprecation warnings seen in `noxos-app`'s CI — not urgent).

## Not real tasks — deliberately not building these

- Patch chaining across multiple missed OTA versions (N-hop), in v1 — see "Deliberate Non-Features" in this repo's own [`README.md`](README.md); reclassified as real v2 scope (not permanent) as of 2026-09-10.
- Push notifications for update availability — conflicts with the GMS-independence pillar (see `../PROJECT.md`).
- A persistent self-hosted OTA server / Lambda-as-compute-on-request beyond the one signing Lambda described above — the manifest-generation side stays static (GitHub Pages), deliberately.
