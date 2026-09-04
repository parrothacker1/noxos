# Knowledge Hub

Private project documentation for NoxOS — not published, not linked from any repo's public README. Lives outside git entirely (gitignored at the NoxOS root); this is context for us and for future AI sessions, not for the public repos.

## Start here (any AI, any session, no prior context assumed)

This directory is written to be self-contained — everything a fresh session needs to pick this project up cold, without access to any prior conversation. Read in this order:

1. **This file** — repo map, per-repo pointers, data flow.
2. **[`PROJECT.md`](PROJECT.md)** — full architecture, every major decision and *why* it was made, the 14-phase roadmap. This is the single source of truth; if anything elsewhere contradicts it, this file wins.
3. **[`TASKS.md`](TASKS.md)** — what's actually done vs. in-progress vs. not-started, in concrete next-action form. Always check this before assuming any piece of work is finished — it's kept current specifically so a new session doesn't have to reconstruct state from git log archaeology across five repos.
4. **The relevant per-repo `README.md`** below, for whichever repo you're about to touch.

Verify before trusting: this project moves fast and these docs can lag reality. Any claim here that names a specific file/function/commit is a claim about *when it was written* — run `git log`/`git status` in the repo in question before acting on it, same as the general rule for any inherited context.

**Full architecture, decisions, and roadmap:** [`PROJECT.md`](PROJECT.md) — read that first for the "why."
**What to actually do next:** [`TASKS.md`](TASKS.md).

Last reviewed: 2026-08-15

## Structure

```
knowledge-graph/
├── README.md              # this file — hub, points everywhere else, "start here" for any AI
├── PROJECT.md              # full architecture, decisions, roadmap (source of truth)
├── TASKS.md                 # concrete task list: done / in-progress / next, with explanations
├── noxos-os/README.md      # AOSP customization — infra scripts, local manifest, CI
├── noxos-payload/README.md # Microdroid native payload — AVF research findings
├── noxos-app/README.md     # host Android app — Gradle module layout
└── noxos-server/README.md  # OTA update server — Go API shape
```

## Branding

`../assets/branding/` (root repo, public) — the logo mark: a hexagon (VM isolation boundary) around a crescent moon (*nox* = night), navy `#0B1220` + teal `#4FD1C5`. Source of truth for `noxos-app`'s launcher icon and `noxos-os`'s boot animation, both of which vendor their own copy. See `../assets/branding/README.md`.

## Per-repo index

| Repo | Language | What it does | Context |
|---|---|---|---|
| [noxos-os](https://github.com/parrothacker1/noxos-os) | Shell + AOSP/Soong | AOSP fork build pipeline — local manifest, infra scripts, self-hosted CI | [`noxos-os/README.md`](noxos-os/README.md) |
| [noxos-payload](https://github.com/parrothacker1/noxos-payload) | C++ (Android.bp) | Native payload that runs inside the Microdroid pVM | [`noxos-payload/README.md`](noxos-payload/README.md) |
| [noxos-app](https://github.com/parrothacker1/noxos-app) | Kotlin (Gradle) | Host-side Android app — trigger/router, VPN monitor, audit UI | [`noxos-app/README.md`](noxos-app/README.md) |
| [noxos-server](https://github.com/parrothacker1/noxos-server) | Bash + GitHub Actions | Static OTA manifest publisher (GH Pages) — not a running service | [`noxos-server/README.md`](noxos-server/README.md) |

No `INDEX.md` / `index.json` function-level indexes yet — there's no real implementation to index (all four repos are Phase 1 scaffolding as of 2026-08-15). Add those per-project once P6+ implementation work lands, same pattern as `patent-cron`'s knowledge-graph.

## Data flow (target architecture, not yet built)

```
Host OS:
  Untrusted File (download/share/sideload) ─┐
  App Network Traffic → VPNService Monitor ──┼─→ Host Trigger/Router      [noxos-app]
                                              ↓
Microdroid pVM (ephemeral):
  Boot VM → Isolated Payload/Parser → Validate/Scan/Parse → Return Result → Destroy VM   [noxos-payload]
                                              ↓                    ↓
                              Sanitized Result → Requesting App    Audit & Observability App   [noxos-app]
                                                                   (execution + traffic logs)

noxos-os  → builds the AOSP image all of the above runs on, uploads full+patch OTA artifacts to S3
noxos-server → static manifest reading from S3, GH Pages, no live server
```

## Status

Don't trust a summary here — read [`TASKS.md`](TASKS.md), it's kept current and this isn't. Short version as of 2026-08-31: all 4 repos scaffolded and pushed, CI green everywhere. `noxos-app` (branded **Warden**) got a full visual + feature redesign and its first real-device testing (session 6) — three real capture-pipeline bugs found and fixed through `v1.1.3`, UDP relay confirmed working against real traffic, TCP relay still broken on-device and being diagnosed (see `TASKS.md` backlog item 17). OTA design moved from GitHub Releases to S3 (`noxos-server` rewritten to match, unverified end-to-end — no bucket/credentials yet). **`noxos-os`'s infra plan was re-architected this session (session 7): Cuttlefish moved off AWS entirely** (the M8i/R8i/C8i nested-KVM instance the user needed for it was never actually obtainable — matches session 6's `c7i-flex` finding), now running locally on the user's Arch Linux laptop via bare-metal KVM instead. AWS is now scoped to one box only, `r5.2xlarge`, for AOSP compilation — no nested virtualization required there at all. Unlike most planning passes, **local Cuttlefish (Phase 1b) actually got built and verified working this session** — a real Docker container running Google's own Cuttlefish orchestrator stack, `/dev/kvm`/`/dev/net/tun` passed through, see `noxos-os/CUTTLEFISH.md`. AWS credentials (briefly broken, then fixed by the user) are now working in `us-east-1`, and **the `r5.2xlarge` ROM-compile box is up and actually running its first real `repo sync` + build (v0 stock, then v1 with a new lightweight-base/branding device overlay) right now** — the first real test of any of `noxos-os`'s scripts against real AOSP source. An S3 bucket (`noxos-releases`) is also live for OTA hosting, with least-privilege IAM wired for both the compile box and `noxos-server`'s CI. Full detail, live resource IDs, and the two real infra bugs found getting the box running: `TASKS.md`.

## Conventions

- **Commits:** `type: message` (Conventional Commits — `feat:`, `fix:`, `chore:`, etc.), no `Co-Authored-By` trailer. The early "init" commits across all repos predate this convention being stated explicitly — left as-is, not retrofitted. `noxos-app` also has a local, gitignored `AGENTS.md` restating this + the no-comments rule, since it's the repo this keeps needing correction on.
- **Repos:** public, under `github.com/parrothacker1`.
- **No code comments**, in any repo, even "why" comments — see [`TASKS.md`](TASKS.md) session log.
