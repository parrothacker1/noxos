# Knowledge Hub

Private project documentation for NoxOS — not published, not linked from any repo's public README. Lives outside git entirely (gitignored at the NoxOS root); this is context for us and for future AI sessions, not for the public repos.

## Start here (any AI, any session, no prior context assumed)

This directory is written to be self-contained — everything a fresh session needs to pick this project up cold, without access to any prior conversation. Read in this order:

1. **This file** — repo map, per-repo pointers, data flow.
2. **[`PROJECT.md`](PROJECT.md)** — full architecture, every major decision and *why* it was made, the 14-phase roadmap. This is the single source of truth; if anything elsewhere contradicts it, this file wins.
3. **The relevant repo's own `<repo>/TASKS.md` + `<repo>/README.md`** below, for whichever repo you're about to touch — task history is per-repo (as of 2026-09-12), not one combined file, so a session working on a single repo only needs to load that repo's own pair of files. [`TASKS.md`](TASKS.md) at this top level is now just an index pointing to each repo's file — start there if you're not sure which repo(s) are relevant yet.

Verify before trusting: this project moves fast and these docs can lag reality. Any claim here that names a specific file/function/commit is a claim about *when it was written* — run `git log`/`git status` in the repo in question before acting on it, same as the general rule for any inherited context.

**Full architecture, decisions, and roadmap:** [`PROJECT.md`](PROJECT.md) — read that first for the "why."
**What to actually do next, per repo:** [`TASKS.md`](TASKS.md) (index) → `<repo>/TASKS.md`.

Last reviewed: 2026-09-12

## Structure

```
knowledge-graph/
├── README.md                    # this file — hub, points everywhere else, "start here" for any AI
├── PROJECT.md                    # full architecture, decisions, roadmap (source of truth)
├── TASKS.md                       # index only — points to each repo's own TASKS.md below
├── noxos-os/README.md            # AOSP customization — infra scripts, local manifest, CI
├── noxos-os/TASKS.md              # noxos-os's own session-by-session task history
├── noxos-os/CUTTLEFISH.md        # local Cuttlefish container setup detail
├── noxos-payload/README.md       # Microdroid native payload — AVF research findings
├── noxos-payload/TASKS.md         # noxos-payload's own task history
├── noxos-app/README.md           # host Android app (Warden) — Gradle module layout
├── noxos-app/TASKS.md             # noxos-app's own task history
├── noxos-server/README.md        # OTA update server — API shape
├── noxos-server/TASKS.md          # noxos-server's own task history
├── noxos-inference/README.md     # threat-analysis inference backend
└── noxos-inference/TASKS.md       # noxos-inference's own task history
```

## Branding

`../assets/branding/` (root repo, public) — the logo mark: a hexagon (VM isolation boundary) around a crescent moon (*nox* = night), navy `#0B1220` + teal `#4FD1C5`. Source of truth for `noxos-app`'s launcher icon and `noxos-os`'s boot animation, both of which vendor their own copy. See `../assets/branding/README.md`.

## Per-repo index

