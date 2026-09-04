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

### OTA distribution (revised 2026-08-16 — supersedes 2026-08-15's GitHub-Releases framing)

Originally scoped as a persistent self-hosted Go server, then revised to GitHub Releases + a static manifest. Revised again: GitHub Releases' 2GB-per-file limit is a real risk for full Android image bundles, so artifacts move to **S3**:

- `s3://noxos-releases/full/` — periodic complete builds, for fresh installs or devices too far out of date to patch forward.
- `s3://noxos-releases/patches/` — incremental deltas between *consecutive* full releases only, generated via AOSP's `ota_from_target_files -i old.zip new.zip patch.zip`. A patch isn't a separate build artifact — it's a diff computed from two already-built target-files packages.
- A small JSON manifest tracks available versions and valid patch chains; the on-device updater resolves current→latest as either "apply the single available patch" or "pull the latest full image" if too far behind.
- **Still no N-hop patch chaining across multiple missed versions** — that constraint from the 08-15 revision holds; only the hosting and single-hop patch generation changed.
- **No push notifications** — client polls on a schedule instead of FCM (conflicts with GMS-independence) or a self-hosted UnifiedPush relay.
- **No Lambda / compute-on-request** — no server-side logic yet that would justify it.
- Signing stays self-controlled regardless of hosting — the "we don't trust Google's OTA channel" claim lives in who holds the keys, not in running custom server infra.

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
4. **`noxos-server`** — static OTA manifest publisher (not a running server — see "OTA distribution" below).

## Roadmap — 14 phases, 5 parts

- **Part I — Preparatory:** P1 build environment/toolchain setup, P2 prove the AVF/Microdroid pipeline works using Google's reference demo before custom code.
- **Part II — Lightweight base:** P3 strip GMS/bloat, P4 trim fonts/locale/kernel, P5 ART/init tuning.
- **Part III — Isolation architecture (core work):** P6 minimal custom payload in a VM, P7 real untrusted-file parser + adversarial test, P8 host-side auto-trigger/routing, P9 observability/audit app, P10 network traffic visibility + correlation.
- **Part IV — Distribution:** P11 app store integration, P12 custom OTA channel.
- **Part V — Final integration:** P13 end-to-end demo, P14 documentation.

## Current status

Literature survey and architectural roadmap delivered to the guide. Nothing implemented yet. Next step: **Phase 1** — get the build environment running and an unmodified Cuttlefish image compiling and booting, before any custom code.
