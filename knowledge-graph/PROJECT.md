# NoxOS

A lightweight, security-focused alternative mobile OS — B.Tech major project, solo, built with AI coding agents.

## Brief

Mobile OS alternative to Android: own app store, multiple browsers, lightweight, more secure than other OSes, positioned as a hands-on OS-building practice tool (the phased roadmap format is a nod to eXpOS, NIT Calicut's staged OS-building course). Quantum computing gets a one-line forward-looking note about crypto-agility — not a functional requirement.

This project replaced an earlier, unrelated CARE-X (healthcare AI) project entirely, per the guide.

## Architecture — three independent pillars

### 1. Lightweight

Fork AOSP (keep the Linux kernel and ART runtime as-is). Strip Google Play Services and OEM bloat at build time, trim fonts/locales to single-locale, trim kernel defconfig, tune ART compilation mode, minimal init.rc/launcher. Relative claim — "lighter than stock Android" — same as every de-Googled ROM.

### 2. Secure — the novel contribution

Android has shipped hardware-backed virtualization (AVF, pKVM hypervisor) since Android 13, but nobody has shipped a polished, user-facing feature that uses it for untrusted-content isolation:

- GrapheneOS devs publicly wanted this in 2023, still haven't shipped it (their VM Launcher app is for general-purpose Linux desktop VMs, not security-triggered content isolation)
- Mainstream sandboxing apps (Island, Shelter, GeeLark) only use work-profile/UID isolation, not pKVM
- Academic prior art (Anception, ~2014) proposed VM-based app isolation conceptually but needed a custom hypervisor — pKVM didn't exist yet
- pKVM got SESIP Level 5 certified in August 2025 — independently audited, not experimental

**Scope:** untrusted file content (downloads, sideloaded APK contents) and flagged network payloads get routed into a disposable Microdroid VM instead of parsed in the normal app process.

```
Boot VM → Isolated Payload/Parser → Validate/Scan/Parse → Return Result → Destroy VM (no persistence)
```

Ephemeral by design — nothing survives between invocations.

### 3. Observability layer

A companion "audit" app logs every isolated execution (input, output, duration, errors) and every flagged network transfer, so the security claim is demonstrable, not a black box. Built on Android's `VpnService` API for per-app traffic visibility (same mechanism NetGuard/PCAPdroid use — no root needed).

### 4. App store / OTA

GMS-independent app installation (Aurora Store-style, or microG if the real Play Store app is specifically needed — Play Integrity API will likely reject a custom build for some apps, a known documented limitation). Custom signed OTA images built with AOSP's `ota_from_target_files` tooling (`noxos-os`), published as GitHub Releases, indexed by a static manifest (`noxos-server`) rather than a self-hosted update server — see "OTA distribution" below for why that's static instead of the LineageOS/CalyxOS self-hosted-server pattern.

### OTA distribution (revised 2026-09-10 — supersedes 2026-08-16's static-only framing)

Originally scoped as a persistent self-hosted Go server, then revised to GitHub Releases + a static manifest, then to S3 + a static manifest (client resolves the update itself against a public JSON file). **Revised again 2026-09-10: the download step becomes a live signing Lambda, the manifest-generation pipeline stays static.** User's framing: the ROM sends its current version, the server figures out what comes next and hands back a signed S3 URL — deliberately kept as v1 scope (bundled multi-version updates, where a single update jumps a device from v1 straight through v3, are v2 scope, not attempted now).

- `s3://noxos-releases/full/` — periodic complete builds, for fresh installs or devices too far out of date to patch forward.
- `s3://noxos-releases/patches/` — incremental deltas between *consecutive* full releases only, generated via AOSP's `ota_from_target_files -i old.zip new.zip patch.zip`. A patch isn't a separate build artifact — it's a diff computed from two already-built target-files packages.
- **Manifest generation is unchanged**: `noxos-server`'s scheduled GitHub Action (`list-s3-releases.sh` + `build-manifest.sh`, now weekly not every 6h) still lists the bucket and builds a `{response, patches}` JSON per device/channel, published to GitHub Pages exactly as before.
- **New (drafted, not deployed): `noxos-server/lambda/ota_handler.py`.** A Lambda that reads that same manifest JSON (from S3 directly once the publish step also uploads there — not yet wired) and, given `?device=&channel=&version=`, applies the existing single-hop-patch-else-full-image resolution logic server-side instead of leaving it to the client, then returns a **presigned S3 URL** (1h expiry) for the one file the device should download next. The device applies it, then calls again with its new version to get the next hop — sequential, not bundled. Pure resolution logic (`resolve_update`) is unit-tested with plain asserts (`lambda/test_ota_handler.py`, passes in an isolated venv since boto3 isn't installed system-wide here — it ships built into the Lambda Python runtime itself, so the real deploy needs zero dependency packaging).
- **Still not deployed, deliberately** — no IAM role, no Function URL, no manifest→S3 publish step, no bucket-policy change yet. User: keep it drafted/committed, revisit once a real v1 build exists to actually test end-to-end against. When it is deployed, the bucket's current public `GetObject` policy on `full/`/`patches/` should be reconsidered — presigned URLs only mean something if the objects aren't already publicly readable without one.
- **Still no N-hop patch chaining across multiple missed versions** in v1 — a device more than one release behind gets the full image, same as before. N-hop / bundled chaining is explicitly v2 scope now (see above), not a "maybe never" — this is the first time it's been scoped as a real future phase rather than a permanent non-feature.
- **No push notifications** — client polls (now calls the Lambda) on its own schedule instead of FCM (conflicts with GMS-independence) or a self-hosted UnifiedPush relay.
- **CDN in front of S3** — explicitly deferred, not v1 scope, user's own call ("not right now").
- Signing stays self-controlled regardless of hosting — the "we don't trust Google's OTA channel" claim lives in who holds the keys, not in running custom server infra. A presigned URL is signed with those same self-controlled credentials, not a third party's.

## Full architecture diagram

```
Host OS:
  Untrusted File (download/share/sideload) ─┐
  App Network Traffic → VPNService Monitor ──┼─→ Host Trigger/Router
                                              ↓
Microdroid pVM (ephemeral):
  Boot VM → Isolated Payload/Parser → Validate/Scan/Parse → Return Result → Destroy VM
                                              ↓                    ↓
                              Sanitized Result → Requesting App    Audit & Observability App
                                                                   (execution + traffic logs)
```

## Threat analysis (app-side + dispatch loop shipped 2026-09-12; explainability + session-scoping + file-side design added 2026-09-13; real classifier + service shipped 2026-09-13; hosting + real explainability text still open)

Extends pillar 3 (Observability) from passive logging toward an actual verdict on flagged traffic and files, without turning this into a general malware-detonation engine (that scope boundary from pillar 2 still holds) or a payload-inspecting MITM proxy (would conflict with the "we don't trust interception" trust model this whole project is built around).

- **ACL, not just a blocklist.** `noxos-app`'s `blocked_hosts` became a real 3-state ACL (`ALLOWED`/`BLOCKED`/`FLAGGED`) — shipped. A destination with no entry gets flagged once ("pending analysis") the first time it's seen; `BLOCKED` still drops the flow, `FLAGGED`/`ALLOWED` don't. The ACL self-updates from two sources: an eventual AI verdict (writes `ALLOWED`/`BLOCKED` back once analysis resolves a flag), and later, optionally, an external threat-intel feed as a cheap first-pass seed — both decided, only the AI side has anywhere to write to yet since no model exists.
- **Cost gating is structural, not a rate limiter bolted on.** Analyzing every packet was explicitly ruled out (user's own concern) — the unit of analysis is one verdict per *destination*, cached in the ACL, so a never-before-seen host is asked about once, ever, not once per connection or per packet.
- **What would actually get sent to a model: metadata, not payload.** Destination IP/port, SNI/domain (readable from a TLS ClientHello even though the rest is encrypted), volume/frequency, requesting app, ASN/geo. Not raw packet payload — almost everything on-device is TLS today, so payload inspection buys nothing without MITM, which was deliberately ruled out as out of scope (see above).
- **Where inference runs: hybrid, local pre-filter first.** Cheap local heuristics/the ACL itself handle the vast majority; only a genuinely new-and-ambiguous destination would ever reach the model. The model itself: **self-hosted on EC2, not a cloud LLM API** — user's explicit call, "find a pretrained model or train one." Recommended approach (not yet built): a classical gradient-boosted classifier (XGBoost/LightGBM) trained on a public labeled flow-intrusion dataset (CICIDS2017/2018 or UNSW-NB15 — the standard ones for exactly this task), not an LLM — cheaper to host (CPU-only, no GPU), faster per-call, and the right tool for structured flow-metadata classification. **File-side analysis is a separate problem, not the same model**: ClamAV (signature-based, free, self-hostable on the same box) recommended as the first pass, since Warden receives APKs/images/docs, not the Windows-executable-shaped inputs most ML malware-classifier research (e.g. EMBER) targets.
- **File-scan trigger surface widened to match**: no longer just the manual "Select & Scan" button — a `MediaStore.Downloads` watcher (`FileArrivalWatcher`, shipped 2026-09-10) auto-triggers a scan for anything landing there, covering SD-card-copy/Bluetooth/Wi-Fi-share without per-transport integration code.
- **User-facing opt-out, now two independent ones (2026-09-13, user's explicit ask)**: "AI analysis of network traffic" and "AI analysis of files" are separate Settings toggles, each default-on. Turning network off means destinations never get flagged as pending in the first place; the file one is wired (setting exists, default true) but has nothing to gate yet since no file-side AI pipeline is built (see below) — added now so the toggle exists before the feature does, not after.
- **Explainability (2026-09-13, user's explicit ask): the model's response carries `reasoning` (free text) and `safety_score` (float) alongside `verdict`, not just a bare allow/block.** `AnalysisDispatcher` parses both and writes the real reasoning text into the ACL entry's `reason` field (prefixed `ai:`) instead of a generic placeholder — the ACL screen shows it directly, plus the safety score as a percentage. **Open reconciliation point, not yet resolved with `noxos-inference`**: `noxos-app`'s convention is "higher `safety_score` = safer" (a 0.02 score paired with a `block` verdict in its own tests). `noxos-inference`'s in-progress model (see its own `TASKS.md`) naturally outputs an *attack probability* (its own documented threshold scheme is `<0.4` allow / `0.4–0.6` uncertain / `>0.6` block — higher means *more* dangerous, the opposite polarity). Someone has to invert one side before these two independently-built pieces actually agree — flagged here for whoever picks up `noxos-inference`'s `service/app.py` next, not silently assumed either way.
- **Session-scoped trust for AI verdicts (2026-09-13, user's explicit ask): an AI-resolved verdict is remembered only for the network-monitoring session it was resolved in, then forgotten.** `AclEntity` gained a `sessionOnly: Boolean` field; `NetMonitorService.startMonitor()` calls a new `AclRepository.clearSessionVerdicts(NETWORK)` at the start of every session, deleting only AI-written entries (`sessionOnly = true`) — user-set and seeded entries are untouched, permanent as before. Deliberate freshness-over-permanence tradeoff: a host judged safe today isn't trusted forever without being asked about again, at the cost of re-asking the model once per destination per session instead of once ever. Not yet extended to files (no file-side AI verdicts exist yet to scope this way).
- **One deployment, not two — boot flags select capability (2026-09-13, user's explicit ask, not yet built).** `noxos-inference` should stay a single service exposing both `/analyze/network` and `/analyze/file`, with a boot-time flag/env var to run in network-only, file-only, or both mode if a deployment ever needs to split them — not two separate EC2 boxes/deployments. Purely a `noxos-inference`-side infra detail; nothing on the `noxos-app` side depends on how this is implemented.
- **File-side design, sketched 2026-09-13, deliberately not built yet ("we haven't decided much" — user's own words, this is the starting point, not the final word):**
  - A **cheap filter runs inside the Microdroid pVM itself**, alongside the existing parse/scan — not a separate host-side pass. Candidate checks: declared-extension vs. actual magic-header mismatch, size sanity. This means `noxos-payload`'s native parser needs to emit a flagged+reason signal alongside its existing parse result, and the host↔guest `VmPayloadProtocol` needs a field to carry it back — cross-repo work, tracked as a pointer in `noxos-payload/TASKS.md`, not started.
  - A file the cheap filter flags is **held (not delivered to the requesting app) and escalated to `/analyze/file`** — this is the trigger model: files reach the AI endpoint because the phone-side filter flagged them, not "every file, always." Matters for `noxos-inference`'s capacity planning — real volume will be much lower than "every scanned file."
  - **The user can force-allow a held file anyway** — an explicit override action, not yet built (no UI, no backing "held" file state exists — `TriggerRouter.scanFile()` currently only returns Success/Failure/Error, there's no "blocked pending override" outcome). Don't build the override UI before the hold mechanism it overrides exists.
  - `/analyze/file` needs **real file bytes**, not metadata-only — already independently discovered and documented on the `noxos-inference` side (ClamAV's signature matching needs actual bytes; a hash alone isn't a scan). Consistent with this plan, not a conflict.
- **Status (updated 2026-09-13, session 13)**: the app-side pieces (ACL with kind/priority, auto-flagging, seed list, file-arrival watching + per-source trust, both opt-outs, explainability fields, session-scoped forgetting) are shipped on `noxos-app` `main` and verified live. **`noxos-inference` now has a real trained model and a real service**: a real XGBoost classifier trained on UNSW-NB15 (95.75% accuracy, 0.969 F1 on a held-out split), served via a real FastAPI app (`POST /analyze/network`, `POST /analyze/file` via a real ClamAV client, a boot-flag for network-only/file-only/both deployments), committed and pushed. The safety-score polarity question above is **resolved** — inverted at the API boundary (`safety_score = 1 - attack_probability`), matching `noxos-app`'s convention. `reasoning` is still always `null` — real explainability text is the one deliberately deferred piece, next up. **What's still genuinely open**: no live EC2 endpoint (scripts ready, nothing launched — a real money decision, not made without the user); `service/clamav_client.py`'s actual scan-result parsing has never been exercised against a live `clamd`; the file-side design (cheap in-pVM filter, held-file+override, `/analyze/file`'s app-side caller) is still a plan, not code.

## Key technical decisions

- **Target platform: Cuttlefish** (`aosp_cf_x86_64_phone` or `aosp_cf_arm64_phone`), not physical hardware — no phone available. Full AVF/Microdroid stack, but only **non-protected** mode (no hardware root-of-trust). Stated explicitly as a scope boundary, not hidden — also literally how Google develops/tests AVF before hardware deployment.
- **Protected pKVM** (hardware-backed guarantee) requires Pixel 6+ — out of scope unless real hardware is acquired later.
- **Don't build a general malware-detonation engine.** Scope to one payload type end-to-end (e.g. image EXIF parsing) rather than general-purpose analysis — that's Cuckoo Sandbox's job.
- **Federated learning / heavy DP: cut.** Same "don't fake a multi-institution setup with one dataset" logic as the CARE-X pivot, if anything FL-flavored ever comes up.
- **No app repo contains the AOSP source itself** — referenced via a `repo` tool local manifest, same as every real custom ROM project.

## Infra / build pipeline

**Revised 2026-08-31 — Cuttlefish moved off AWS entirely, one-box plan.** Supersedes 2026-08-16's two-instance split (`m8i.xlarge` Gradle+Cuttlefish box + `m5.4xlarge`/`r5.2xlarge` ROM-compile box). The M8i/R8i/C8i nested-KVM requirement no longer applies to anything in this project's AWS footprint — kept below only as a dead end worth remembering (don't re-derive it from scratch if it comes up again).

- **AWS now hosts exactly one instance, for AOSP compilation only: `r5.2xlarge` (8 vCPU, 64GB RAM), spot, `us-east-1`.** 64GB matches Google's official AOSP-build recommendation and avoids Soong's dependency-analysis OOM wall — not negotiable down. Spot ~$0.15/hr, on-demand-equivalent ~$0.50/hr. No nested virtualization needed here — this box only compiles, it never runs Cuttlefish.
- **IAM: least-privilege, scoped to what this one instance actually does** — EC2 spot request/run/stop, and access limited to its own EBS volume/snapshots. No broader permissions assumed or requested.
- **Persistence model: EBS snapshot-and-restore, not an always-on volume.** Snapshot the gp3 volume (~400GB) before tearing the instance/volume down at the end of a session; restore a fresh volume from that snapshot to resume. Snapshots are block-level, so file timestamps survive exactly — this is what makes ninja's incremental build cache resume correctly. **Deliberately not** a manual tar-to-S3/archive-extract workflow — that path risks silently rewriting timestamps and forcing spurious full rebuilds, which would quietly defeat the entire point of the persistence step. No automation for the snapshot/restore cycle exists yet — real work, not assumed done.
- **Cuttlefish runs locally now, not on AWS** — on the user's Arch Linux laptop, bare-metal KVM, no nesting involved. `noxos-os`'s CI only needs to produce `m dist` image output; a human copies it to the laptop for local Cuttlefish testing. Local setup uses Google's official [`google/android-cuttlefish`](https://github.com/google/android-cuttlefish) Docker container with host `/dev/kvm` + `/dev/net/tun` mapped in (bypassing Arch Linux packaging issues). Automated via [`noxos-os/infra/setup-cuttlefish-local.sh`](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/noxos-os/infra/setup-cuttlefish-local.sh) (see [`knowledge-graph/noxos-os/CUTTLEFISH.md`](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/knowledge-graph/noxos-os/CUTTLEFISH.md)).
- **GitHub Actions split:** hosted runners (free) for everything except the AOSP compile — app builds/tests, native payload unit tests, canary/privacy test scripts, doc generation. A self-hosted runner on the `r5.2xlarge` box handles `repo sync` + `m dist` only; it does not run Cuttlefish or any AVF integration test (those move to the local laptop, outside CI, for now).
- **Output size is unmeasured — decide the host once it's known, not before.** GitHub Releases caps a single asset at 2GB; whether a bloat-stripped `m dist` bundle fits under that is unverified. Measure with `ls -lh` after the first real build. S3 stays reserved for OTA specifically (already wired in `noxos-server`) and isn't the default answer here just because it exists.
- Cuttlefish host requirement (laptop, not AWS): Linux, VT-x/AMD-V enabled at the BIOS/hypervisor level — Arch satisfies this; the `android-cuttlefish` tooling is the open friction point, not the kernel/CPU support.

### Cross-repo integration points (not yet built, don't build in isolation)

- **jniLibs handoff:** `noxos-payload`'s Soong-built native `.so` has to land in `noxos-app`'s `app/src/main/jniLibs/<abi>/` before a release build can embed it. No mechanism copies it there yet — this is real work, not a config toggle. See `TASKS.md` backlog for the existing `libnoxos_payload_stub.so` naming this depends on matching.
- **Warden as a priv-app requires all three of the following together, or the permission grant silently fails** — this only happens at the `noxos-os` build level, never at the app level:
  1. Placement in `/system/priv-app/`, not `/system/app/`.
  2. A `privapp-permissions-<name>.xml` in `/system/etc/permissions/` explicitly naming Warden's package and listing `MANAGE_VIRTUAL_MACHINE` (plus any other AVF permissions it ends up needing).
  3. Platform-signed, matching whatever key `noxos-os` signs the build with.

  `MANAGE_VIRTUAL_MACHINE` is `signature|privileged` — categorically ungrantable to a sideloaded app, full stop. This is why Phase 2's "is `MANAGE_VIRTUAL_MACHINE` alone sufficient" open question (see `TASKS.md`) already has its answer: no, it isn't, regardless of what Cuttlefish/adb-install testing might have suggested — the real answer requires OS-level integration, tracked as its own phase below.

## Repos

1. **`noxos-os`** (this repo) — AOSP customization: local manifest, build config patches, `/infra` (spot instance scripts), CI workflow triggering compiles on the self-hosted runner.
2. **`noxos-payload`** — native isolated payload running inside Microdroid (`AVmPayload_main()`, file parsers). Separate repo deliberately — its history is the audit trail for everything ever executed inside the trust boundary.
3. **`noxos-app`** — host-side Android app, multi-module Gradle: Host Trigger/Router, VpnService network monitor, Audit & Observability UI. Free GitHub-hosted runners only.
4. **`noxos-server`** — static OTA manifest publisher, plus a drafted-but-undeployed Lambda that signs download URLs per-device on request — see "OTA distribution" below.

## Roadmap — 14 phases, 5 parts

- **Part I — Preparatory:** P1 build environment/toolchain setup, P2 prove the AVF/Microdroid pipeline works using Google's reference demo before custom code.
- **Part II — Lightweight base:** P3 strip GMS/bloat, P4 trim fonts/locale/kernel, P5 ART/init tuning.
- **Part III — Isolation architecture (core work):** P6 minimal custom payload in a VM, P7 real untrusted-file parser + adversarial test, P8 host-side auto-trigger/routing, P9 observability/audit app, P10 network traffic visibility + correlation.
- **Part IV — Distribution:** P11 app store integration, P12 custom OTA channel.
- **Part V — Final integration:** P13 end-to-end demo, P14 documentation.

## Current status

Literature survey and architectural roadmap delivered to the guide. Nothing implemented yet. Next step: **Phase 1** — get the build environment running and an unmodified Cuttlefish image compiling and booting, before any custom code.