| Repo | Language | What it does | Context |
|---|---|---|---|
| [noxos-os](https://github.com/parrothacker1/noxos-os) | Shell + AOSP/Soong | AOSP fork build pipeline — local manifest, infra scripts, self-hosted CI | [`noxos-os/README.md`](noxos-os/README.md) + [`noxos-os/TASKS.md`](noxos-os/TASKS.md) |
| [noxos-payload](https://github.com/parrothacker1/noxos-payload) | C++ (Android.bp) | Native payload that runs inside the Microdroid pVM | [`noxos-payload/README.md`](noxos-payload/README.md) + [`noxos-payload/TASKS.md`](noxos-payload/TASKS.md) |
| [noxos-app](https://github.com/parrothacker1/noxos-app) | Kotlin (Gradle) | Host-side Android app (**Warden**) — trigger/router, VPN monitor, audit UI, ACL | [`noxos-app/README.md`](noxos-app/README.md) + [`noxos-app/TASKS.md`](noxos-app/TASKS.md) |
| [noxos-server](https://github.com/parrothacker1/noxos-server) | Bash + GitHub Actions | Static OTA manifest publisher (GH Pages) — not a running service | [`noxos-server/README.md`](noxos-server/README.md) + [`noxos-server/TASKS.md`](noxos-server/TASKS.md) |
| [noxos-inference](https://github.com/parrothacker1/noxos-inference) | Python (FastAPI) | Self-hosted threat-analysis backend for Warden's flagged traffic/files | [`noxos-inference/README.md`](noxos-inference/README.md) + [`noxos-inference/TASKS.md`](noxos-inference/TASKS.md) |

No `INDEX.md` / `index.json` function-level indexes yet. Add those per-project once it's clear they'd earn their keep, same pattern as `patent-cron`'s knowledge-graph.

## Data flow (target architecture)

```
Host OS:
  Untrusted File (download/share/sideload) ─┐
  App Network Traffic → VPNService Monitor ──┼─→ Host Trigger/Router      [noxos-app / Warden]
                                              ↓
Microdroid pVM (ephemeral):
  Boot VM → Isolated Payload/Parser → Validate/Scan/Parse → Return Result → Destroy VM   [noxos-payload]
                                              ↓                    ↓
                              Sanitized Result → Requesting App    Audit & Observability App   [noxos-app]
                                                                   (execution + traffic logs)
                                                                   ↓
                              Flagged (new/ambiguous) destination or file, one verdict ever
                                                                   ↓
                                                    Self-hosted inference backend  [noxos-inference]
                                                    (gradient-boosted classifier for traffic,
                                                     ClamAV for files) — verdict written back
                                                     to the ACL, may then enforce future traffic

noxos-os  → builds the AOSP image all of the above runs on, uploads full+patch OTA artifacts to S3
noxos-server → static manifest reading from S3, GH Pages, no live server
```

The `noxos-app`→`noxos-inference` leg (the bottom two boxes) is real and tested as of 2026-09-12 against a stand-in responder — the real model/service doesn't exist yet. See [`noxos-inference/TASKS.md`](noxos-inference/TASKS.md).

## Status

Don't trust a summary here — read each repo's own `TASKS.md` (index at [`TASKS.md`](TASKS.md)), kept current per-repo; this isn't. As of 2026-09-12: all five repos exist, scaffolded, CI green where CI exists. `noxos-os` has produced two real, boot-verified Cuttlefish artifacts (v0 stock and v1 the custom lightweight-base overlay) via a real AWS spot-fleet compile pipeline. `noxos-app` (branded **Warden**) has a full visual redesign, a real 3-state ACL with priority/kind and a seed list, both UDP and TCP network relay confirmed working on real hardware, and a real dispatch loop to `noxos-inference`'s (not-yet-deployed) service verified end-to-end against a stand-in. `noxos-server` has a drafted-not-deployed OTA-signing Lambda. `noxos-inference` is brand new — infra scripts exist, the model/dataset/service do not yet.

## Conventions

- **Commits:** `type: message` (Conventional Commits — `feat:`, `fix:`, `chore:`, etc.), no `Co-Authored-By` trailer. The early "init" commits across all repos predate this convention being stated explicitly — left as-is, not retrofitted. `noxos-app` and `noxos-inference` each have their own local, gitignored `AGENTS.md` restating this + the no-comments rule.
- **Repos:** public, under `github.com/parrothacker1`.
- **No code comments**, in any repo, even "why" comments — see each repo's own `TASKS.md` for when/why this was established.
- **IAM writes get blocked by this environment's auto-mode classifier** — every repo's infra work has hit this; the fix is always the same, hand the user the exact `aws iam ...` command to run manually via `!`.
- **GPG commit signing can hang** in a non-interactive session (no way to satisfy a `pinentry` prompt) — when this happens, ask the user before bypassing with `--no-gpg-sign`; if they authorize it, track which commits are unsigned and re-sign them (`git rebase --exec 'git commit --amend --no-edit -S'`) once resumed. This has happened at least three times across this project's history — see `noxos-os/TASKS.md` and `noxos-inference/TASKS.md` for examples.
