# NoxOS — Task List (index)

Task history used to live entirely in this one file. As of 2026-09-12 it's split per repo, so a session working on a single repo doesn't need to load the whole project's history. This file is now just an index — read [`README.md`](README.md) (hub) and [`PROJECT.md`](PROJECT.md) (architecture, source of truth) for cross-repo context first, then the relevant repo's own file below.

| Repo | Task history |
|---|---|
| `noxos-os` (AOSP build, AWS/EC2 infra, local Cuttlefish, device overlays) | [`noxos-os/TASKS.md`](noxos-os/TASKS.md) |
| `noxos-app` (Warden — the host Android app) | [`noxos-app/TASKS.md`](noxos-app/TASKS.md) |
| `noxos-payload` (native Microdroid guest payload) | [`noxos-payload/TASKS.md`](noxos-payload/TASKS.md) |
| `noxos-server` (OTA manifest publisher) | [`noxos-server/TASKS.md`](noxos-server/TASKS.md) |
| `noxos-inference` (threat-analysis inference backend) | [`noxos-inference/TASKS.md`](noxos-inference/TASKS.md) |

Each of those files also has a matching `README.md` in the same directory (repo-specific architecture/module notes, not session history) — read both together when picking up a repo cold.
