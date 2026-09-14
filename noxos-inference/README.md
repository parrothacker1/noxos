# noxos-inference

**Python (FastAPI) + a gradient-boosted-tree model + ClamAV** — the self-hosted threat-analysis backend `noxos-app`'s `AclRepository.nextAnalysisBatch()` feeds. Created 2026-09-12; the newest and least-built-out of the five repos in this project.

Two unrelated problems behind one small service, not one model wearing two hats:

- **Network traffic** (`POST /analyze/network`) — a gradient-boosted classifier (XGBoost/LightGBM), not an LLM. Trained on flow metadata (destination IP/port, protocol, volume, frequency) — cheaper to host (CPU-only, no GPU) and the right tool for structured flow-metadata classification, not a job for a language model.
- **Files** (`POST /analyze/file`) — ClamAV, signature-based. Most ML malware-classifier research (e.g. EMBER) targets Windows PE executables — Warden receives APKs/images/docs, a poor fit for that research.

Never sees raw packet payload or file contents beyond what ClamAV needs — almost everything on-device is TLS today, so payload inspection buys nothing without MITM, which is explicitly out of scope for this OS's trust model (see `../PROJECT.md`).

## Cross-project pointers

| Need to know… | Go to |
|---|---|
| The `noxos-app` code that calls this service (`AnalysisDispatcher`, Settings UI for endpoint/API key) | [`../noxos-app/TASKS.md`](../noxos-app/TASKS.md) |
| The cost-gating mechanism that limits how often this service actually gets called | `noxos-app`'s `AclRepository.nextAnalysisBatch()` — one verdict per destination, ever, not per packet or per connection |
| Full architecture/design rationale (why XGBoost not an LLM, why metadata-only, why self-hosted not a cloud API) | `../PROJECT.md`, "Threat analysis" section |
| Session-by-session log of what's actually been built/tested/deferred here | [`TASKS.md`](TASKS.md) |

## Intended layout (per this repo's own README — see status below for what actually exists)

- `training/` — dataset prep + model training, produces the artifact `service/` serves.
- `service/` — FastAPI app: `POST /analyze/network`, `POST /analyze/file`.
- `infra/` — EC2 deploy scripts for the self-hosted inference box (`us-east-1`, no IAM role needed — see `infra/README.md`).
- `tests/` — real tests against the trained model and the live service, intended to not be decorative.

## Infra design, already decided

- Single `t3.micro`, on-demand, `us-east-1` (same account as `noxos-os`'s compile fleet, `<AWS_ACCOUNT_ID>`) — **no fleet, no spot, no snapshot/restore machinery**. That exists in `noxos-os` because AOSP compiles run for hours and can't restart cheaply; this box is stateless and cheap enough (~$7.50/mo) that a fresh instance booting the same systemd unit off this public repo, with nothing to lose, is the whole recovery story.
- **Deliberately no IAM role** — the box makes zero AWS API calls (public `git clone` over HTTPS, no S3). If a future version needs S3 (training data, model pulls), scope a new dedicated least-privilege role then — don't reuse `noxos-rom-compile-role`.
- **Known, flagged gap: no TLS.** Plaintext HTTP + a shared bearer token (`NOXOS_INFERENCE_API_KEY`). No domain exists yet to get a real cert against. This is also why `noxos-app` had to add `android:usesCleartextTraffic="true"` to its manifest — see [`../noxos-app/TASKS.md`](../noxos-app/TASKS.md) session 11. Fix before this carries real traffic, not before.

## Known gaps, deliberately not closed yet

- **Feature-schema mismatch with what Warden actually persists.** `AclEntry` (what `nextAnalysisBatch()` returns) only carries `subject` (IP), `priority`, `reason`, `updatedAtEpochMillis` — no port/protocol/volume/frequency/requesting-app, even though flow-intrusion datasets (CICIDS/UNSW-NB15) are typically trained on that richer per-flow shape. `noxos-app`'s `AnalysisDispatcher` currently sends only what's real. Resolve by either (a) treating unknown-destination scoring as IP/ASN-reputation-style rather than a full per-flow IDS, or (b) extending `AclEntity` in `noxos-app` to persist lightweight per-destination flow stats (cheap schema bump — `fallbackToDestructiveMigration()` is already in place) once it's clear the model actually needs those fields. Don't do (b) speculatively, before that's known.
- **ClamAV path is unverified against a live `clamd`** — built for real (`service/clamav_client.py`, per this repo's own plan), but no dev box here has ClamAV installed, so it's only ever been exercised (if at all) against the EC2 box's own `clamd`. Check [`TASKS.md`](TASKS.md) for the actual current verification status before assuming it works.
- **`reasoning` is always `null`** in `/analyze/network`'s response — `safety_score` is real, `reasoning` (real explainability text) is deliberately deferred, the last piece of the original plan left to build. See `TASKS.md` session 13.

## Status (2026-09-13, session 13)

Repo scaffolded and wired into the root `NoxOS` meta-repo as a submodule. `infra/` has real, reviewed deploy scripts but **nothing has been launched** — no live EC2 instance. **`training/` and `service/` are real now**: a real XGBoost classifier trained on UNSW-NB15 (95.75% accuracy, 0.969 F1, held-out split), a real FastAPI service (`service/app.py`) serving both endpoints with a boot-flag deployment mode, a real ClamAV client (never tested against a live `clamd`), 10 real passing tests, committed and pushed (signed). The `noxos-app` side that calls this service is built, tested, and verified end-to-end — against a throwaway stand-in responder, not yet against this repo's real (still undeployed) service. See [`TASKS.md`](TASKS.md) for the full session log.
