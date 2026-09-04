# noxos-server

**Bash + `aws`/`jq`** — static OTA manifest publisher, not a running service. Originally a Go HTTP server; then a GitHub-Releases-reading manifest generator; revised again 2026-08-16 to read from S3 (GitHub Releases' 2GB-per-file limit is a real risk for full Android image bundles) and to catalog delta patches alongside full images.

## Why it changed (twice)

First revision (2026-08-15): once artifacts live on GitHub Releases and the client does its own version comparison, the only server-side job left was "reshape release JSON into a per-device file" — a transform, not a service. A scheduled GitHub Action did that, output published to GitHub Pages.

Second revision (2026-08-16): GitHub Releases can't hold a full Android image reliably (2GB/file cap), so the OTA design moved artifacts to S3 (`s3://noxos-releases/full/` and `s3://noxos-releases/patches/`). This repo's job stayed the same shape — list, transform, publish — just pointed at S3 instead of the GitHub Releases API.

## Cross-project pointers

| Need to know… | Go to |
|---|---|
| Where the signed OTA zips and patches this indexes actually come from | `noxos-os` — full images and patches (via AOSP's `ota_from_target_files`) get uploaded to S3 there, this repo only reads them |
| Why single-hop patches but no N-hop chaining / no push notifications | This file, "Deliberately not built," below |
| Client-side consumption of the manifest (patch-vs-full resolution) | `noxos-app` — trigger-router / update logic (not built yet) |
| Full OTA design writeup | `../PROJECT.md`, "OTA distribution" section |

## How it works

`.github/workflows/publish-manifest.yml` (schedule: every 6h, + manual dispatch) → `scripts/generate-manifest.sh` → `list-s3-releases.sh` (`aws s3api list-objects-v2` on `full/` and `patches/` prefixes) piped into `build-manifest.sh` (pure jq/bash transform, parses both `full/noxos-<version>-<YYYYMMDD>-<channel>-<device>.zip` and `patches/noxos-<from>-to-<to>-<YYYYMMDD>-<channel>-<device>.patch.zip`, groups + sorts) → `docs/<device>/<channel>.json` (`{response: [...full builds...], patches: [...deltas...]}`) → GitHub Pages.

`build-manifest.sh` is deliberately network-free except for sidecar fetches per object (`.sha256`, and `.changelog.txt` for full images) — both degrade gracefully (`null`/empty) on failure rather than crashing the run, tested directly (`scripts/test-build-manifest.sh` fixture uses an unreachable base URL on purpose to exercise both degradation paths).

## Deliberately not built (unchanged from 2026-08-15's design discussion, re-confirmed 2026-08-16)

- **No patch chaining across missed versions.** Real ROM projects (LineageOS, GrapheneOS) don't do N-hop incremental chains — pre-building deltas for every version pair doesn't scale, and one failed hop mid-chain breaks the update. A device behind by more than one version re-downloads the latest full image. Single-hop patches (previous full release → latest) are real now, generated upstream in `noxos-os` — this repo just catalogs whatever patch objects exist under `patches/`.
- **No push notifications.** Client polls on a schedule instead. Push would need Firebase Cloud Messaging (conflicts with GMS-independence) or a self-hosted UnifiedPush relay — real infra this project doesn't need yet.
- **No Lambda / compute-on-request.** Considered, rejected: an update check is a static file read, not a computation. Patch *generation* is real compute, but it happens in `noxos-os`'s build pipeline, not here.

## Hosting

GitHub Pages enabled via API (`gh api -X POST repos/.../pages -f build_type=workflow`), 2026-08-15. Resolves to a custom domain already configured on this account: `https://parrothacker1.is-a.dev/noxos-server/` — not the default `github.io` URL. Manifest URLs are `https://parrothacker1.is-a.dev/noxos-server/<device>/<channel>.json`.

## Status (2026-08-16)

Transform logic rewritten for the S3-shaped input and tested against a fixture (`testdata/s3-listing.json`) — passes, verified locally too (bash/jq have no local-tooling restriction, unlike Gradle). CI green on push.

**Still nothing here has run end-to-end against real data.** No S3 bucket exists yet (Phase 1 EC2 infra hasn't been provisioned — see `../TASKS.md`), and the repo secrets/variables the workflow needs (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_DEFAULT_REGION`, `NOXOS_S3_BUCKET`, `NOXOS_S3_BASE_URL`) aren't configured — the scheduled `publish-manifest.yml` run will fail until both exist. That's expected and documented in the repo's own README, not a bug. Once the bucket + credentials exist, trigger manually: `gh workflow run publish-manifest.yml -R parrothacker1/noxos-server`.
