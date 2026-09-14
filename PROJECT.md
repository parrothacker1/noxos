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

## Threat analysis (app-side + dispatch loop shipped 2026-09-12; explainability + session-scoping + file-side design added 2026-09-13; real classifier + service shipped 2026-09-13; file-side quarantine decided and network-side pKVM + on-device-classifier architecture designed 2026-09-13; hosting + real explainability text still open)

Extends pillar 3 (Observability) from passive logging toward an actual verdict on flagged traffic and files, without turning this into a general malware-detonation engine (that scope boundary from pillar 2 still holds) or a payload-inspecting MITM proxy (would conflict with the "we don't trust interception" trust model this whole project is built around).

- **ACL, not just a blocklist.** `noxos-app`'s `blocked_hosts` became a real 3-state ACL (`ALLOWED`/`BLOCKED`/`FLAGGED`) — shipped. A destination with no entry gets flagged once ("pending analysis") the first time it's seen; `BLOCKED` still drops the flow, `FLAGGED`/`ALLOWED` don't. The ACL self-updates from two sources: an eventual AI verdict (writes `ALLOWED`/`BLOCKED` back once analysis resolves a flag), and later, optionally, an external threat-intel feed as a cheap first-pass seed — both decided, only the AI side has anywhere to write to yet since no model exists.
- **Cost gating is structural, not a rate limiter bolted on.** Analyzing every packet was explicitly ruled out (user's own concern) — the unit of analysis is one verdict per *destination*, cached in the ACL, so a never-before-seen host is asked about once, ever, not once per connection or per packet.
- **What would actually get sent to a model: metadata, not payload.** Destination IP/port, SNI/domain (readable from a TLS ClientHello even though the rest is encrypted), volume/frequency, requesting app, ASN/geo. Not raw packet payload — almost everything on-device is TLS today, so payload inspection buys nothing without MITM, which was deliberately ruled out as out of scope (see above).
- **Where inference runs: hybrid, local pre-filter first.** Cheap local heuristics/the ACL itself handle the vast majority; only a genuinely new-and-ambiguous destination would ever reach the model. The model itself: **self-hosted on EC2, not a cloud LLM API** — user's explicit call, "find a pretrained model or train one." A classical gradient-boosted classifier (XGBoost) trained on UNSW-NB15 — cheaper to host (CPU-only, no GPU), faster per-call, and the right tool for structured flow-metadata classification, not an LLM — is now real (see Status below). **File-side analysis is a separate problem, not the same model**: ClamAV (signature-based, free, self-hostable on the same box) is the first pass, since Warden receives APKs/images/docs, not the Windows-executable-shaped inputs most ML malware-classifier research (e.g. EMBER) targets. **Revised 2026-09-13** — see the "Network-side pKVM-gated cheap filter" bullet below: the "local pre-filter" for network traffic is being extended from just the ACL into an actual isolated cheap-filter stage, and the trained model itself is now planned to run on-device rather than only behind the EC2 call.
- **File-scan trigger surface widened to match**: no longer just the manual "Select & Scan" button — a `MediaStore.Downloads` watcher (`FileArrivalWatcher`, shipped 2026-09-10) auto-triggers a scan for anything landing there, covering SD-card-copy/Bluetooth/Wi-Fi-share without per-transport integration code.
- **User-facing opt-out, now two independent ones (2026-09-13, user's explicit ask)**: "AI analysis of network traffic" and "AI analysis of files" are separate Settings toggles, each default-on. Turning network off means destinations never get flagged as pending in the first place; the file one is wired (setting exists, default true) but has nothing to gate yet since no file-side AI pipeline is built (see below) — added now so the toggle exists before the feature does, not after.
- **Explainability (2026-09-13, user's explicit ask): the model's response carries `reasoning` (free text) and `safety_score` (float) alongside `verdict`, not just a bare allow/block.** `AnalysisDispatcher` parses both and writes the real reasoning text into the ACL entry's `reason` field (prefixed `ai:`) instead of a generic placeholder — the ACL screen shows it directly, plus the safety score as a percentage. **Polarity — resolved** (see Status below): inverted at the API boundary, `noxos-app`'s "higher = safer" convention wins on the wire. **Scope of `reasoning` — resolved 2026-09-13**: it explains the verdict in both directions, "safe because X" as much as "unsafe because Y," for both `/analyze/network` and `/analyze/file` — not just a threat explanation when blocking. Still `null` in the real service today; this only settles what it should say once built.
- **Session-scoped trust for AI verdicts (2026-09-13, user's explicit ask): an AI-resolved verdict is remembered only for the network-monitoring session it was resolved in, then forgotten.** `AclEntity` gained a `sessionOnly: Boolean` field; `NetMonitorService.startMonitor()` calls a new `AclRepository.clearSessionVerdicts(NETWORK)` at the start of every session, deleting only AI-written entries (`sessionOnly = true`) — user-set and seeded entries are untouched, permanent as before. Deliberate freshness-over-permanence tradeoff: a host judged safe today isn't trusted forever without being asked about again, at the cost of re-asking the model once per destination per session instead of once ever. Not yet extended to files (no file-side AI verdicts exist yet to scope this way).
- **One deployment, not two — boot flags select capability (2026-09-13, user's explicit ask, not yet built).** `noxos-inference` should stay a single service exposing both `/analyze/network` and `/analyze/file`, with a boot-time flag/env var to run in network-only, file-only, or both mode if a deployment ever needs to split them — not two separate EC2 boxes/deployments. Purely a `noxos-inference`-side infra detail; nothing on the `noxos-app` side depends on how this is implemented.
- **File-side design, decided 2026-09-13 (extends the original sketch into an actual v1 shape — not built yet):**
  - A **cheap filter runs inside the Microdroid pVM itself**, alongside the existing parse/scan — not a separate host-side pass. Candidate checks: declared-extension vs. actual magic-header mismatch, size sanity. This means `noxos-payload`'s native parser needs to emit a flagged+reason signal alongside its existing parse result, and the host↔guest `VmPayloadProtocol` needs a field to carry it back — cross-repo work, tracked as a pointer in `noxos-payload/TASKS.md`. **Built 2026-09-14** — see that file's session 5 for what the check actually turned out to test (the "declared-extension" framing doesn't translate literally since no extension crosses the wire; reinterpreted as embedded-foreign-magic + scan-data size sanity).
  - A file the cheap filter flags is **held and escalated to `/analyze/file`, on both trigger paths, and both need to actually withhold access, not just log a flag.** Manual scan (SAF picker) never delivers a `Success` outcome to the requesting flow anyway, so holding is just returning a new `ScanResult.Held` instead — no new capability needed there. **Auto-scan (`FileArrivalWatcher` on Downloads) needs real quarantine** (decided as v1 scope 2026-09-13, not the advisory-only-flag fallback originally considered): the flagged file gets physically moved out of `MediaStore.Downloads` into app-private storage the moment the watcher's cheap-filter flag comes back, and restored to its original location only on a force-allow. Real, non-trivial work — `noxos-app` already holds `MANAGE_EXTERNAL_STORAGE`, so it's possible, but the move/restore logic doesn't exist yet. Matters for `noxos-inference`'s capacity planning — real volume will be much lower than "every scanned file."
  - **The user can force-allow a held file anyway** — an explicit override action, not yet built. For the manual-scan path this means resuming delivery of the already-decoded result; for the auto-scan/quarantine path it means moving the file back from app-private storage to its original `Downloads` location. No UI, no backing "held" state, no move/restore logic exist yet — don't build the override UI before the hold+quarantine mechanism it overrides exists.
  - `/analyze/file` needs **real file bytes**, not metadata-only — already independently discovered and documented on the `noxos-inference` side (ClamAV's signature matching needs actual bytes; a hash alone isn't a scan). Consistent with this plan, not a conflict.
  - **Retention, decided 2026-09-13**: a quarantined file isn't held forever — a **user-configurable retention period** governs it, mirroring `WardenSettingsRepository`'s existing audit-log retention dropdown (30/90/180/365 days) rather than inventing a new settings pattern. Not built yet; the exact action once retention expires (delete, most likely) wasn't spelled out beyond "not indefinite."
- **Network-side pKVM-gated cheap filter + on-device classification, designed 2026-09-13 (user's explicit design session, not yet built) — extends the same isolated-parsing idea from files to network packets, closing a real asymmetry.** `PacketUtils`/`TcpRelayManager` parse network-controlled bytes directly in the host process today, completely unisolated — the same class of risk the EXIF parser's real fuzzing-found heap overflow demonstrated on the file side, never checked for on the network side. Per-packet VM routing isn't viable (vsock/boot overhead vs. line-rate relay, and a long-lived VM session would break the ephemeral-by-design invariant), so this reuses the **existing per-destination cost gate rather than adding a new one**: live relay stays host-side and unchanged; only when the ACL flags a destination as genuinely new (as it already does today, once, ever) does a background dispatcher open a **one-shot Microdroid VM** with a small sample of that flow's raw packets — the same `TriggerRouter`→vsock→destroy shape the file path already uses, run asynchronously so the live relay for that flow is never blocked on it.
  - `noxos-payload` gains a **second task type in the same payload binary** (dispatched via the VM config's `task.type`/`command`, not a separate `.so` — one audit trail, one build target, reuses the already-fuzzed vsock plumbing) that runs a cheap header-sanity/protocol-conformance check on the sample — the network-side equivalent of the file path's magic-header-vs-declared-type check.
  - **A clean VM result resolves the destination without ever calling the AI classifier** — only a VM-flagged sample escalates further, keeping the common (benign) case cheap. **Detail decided 2026-09-13**: this clean-result resolution writes a real `ALLOWED` ACL entry, **session-scoped** (`sessionOnly = true`, same convention as an AI-resolved verdict — cleared by `AclRepository.clearSessionVerdicts(NETWORK)` at the start of the next monitoring session, not trusted permanently just because the VM check was clean once), and it gets a **real audit-log entry**, same as any other outcome — a clean result is still a real, storable event, not a silent no-op just because nothing was wrong.
  - **The escalation target is now planned as an on-device classifier, not (only) the cloud `/analyze/network` call.** `noxos-inference`'s real trained XGBoost model (see Status below) gets dumped to its native tree-ensemble JSON, evaluated by a hand-rolled Kotlin tree interpreter in `netmonitor` — deliberately no new ML-runtime dependency (TFLite/ONNX Mobile were considered and rejected: a boosted-tree ensemble doesn't need one, and this codebase has consistently hand-rolled rather than added a dependency for exactly this shape of problem, e.g. the TCP relay). **Reversed 2026-09-14**: the model is explicitly *not* a bundled `noxos-app` asset any more (it briefly was, session 20, `63d9f9e`) — see the "on-device model is now load-only, no bundled fallback" entry in `noxos-app/TASKS.md` session 21 for the full architecture change (monitoring itself now refuses to start at all until a real model has been fetched from `BuildConfig.MODEL_MANIFEST_URL` and verified; there is no local-first-launch fallback path any more, by design).
  - **Partially resolved 2026-09-13**: the live EC2 endpoint is confirmed staying (deployed for real, see the "Resolved" block after the pipeline diagrams below) — files stay server-side regardless, ClamAV isn't a phone-side proposition. **Still open**: whether EC2 is the primary resolution step (on-device classifier layered on top later) or the on-device model is primary with EC2 as fallback/refresh — not pinned down yet, check the "Resolved" block below before assuming either shape.
  - Also reopens the previously-deferred `AclEntity` schema question from a different angle: an on-device classifier needs richer per-flow features (port/protocol/volume/frequency) than `AclEntity` was last confirmed to persist, and `NetMonitorService`'s capture loop already sees those live — computing them on-device to feed a local model is a more natural fit than the original plan of serializing them into an HTTP payload, which makes this extension less speculative than it was when only the cloud path existed. **Status as of 2026-09-13 (session 15): partially built.** `AclEntity`/`AclEntry` gained `destPort`/`protocol` (schema v7, captured once at flag time) — a real, honest first slice. **Volume/frequency (running packet-count/byte-count counters) deliberately still not built** — a per-packet DB write for every packet to a still-flagged destination was judged not worth the self-DoS risk this project's ACL design has repeatedly guarded against; needs a batched/rate-limited writer first, see `../noxos-inference/TASKS.md`'s model-export contract section for the full honest state of this gap.
- **Status (updated 2026-09-13, session 15)**: the app-side pieces (ACL with kind/priority, auto-flagging, seed list, file-arrival watching + per-source trust, both opt-outs, explainability fields, session-scoped forgetting) are shipped on `noxos-app` `main` and verified live. **`noxos-inference` now has a real trained model and a real service**: a real XGBoost classifier trained on UNSW-NB15 (95.75% accuracy, 0.969 F1 on a held-out split), served via a real FastAPI app (`POST /analyze/network`, `POST /analyze/file` via a real ClamAV client, a boot-flag for network-only/file-only/both deployments), committed and pushed. The safety-score polarity question above is **resolved** — inverted at the API boundary (`safety_score = 1 - attack_probability`), matching `noxos-app`'s convention. `reasoning` is still always `null` — real explainability text is the one deliberately deferred piece, next up, and now scoped to explain the verdict in both directions (see the "Resolved 2026-09-13" block after the pipeline diagrams below), not just blocks. **`noxos-app`'s own side of both cross-repo integration points is now real and CI-tested (session 15, commit `56ff09d`), not just designed**: real file quarantine (session 14, physical move + force-allow + retention, triggered on real parser-detected `Failure` *and* now on a cheap-filter-flagged response too), `VmPayloadProtocol` gained a task-type byte so one payload binary can serve file-scan and network-sample requests, `TriggerRouter` treats a cheap-filter-flagged file response as a real quarantine trigger, a new `NetworkSampleVmDispatcher` implements the pKVM-cheap-filter-ahead-of-AI sequencing for real (clean → real session-scoped `ALLOWED`, flagged → escalates to the existing AI dispatcher), and a new `OnDeviceNetworkClassifier` (hand-rolled tree interpreter, tested against a synthetic model) is ready to consume whatever `noxos-inference`'s future export step produces. Exact wire/JSON contracts for both are now written out in `../noxos-payload/TASKS.md` and `../noxos-inference/TASKS.md` — **`noxos-payload` and `noxos-inference` can build against those directly, no further coordination through this repo needed for the contract shape itself.** **What's still genuinely open**: EC2 deployment is now a decided next step, not launched yet; `service/clamav_client.py`'s actual scan-result parsing has never been exercised against a live `clamd`; `noxos-payload` now implements both guest-side checks (session 5, 2026-09-14) — file cheap filter (embedded-foreign-magic + scan-data size sanity) and network cheap filter (IPv4 header-sanity/protocol-conformance), both unit- and fuzz-tested against plain `clang++`, not yet exercised against a real Microdroid guest (still Phase-2-gated, same as the rest of the VM code — see `noxos-payload/TASKS.md` session 5 for detail); `noxos-inference` hasn't built the tree-JSON export step yet; the on-device classifier is deliberately **not wired into the live dispatch pipeline** since primary-vs-secondary (on-device vs. EC2) is still an open user decision, not a code gap; volume/frequency per-flow counters remain deliberately unbuilt (see above).
- **Session 18 (2026-09-13): all of the above tested live on a real Cuttlefish device for the first time, four real bugs found and fixed, `v2.0.0` released.** Confirmed hard blocker: `MANAGE_VIRTUAL_MACHINE` is signature-level — no real VM path works on any non-priv-app install, regardless of what `noxos-payload`/`noxos-inference` ship (tracked in `noxos-os/TASKS.md` Phase 1c, not a code gap here). Real user decision: quarantine now triggers on *any* non-`Success` scan outcome, not just a parser-confirmed failure — an explicit fail-closed choice given the permission gap above, so every auto-scanned file gets quarantined today, on purpose. Also confirmed and fixed: force-allow was silently broken since session 14 (a restored file was immediately re-detected and re-quarantined) — now genuinely works, verified live. Full detail: `noxos-app/TASKS.md` session 18, `discussions.md` item 10.

**Addendum, 2026-09-13, from a real data/code deep-dive (see `discussions.md` for full reasoning) — three decisions, two now built:**
- **Built, session 17 (`noxos-app` commit `bcfda8e`)**: the real serving bug is fixed — `AnalysisDispatcher` now maps its captured protocol to the model's actual lowercase `proto` vocabulary (`"tcp"`/`"udp"`, `"OTHER"`/ICMP omitted rather than sent as an invalid category) instead of sending nothing at all (the bug report's own description of what was being sent turned out not to match the real code when checked — worth remembering that even a careful deep-dive can mis-describe code it didn't directly execute against).
- **Built, session 17**: Warden now captures destination-side (inbound reply) data, not just the outbound initiating packet — the first UDP reply / first TCP post-handshake read is appended to the same per-destination pending-sample buffer (capped at 2 entries), consumed by both the pVM cheap filter and, once wired, available for a future on-device classifier. Directly closes the "wrong side of the connection" isolation gap `discussions.md` item 1 raised, and is the prerequisite for the destination-observable feature set item 9 found more predictive.
- ~~Still open, not built: dynamic, checksummed OTA-style model updates~~ — **built session 20 (`63d9f9e`), then revised session 21 (`aa25bdf`)**: the update mechanism itself (manifest poll, SHA-256 verification before trusting a download) is real, but the bundled-fallback-model half was deliberately removed — monitoring now refuses to start at all until a real model has been fetched and verified, no local-first-launch fallback. See `noxos-app/TASKS.md` session 21 and the "Reversed 2026-09-14" note earlier in this section.

### File and network pipelines, end-to-end (designed 2026-09-13, not built — see bullets above for per-piece detail)

**Files — two trigger paths, diverging on what "held" means for each:**

```
A) Manual scan (SAF picker, "Select & Scan")
──────────────────────────────────────────────
User picks file → TriggerRouter.scanFile() reads bytes
        │
        ▼
Microdroid VM (one-shot): parser (EXIF today) + cheap filter run together
   (magic-header-vs-declared-extension mismatch, size sanity)
        │
        ▼
[status][JSON], now carrying flagged + flag_reason → VM destroyed
        │
   ┌────┴────┐
   │ clean   │ flagged
   ▼         ▼
Success   ScanResult.Held(reason) — nothing delivered to the requesting app
(as today)     │
               ▼
      bytes (already in memory) → POST /analyze/file
               │
        ┌──────┴──────┐
        │ allow/force  │ block / no response yet
        ▼              ▼
   deliver result   stays Held — force-allow available any time,
   (resolve Held)   independent of whether the AI has responded

B) Auto-scan (FileArrivalWatcher on Downloads)
──────────────────────────────────────────────
ContentObserver fires on a new MediaStore.Downloads file → same pVM step as (A)
        │
   ┌────┴────┐
   │ clean   │ flagged
   ▼         ▼
audit-only   MOVE the file out of Downloads into app-private storage, now
(as today)   (real quarantine — nothing else can open it once moved)
             → audit entry marked Held
                     │
                     ▼
              bytes → POST /analyze/file
                     │
              ┌──────┴──────┐
              │ allow/force  │ block
              ▼              ▼
        move file BACK    stays quarantined
        to Downloads      (delete-vs-hold-forever: not decided)
```

**Network — one pipeline, gated by the ACL's existing one-time-per-destination flag, not per-packet:**

```
Live relay (NetMonitorService: UDP relay + TcpRelayManager) — unchanged, unisolated, stays fast
        │
        ▼
AclRepository: new destination? insertIfAbsent → FLAGGED, once, ever (existing cost gate)
        │
        ▼ (async — relay for this flow keeps running through everything below)
Background dispatcher grabs a small sample of that flow's raw packets
        │
        ▼
Microdroid VM, one-shot: noxos-payload's 2nd task type runs a header-sanity /
protocol-conformance check on the sample → flagged + reason → VM destroyed
        │
   ┌─────┴──────┐
   │ clean      │ flagged
   ▼            ▼
ALLOWED,      escalate to the AI classifier — NEVER reached on a clean VM
session-      result, which is the point: keeps the common, benign case cheap
scoped,             │
audit-logged        ▼
(no AI call)   On-device: NetMonitorService's already-computed per-flow features
   │           (port/protocol/volume/frequency) → hand-rolled Kotlin tree interpreter
   │           evaluating the bundled, JSON-dumped noxos-inference model
   │                 │
   │                 ▼
   │           AclRepository.allow()/.block() written back, sessionOnly=true
   │           (same session-scoped-trust rule as today), safetyScore recorded
   │                 │
   └────────┬────────┘
            ▼
     Enforcement as today: BLOCKED drops future flows to that destination
```

**Resolved 2026-09-13 (user's explicit decisions, same day as the diagrams above — supersedes the four bullets this replaces):**
- **EC2 gets deployed for real, serving both `/analyze/network` and `/analyze/file`.** This confirms the cloud endpoint is *not* being retired — settles "launch the EC2 box" from a someday item into the actual next infra step.
- **RESOLVED 2026-09-14: on-device vs. EC2 is not an either/or primary/fallback choice — it's a two-tier cascade.** The earlier framing ("which one is primary") was the wrong question; the real architecture is:
  ```
  ACL flags destination → pVM cheap filter (header sanity, no ML at all)
          ↓ clean → ALLOWED, nothing else runs
          ↓ flagged
  On-device classifier (Tier 1 — fast, cheap, runs on every cheap-filter-flagged destination)
          ↓ looks benign → resolve ALLOWED, EC2 never contacted
          ↓ looks genuinely suspicious → escalate
  EC2 server model (Tier 2 — only ever sees the small residue Tier 1 flagged)
          ↓ final verdict, written back to the ACL
  ```
  This is also *why* the server model gets to be "genuinely richer" (see the branch-scope decision above) without becoming a cost or latency problem: it only ever processes the small fraction of traffic Tier 1 already flagged as worth a second look, not the full flagged volume. Same cost-gating instinct this project has applied everywhere else, just one tier further in.
  **Real wiring consequence, not yet built**: today's `AnalysisDispatcher` calls the EC2 endpoint directly for anything that clears the cheap filter — it doesn't run the on-device classifier first. Making the cascade real means restructuring that: on-device evaluates first, EC2 only fires when the on-device verdict itself is "suspicious." Tracked as a real task in `noxos-app/TASKS.md`.

  **Status clarification, 2026-09-14 — "the on-device model is done" is true for one half of this, not the other.** Two genuinely separate things, easy to conflate:
  - **The model artifact and its pipeline: complete.** Real dataset, real 10-feature training recipe (F1=0.9724), real export-to-JSON, real CI (train → export → verify → publish), real GitHub Releases hosting, real checksum verification on the app side. Future changes to *this* really are just "edit the dataset/feature list, push, CI does the rest" — no new plumbing needed.
  - **The model being an active feature on the phone: not complete, two real gaps.** (1) `OnDeviceNetworkClassifier` is built and tested but nothing in the live dispatch path calls it yet — that's the cascade-wiring task above, specced not built. (2) Nothing in this entire network pipeline can run on a real device at all until Phase 1c (`noxos-os`, `MANAGE_VIRTUAL_MACHINE`) ships, since the cheap filter that gates everything upstream of the classifier needs a working VM. Don't read "the model is done" as "the phone is protected" — the second one waits on both gaps closing.
- **`reasoning` explains the verdict both ways, not just for blocks.** The service should return a real explanation whether the destination/file was judged safe or unsafe — "safe because X" as much as "blocked because Y." Applies to both `/analyze/network` and `/analyze/file` once real reasoning text is built (still `null` today — this resolves *what* it should say, not that it's written yet).
- **Quarantined files get a user-configurable retention period, not indefinite hold.** Mirrors the existing audit-log retention pattern (`WardenSettingsRepository`'s 30/90/180/365-day dropdown) rather than a new mechanism — a quarantined/held file that's aged past the configured window gets cleaned up automatically instead of sitting there forever. **Built session 14**: real quarantine (physical move out of `MediaStore.Downloads` into app-private storage, `QuarantineManager`), a `quarantineRetentionDays` setting (same 30/90/180/365 options, default 30), purged on app start and on setting change, force-allow restores the file for real. Triggered today by the EXIF parser's own real `Failure` verdict; session 15 additionally wired the file-side cheap-filter's `cheap_filter_flagged` response into the same path (see `../noxos-app/TASKS.md` session 15) — `noxos-payload` doesn't need to build anything host-side to make this real, just implement the check and add the two response keys.
- **`AclEntity` schema extension — partially built, session 15.** `destPort`/`protocol` added (schema v7, captured once at flag time in `flagIfUnknown`) — a real, honest first slice of "richer per-flow features," not the full set. **Volume/frequency (running packet-count/byte-count counters) still deliberately not built** — judged not worth a per-packet DB write's self-DoS risk without a batched/rate-limited writer first; see `../noxos-inference/TASKS.md`'s model-export contract section for the full state of this gap.
- **A clean pVM cheap-filter result is a real, storable `ALLOWED` — not a silent pass-through.** Same session-scoped convention as an AI-resolved verdict (`sessionOnly = true`, cleared by `AclRepository.clearSessionVerdicts(NETWORK)` at the start of the next monitoring session — a clean check today doesn't mean permanently trusted) and it gets a real audit-log entry, same as a blocked or AI-resolved flow. **Built session 15**: `NetworkSampleVmDispatcher` implements exactly this — real, tested against fakes (no real VM/payload exists yet to test against for real, same Phase-2 gating as the rest of the VM code).

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

  **Ongoing Warden releases after Phase 1c ships do NOT each require a ROM recompile — one real condition attached, checked 2026-09-14.** Verified against Android's own signature-permission docs: an app update is only accepted if signed with the same certificate already installed, which is baseline Android behavior, not priv-app-specific. So as long as every future Warden build stays signed with the exact same platform key `noxos-os` bakes in at Phase 1c, ordinary releases (GitHub release, sideload, whatever distribution channel) should install as a same-signature update and keep the `MANAGE_VIRTUAL_MACHINE` grant — no ROM rebuild needed. **One piece not confirmed from official docs, flagged as recollection rather than verified fact**: the believed mechanism is that PackageManagerService treats the `/system/priv-app` copy as the privileged "base," and a same-signature update shadowing it into `/data/app` keeps privileged status for execution (this is the same mechanism Google uses to push Play-Store updates to system apps without a full OTA) — but the AOSP docs fetched describe *where* an app must live to be privileged, not explicitly what happens across an update-shadow boundary. **Verify empirically once Phase 1c ships**: bake Warden in, sideload a same-signed update, confirm `dumpsys package <warden-pkg>` still shows the `MANAGE_VIRTUAL_MACHINE` grant. Don't assume this without that check.

  **ROM recompile IS required for**: the first bake-in, any signing-key rotation, or adding a new privileged permission Warden doesn't already have listed in its `privapp-permissions-*.xml` — confirmed via AOSP allowlist docs that privileged permissions added in an update are never auto-granted, only ones already present in the on-partition allowlist at the time the app was first installed as a priv-app.

  **Also note**: the jniLibs handoff above is `noxos-app`/`noxos-payload`'s build step, not `noxos-os`'s — it has to produce the finished Warden APK (payload `.so` already bundled in) *before* handing it to the OS build for priv-app placement. Sequencing matters: app/payload work first, then OS bake-in, not the other way around. **The OS bake-in itself doesn't need to wait for the latest payload** — it can start now against whatever Warden release currently exists, and re-run later against a newer one; that's a cheap repeat, not a blocker.

  **Checked and rejected 2026-09-15: dynamically fetching the payload binary at runtime instead of embedding it in the app.** Not just unimplemented — architecturally unavailable through Microdroid's supported "app payload" API, confirmed via AOSP's own Microdroid docs. The pVM boot chain mounts the host app's *installed, signed APK itself* as a filesystem (`zipfuse` + `dm-verity` over the APK zip) and extracts the payload from inside it — the entire integrity guarantee is that pVM code is provably exactly what was in the signed APK, nothing else. No documented path points the VM config at an externally-downloaded file, and doing so would defeat the reason pVM isolation exists (arbitrary unverified code running with elevated VM privileges is exactly the hole it closes). **Real, lighter alternative instead**: `noxos-app` still needs rebuilding whenever `noxos-payload` releases, but that's a normal Gradle build + re-sign + publish, not a ROM rebuild — automate *that* as CI (workflow in `noxos-app` triggered by a `noxos-payload` release, pulls the new `.so`, rebuilds, re-signs with the same platform key, publishes). Gets the "cut a payload release and it flows through" experience without touching Microdroid's verification model. This is now the real intended shape of item 9 (jniLibs handoff), not a manual copy step.

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
