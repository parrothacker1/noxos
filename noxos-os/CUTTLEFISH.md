# Cuttlefish Local Development Environment (Arch Linux)

Created: 2026-08-31
Scope: Phase 1b — Local bare-metal KVM Cuttlefish setup on Arch Linux host.

---

## 1. Overview & Architecture

Official Google Cuttlefish tooling (`android-cuttlefish`) is packaged as `.deb` binaries for Debian/Ubuntu. On Arch Linux, AUR packages are out of date and prone to breaks.

To solve this on Arch bare-metal:
- **Host System:** Arch Linux (`6.18.38-1-lts`), KVM enabled (`/dev/kvm`), TUN enabled (`/dev/net/tun`).
- **Container Environment:** Docker container built directly from Google's official [`google/android-cuttlefish`](https://github.com/google/android-cuttlefish) repository (`container/image/Containerfile`).
- **Key Container Image:** `cuttlefish-host:latest` (built locally).
- **Active Container Name:** `cuttlefish_orchestrator`
- **Capabilities Granted:** Privileged access (`--privileged`) with `/dev/kvm` and `/dev/net/tun` mapped directly into the container.

---

## 2. How to Build & Run the Cuttlefish Host Container from Scratch

If you ever need to rebuild or re-run the container manually without using the script:

### Step 1: Clone the Cuttlefish Repository
```bash
git clone https://github.com/google/android-cuttlefish.git /tmp/android-cuttlefish --depth=1
```

### Step 2: Build the Container Image
> **IMPORTANT:** You MUST pass `--build-arg REPO=android-cuttlefish` or apt repository resolution inside the container build will 404.

```bash
docker build -t cuttlefish-host \
  -f /tmp/android-cuttlefish/container/image/Containerfile \
  --build-arg REPO=android-cuttlefish \
  /tmp/android-cuttlefish
```

### Step 3: Run the Host Container
Run the built image with KVM, TUN, and port-forwarding:

```bash
docker run -d \
  --name cuttlefish_orchestrator \
  --privileged \
  --device /dev/kvm \
  --device /dev/net/tun \
  -p 1080:1080 -p 1443:1443 \
  -p 2080:2080 -p 2443:2443 \
  -p 6520-6530:6520-6530 \
  cuttlefish-host:latest
```

---

## 3. Container Ports & Access Points

| Component | Target URL / Port | Protocol | Purpose |
|---|---|---|---|
| **Web UI / Operator Dashboard** | [http://localhost:1080](http://localhost:1080) | HTTP | Visual screen streaming & browser controls |
| **Secure Operator Web UI** | [https://localhost:1443](https://localhost:1443) | HTTPS | SSL-encrypted WebRTC screen stream |
| **Host Orchestrator API** | `http://localhost:2080` / `2081` | HTTP | API service for controlling CVD instances |
| **ADB Connectivity** | `localhost:6520` (to `6530`) | TCP | Remote debugging (`adb connect localhost:6520`) |
| **WebRTC Video Feed** | Ports `15550-15560` | UDP/TCP | High-FPS screen streaming |

---

## 4. How to Access & Interact with Cuttlefish

### A. Accessing the Browser UI
Open your browser and navigate to:
```text
http://localhost:1080
```
*(Or https://localhost:1443 if using HTTPS)*

This opens Google's Cuttlefish WebRTC dashboard where active virtual device screens, touch interactions, buttons, and logs are rendered.

### B. Connecting via ADB
From your local Arch terminal, run:
```bash
adb connect localhost:6520
```
Verify the device status:
```bash
adb devices
adb shell getprop ro.build.version.release
```

---

## 5. How to Run Your Custom Built NoxOS OS Image — UNVERIFIED, corrected 2026-08-31

**This whole section was wrong about the container's actual layout and hasn't been exercised against a real image yet (Phase 1a hasn't produced one) — treat everything below as a starting hypothesis, not a confirmed procedure.** Checked directly against the running `cuttlefish_orchestrator` container: there is no `/home/user` (`/home` is empty) and there is no standalone `launch_cvd`/`stop_cvd` binary — only a unified `/usr/bin/cvd` CLI (subcommands, e.g. `cvd create`/`cvd stop`, supersede the old `launch_cvd`/`stop_cvd` scripts). `cvd fleet` run against the live container currently returns `{"groups": []}` — no device has ever been created in it yet.

When `noxos-os/infra/build.sh` (on AWS or elsewhere) produces `m dist` output under `out/dist/`, it should still be the same two artifacts:
1. `cvd-host_package.tar.gz`
2. `aosp_cf_x86_64_phone-img-*.zip`

Open question, not yet resolved: whether to extract these into a bind-mounted host directory (`-v` at container-start time, meaning `setup-cuttlefish-local.sh --start` needs a mount flag added) or `docker cp` them in after the fact, and what working directory `cvd create`/`cvd start` actually expects them relative to inside this image (root's home is `/root`, but that's a guess for where images should land, not confirmed). **Resolve this against a real build, not by guessing further** — first real `m dist` output is Phase 1a's job (`TASKS.md`), this section gets filled in for real once that exists and the actual `cvd create` invocation has been run and confirmed working.

---

## 6. Container Management Commands

### A. Managing Container Lifecycle
```bash
# Check if container is running
docker ps | grep cuttlefish

# Stop container
docker stop cuttlefish_orchestrator

# Start container if stopped
docker start cuttlefish_orchestrator

# View live service logs
docker logs -f cuttlefish_orchestrator
```

### B. Interactive Shell Access inside Container
```bash
docker exec -it cuttlefish_orchestrator bash
```

---

## 7. Automation Script Reference

Automation script: [`../../noxos-os/infra/setup-cuttlefish-local.sh`](../../noxos-os/infra/setup-cuttlefish-local.sh).

**Rewritten 2026-08-31** — the previous version of this script (pull `us-docker.pkg.dev/.../cuttlefish-orchestration:latest` with a `qemu-kvm`/`libvirt` Ubuntu fallback, plus `ci.android.com` build-artifact downloading) never matched what's actually running and was never exercised — the fallback in particular would have failed immediately (`./bin/launch_cvd` doesn't exist in a bare `qemu-kvm`/`libvirt` install). The script now just codifies the exact commands in section 2 above, which is what actually produced the live `cuttlefish_orchestrator` container:

- `./infra/setup-cuttlefish-local.sh --prereq-check` — validates `/dev/kvm`, `/dev/net/tun`, Docker daemon.
- `./infra/setup-cuttlefish-local.sh --build` — clones `android-cuttlefish` (if not already at `~/tools/android-cuttlefish`) and builds `cuttlefish-host:latest` from `container/image/Containerfile`.
- `./infra/setup-cuttlefish-local.sh --start` — runs the container (same flags as section 2's `docker run`), recreating it if one already exists.
- `./infra/setup-cuttlefish-local.sh --stop` — stops and removes it.
- No args — prereq-check, build, and start in sequence.

No `--download-only`/`--launch-only` anymore — Phase 1c (copying a real NoxOS `m dist` build into this container) isn't built yet, since Phase 1a hasn't produced a real image to test the copy step against. Don't add that back speculatively — see section 5 above for the open questions that block it.
