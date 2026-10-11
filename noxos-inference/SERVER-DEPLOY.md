# teacher-server: deployment and verification

Single static Go binary (`teacher-server` branch, release `teacher-server-latest`, SHA-256 in `teacher-server-linux-amd64.sha256`). It serves `/health`, `/analyze/network` (teacher XGBoost + TreeSHAP reasoning), `/analyze/file` (Drebin permission model, `advisory: true`) and `/reload`. The student model is not served; it runs on the device.

## Configuration (environment)

| variable | meaning |
|---|---|
| `NOXOS_MANIFEST_URL` | teacher manifest (`.../teacher-latest/manifest.json`); the model is downloaded, SHA-256 checked against the manifest, hot-reloaded every 300 s |
| `NOXOS_FILE_MANIFEST_URL` | file model manifest (`.../file-latest/manifest.json`) |
| `NOXOS_INFERENCE_API_KEY` | bearer token; if unset the analyze endpoints are open. `/health` is always open |
| `PORT` | default 8080 |
| `NOXOS_BIND_ADDRESS` | listen on one interface only (added in cb50ad0); empty means all interfaces |
| `NOXOS_RELOAD_INTERVAL_SECONDS` | default 300 |

`/analyze/network` returns 422 (no verdict) when the flow features are missing or invalid, see `ML-NETWORK-REQUEST-CONTRACT.md`. Two other behaviours to know: a model with no per-node cover returns `reasoning: null` instead of a made-up sentence; split comparisons are float32.

## Path A: local laptop (verified 2026-10-11)

Files in `~/noxos-artifacts/live-check/` (outside git): `token` (chmod 600, random 64 hex, never printed or committed), `start.sh [bind-address]` (defaults to the docker0 address, refuses to start if docker0 is down), `stop.sh`, `server.pid`, `server.log`, `endpoint.txt`, saved responses.

- Start: `~/noxos-artifacts/live-check/start.sh` (docker bridge) or `... start.sh 127.0.0.1` (host only). Stop: `~/noxos-artifacts/live-check/stop.sh`.
- The Cuttlefish host container (`cuttlefish_orchestrator`, `docker run` in `noxos-os/CUTTLEFISH.md`) uses default bridge networking, so the guest reaches the laptop through the container at the docker0 gateway, normally `http://172.17.0.1:8080`. Confirmed 2026-10-11: from inside `cuttlefish_orchestrator` (eth0 172.17.0.2, default route via 172.17.0.1), `curl http://172.17.0.1:8080/health` works, an unauthenticated analyze call gets 401 and an authenticated `/analyze/network` returns the TreeSHAP sentence (`guest_*.json` in live-check). `http://10.0.2.2:8080` does not work from the container (that address is the Android emulator-style alias, not present here). The server is bound to 172.17.0.1 only, not wlan0. A restarted container has no running CVD device; the guest hop (guest -> CVD NAT -> container -> 172.17.0.1) is unverified until a device is launched.
- Loopback verification run against the published models (teacher v1791623224, file v1790706350): `/health` ok; no token and wrong token both 401 on both analyze endpoints; `/analyze/network` returns a TreeSHAP sentence ("blocked - handshake_latency_millis (30), smean (1333.3), duration_millis (20000) pushed this toward attack-like" for a big-upload shape, "allowed - ..." for a small normal flow); `/analyze/file` returns `advisory: true` with the "advisory only (permission-based model trained on 2012-era apps, do not use this to block)" prefix.

## Path B: cloud (on-demand EC2, stopped)

`infra/user-data.sh` on the `teacher-server` branch installs the SHA-256-verified release binary as a systemd service on port 8443 (go build is OOM-killed on a 1 GiB t3.micro, so the binary is cross-compiled and downloaded). Instance `i-038094e878a029b4f` (t3.micro, us-east-1) is **stopped** by the user's decision; starting it is the user's spend decision. It was verified earlier on the older binary only; the current binary and models have not been exercised there.

## What is and is not verified

| item | status |
|---|---|
| current binary + current published models, loopback, auth, TreeSHAP, advisory file path | verified 2026-10-11 on the laptop |
| reachable from the Cuttlefish container to the host server (172.17.0.1:8080) | verified 2026-10-11 (health, 401, authenticated TreeSHAP) |
| reachable from inside the Android guest itself | not verified: no CVD device was running |
| cloud deploy of the current binary | not verified; older binary only |
| any traffic from a real Warden session | none |

Current release binary: `teacher-server-latest`, built from 90dd840, SHA-256 `51318d572420f3de31ef430fce5236fbad971796c575203c019fb01e9a510b8d`. The laptop server runs this binary (verified from inside `cuttlefish_orchestrator`: Warden-v3.3.0-shaped body gets 422, complete flow gets a verdict). The EC2 box, when next started, downloads this binary; that path is still unverified with it.
