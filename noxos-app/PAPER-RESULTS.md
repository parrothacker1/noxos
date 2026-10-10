# noxos-app (Warden) — paper-ready facts, v3.2.0 (2026-10-10/11)

Everything here was measured on the Cuttlefish device with the platform-signed v3.2.0 release APK unless marked UNMEASURED.

## Release

- v3.2.0 = commit `79262e7` (payload v1.0.5, versionCode 17). CI run 38078407463 success; Release run 38078698521 success.
- https://github.com/parrothacker1/noxos-app/releases/tag/v3.2.0 — `app-release.apk` sha256 `2cc8205e84b752a031ca877a79e52a6c78b1de618001c15b21308c8349bcb768` (equals GitHub's digest; downloaded and re-hashed).
- Payload v1.0.5 libs synced by hand (Sync Payload workflow stays disabled). sha256 equals the AWS build copies: arm64-v8a `bfd72124...0e3c`, x86_64 `4125200a...cc6d`. readelf NEEDED = libvm_payload/libc/libm/libdl only; nm -D exports `AVmPayload_main`, imports `AVmPayload_notifyPayloadReady`; strings finds neither `EICAR-STANDARD` nor `com.metasploit.stage` (both ABIs).
- Unit tests: 164 `@Test` methods in 23 files (grep count, not a Gradle report), all green in CI. New in this release: 2 student-parser tests.

## Student parser tolerance (new student-latest v1791623396)

`OnDeviceNetworkClassifier` reads JSONObject keys by name, so unknown top-level `feature_scale` and per-node `cover` are ignored. Tests: a synthetic model with extra fields, and the real released model (fixture `student_released_v1791623396.json`, sha256 `1e564271...b0d8`, 100 trees, 9-feature `feature_scale`) parses and classifies. The existing float32-boundary test is unchanged. On the device the downloaded model is v1791623396 (meta file), so the live download path parses it too.

## /analyze/file (advisory client)

- Contract checked against ML-FILE-DESIGN.md: request key `permission_strings`, response `verdict`/`safety_score`/`reasoning` plus `advisory:true`. The design doc says the exact schema is "not written yet", so this is checked against the doc's field names and the NoxOS Inference server behaviour recorded earlier, not against a published schema.
- MOCK, not live: a Python mock server on the Cuttlefish host (192.168.97.1:8099) received, from the real v1.0.5 guest scanning Warden's own APK, `POST /analyze/file` with `Authorization: Bearer <key>` and body `{"permission_strings":[8 android.permission.* strings]}` and nothing else. Audit row: "Scan completed, no issues found | Advisory: advisory only: mock", flagged 0. The live EC2 server was NOT used (spend decision not made) — UNMEASURED live.
- Router tests (8) with a plain-socket fake server pin: only clean APKs, only with the toggle on and an endpoint set, advisory never changes the verdict or quarantine.

## Warden's own APK no longer self-flags

Scanning the v3.2.0 APK itself (43.5 MB) returned "Scan completed, no issues found", not flagged, not quarantined (BOOTING 1018 ms, EXECUTING 520 ms, SANITIZING 2 ms). v1.0.4 libs flagged it on the EICAR signature (per Payload's finding); not re-run here.

## The three fixes from 7f30e4d, on the device

1. Same-second batch: four files (png, pdf, txt, jpg) pushed and broadcast back-to-back produced four VMs within ~0.2 s (19:14:47.107-.282) and four audit rows. (v3.1.0 scanned only the first.)
2. Auto-scan outside the app: the self-scan above ran with the app in the background (HOME pressed), and the batch ran while the app was open. A BACK-key exit test was not repeated on this build — partially measured.
3. Labels: the `.txt` row reads "Unrecognized file type (unknown) — not analyzed, not flagged". The detail-screen banner/pill text was not re-checked visually on this build — UNMEASURED visually (unit tested).

Scan timings, 512 MB microdroid VM: BOOTING 1.97-2.44 s, EXECUTING 4-30 ms (tiny files), 520 ms for the 43.5 MB APK.

File results: PNG, PDF, EXIF-less JPEG, APK -> "no issues found"; `.txt` -> not analyzed; earlier-build quarantine of the spoofed `holiday_photo.jpg` and a 0-byte "photo" is unchanged (rows 3 and 6 from the v3.1.0 pass); no new quarantines this pass.

## Autoencoder tier (MIRAGE model v1790722998, thresholds tcp 0.32267, udp 0.12507)

Measured with generated test traffic (adb `nc`), destination-IP unit, scored at the 30 s poll:

| Flows | Result |
|---|---|
| TCP, 5 fresh destinations (example.com :80/:443 via 172.66.147.243, 140.82.112.3, 151.101.1.69, 104.16.132.229, the mock host) | 5/5 "autoencoder: normal" -> ALLOWED (session only) |
| UDP, 10 fresh resolvers, one 34-byte `hello` datagram, no reply | 10/10 flagged, errors 0.140-0.268 (threshold 0.125) |
| UDP, 4 real DNS A queries for example.com (57 B up; 3 of 4 got a 61 B reply) | 4/4 flagged, errors 0.181-0.250 |
| UDP, 9.9.9.9 earlier | flagged, 0.141 |

So on this device every fresh UDP destination was flagged: 15/15 (not the ~9% the MIRAGE document reports). Caveats: tiny, test-generated, single-exchange flows, only ~15 destinations, one device, no real app traffic; the training UDP calibration was thin (132-807 rows). A real-traffic UDP false-flag rate is UNMEASURED.

Escalation: with an endpoint set, the flagged 9.9.9.9 was sent to `/analyze/network` (body ip, priority, reason, proto udp, dst_port 53), the mock answered allow, ACL went ALLOWED ("ai: mock"). With the endpoint blank, the 14 flagged UDP destinations stayed BLOCKED (on-device student gave no "allow"; only a student/server "allow" releases a block). Whether the on-device student scored each one as block or uncertain was not logged — UNMEASURED. Consequence: a UDP destination that is not in the seeded allow list (8.8.8.8, 8.8.4.4, 1.1.1.1, 1.0.0.1) is blocked until released, with no endpoint set.

## Limitations found

- Stale FLAGGED rows are never rescored: persisted rows without live stats (process restart) are skipped by design ("leaving pending"), and new traffic to a FLAGGED IP does not create stats (stats are only created for unknown IPs). Seen: `104.20.23.154`, `216.239.35.0`, `216.239.35.12` stayed FLAGGED after fresh connections to them. They are relayed, not blocked, while FLAGGED. A fix (seed stats when a FLAGGED IP reappears) is small but not made.
- Thin UDP flows are over-flagged (above).
- IPv4 TCP/UDP only; dttl not capturable from an app; flows are aggregated per destination IP.
- Live `/analyze/file`, `/analyze/network` against the real server: not tested this pass.


# Addendum 2026-10-11 — new UDP threshold and the Warden isolation evidence

All measured on the same Cuttlefish device (v3.2.0 release APK, payload v1.0.5) unless marked UNMEASURED. Raw numbers come from the audit database (`audit_entries.stepTimingsCsv`, `durationMillis`), `logcat`, `dumpsys`, `ps`.

## A. Autoencoder v1791661543 (UDP threshold 0.429368; TCP unchanged)

- Test fixture moved to the released file (`autoencoder_released_v1791661543.json`, sha256 `ba13d20e…8950`); the UDP golden vector (error 0.140742) and the "almost every input missing" UDP vector (error 0.1827) are now `flagged=false`. CI 97492a4 run 38081369831 green (the first push, 8b1f9dd, failed only because a test name contained a `.`).
- The device re-downloaded the model on its own when the local copy was removed: meta `version=1791661543`, sha256 equal to the release.
- UDP rerun on 14 fresh destinations: 8 real DNS A queries (6 got a 61-byte reply, 2 got none) and 6 single-datagram `hello` probes: **0/14 flagged** (all "autoencoder: normal"), versus 14/14 flagged under the old 0.125 threshold. Errors of the normal flows are not logged (only that they are below 0.429368) — per-flow errors UNMEASURED.
- Caveat: tiny test-generated flows, one device, no real app UDP traffic (QUIC, VoIP, games) — a real-traffic rate is UNMEASURED. The 2.2% in the Inference doc is on MIRAGE, not on this device.
- Rows flagged by the old model (BLOCKED) stay BLOCKED across a model update; nothing rescoring them (same limitation as the stale FLAGGED rows above).

## B1. Timing (BOOTING / EXECUTING / SANITIZING)

Definitions (`TriggerRouter.kt`): total `durationMillis` runs from the start of `scanFile` to the audit write, so it includes the size check, `getOrCreate` + `vm.run()` (VM creation), BOOTING, EXECUTING, SANITIZING, and VM stop. **BOOTING** starts after `createSession` returns (VM created and run() issued) and stops when `getTransport()` returns, i.e. after the guest's `onPayloadReady` callback and `connectVsock(5000)`. **EXECUTING** starts after that and stops when the guest's full response has been read (it includes streaming the file over vsock, the guest parse, and the response). **SANITIZING** is the host-side decode of the response (plus the `/analyze/file` advisory call when it applies, so it can include a network round trip). VM stop/cleanup and the audit write are in total only. Timestamps are `System.currentTimeMillis()`, millisecond resolution.

**Warm series, N = 40, all SUCCESS** (device up for ~1 h, no other load; 5 scans each of: 69 B PNG, 198 B PDF, 51 B text, 7.5 KB JPEG, 1.2 KB ZIP, 1 MiB random `.bin`, 10 MiB random `.bin`, 43.5 MB APK; one file every 7–12 s, never overlapping):

| Phase (ms) | min | median | p95 | max |
|---|---|---|---|---|
| BOOTING | 712 | 821 | 929 | 942 |
| EXECUTING | 2 | 3 | 223 | 698 |
| SANITIZING | 0 | 0 | 1 | 2 |
| total | 940 | 1113 | 1298 | 1886 |

By type (median BOOTING / EXECUTING): tiny files 804–906 / 2–3; 1 MiB 828 / 10; 10 MiB 761 / 55 (max 176); 43.5 MB APK 826 / 223 (max 698). BOOTING does not depend on file size; EXECUTING grows with it (~5 ms/MiB up to 10 MiB, ~5 ms/MiB for the APK).

**Right after a fresh boot + fresh install** (the whole device was restarted with `cvd stop/start`, which this time also reset user data, then the same v3.2.0 APK was installed and monitoring started ~78 s after the install; first 40 scans, same file mix, 5 minutes): median BOOTING 1101 (min 869, p95 1793, max 1983), median EXECUTING 7, median total 1458 (p95 2142, max 2325). The very first scan (PNG): BOOTING 1006, EXECUTING 9, total 1403. The first three scans were 1006/1004/1282 ms BOOTING. So the device was ~25–35% slower for the first few minutes after boot; the "cold" claim rests on N = 1 first-scan sample plus this 40-scan series, not on repeated reboots (a second cold reboot was not done).

**Concurrent, N = 4 simultaneous 10 MiB scans:** BOOTING 2289–2817 ms, EXECUTING 108–319 ms, total 2973–3520 ms (vs 1.1 s alone) (cause not investigated; the 4-vCPU nested host is the likely limit).

Caveat for the paper: the host is Cuttlefish (crosvm in a Docker container on an i7-1255U) running AVF's crosvm *nested*; absolute boot times on a real phone are UNMEASURED and expected to differ.

## B2. VM configuration (as set in code, `MicrodroidVmSession.kt:42-46`)

`VirtualMachineConfig.Builder(context).setPayloadBinaryName("libnoxos_payload_stub.so").setProtectedVm(false).setMemoryBytes(512 MiB).build()`. Nothing else is set: vCPU count (default 1), debug level (default none), network (none requested), storage (none). Memory was 256 MiB (AVF default) until commit `0614c4e` (2026-09-29, "raise VM memory to 512MB"); the payload repo's "256 MiB / `--mem 256`" is that earlier measurement. The current crosvm line from `logcat` (virtmgr), quoted: `"--cpus", "num-cores=1", "--mem", "512", "--force-disable-readonly-mem", "--params", "coherent_pool=4096", "--balloon-page-reporting"`, with `--cid 2049…`, `--name crosvm_noxos-scan-<uuid>`, kernel `/apex/com.android.virt/etc/fs/microdroid_kernel`, `--disable-sandbox`, `Non-protected virtual machine … (owner: u0_a44)`. `--log-level debug` in that line is crosvm's host-side log level, not the guest debug level.

Lifecycle: one new VM per file, named `noxos-scan-<random UUID>` (`vmm.getOrCreate`), started with `vm.run()`, stopped by `vm.stop()` in `close()` (called from `use {}` after the response). **The VM is stopped but not deleted:** the app never calls `VirtualMachineManager.delete`, and `/data/data/com.noxos.app/vm/noxos-scan-*/` instance directories (≈340 KB each: instance.img + idsig) remained on the device after the scans (12 directories, 4.1 MB, counted earlier on this boot). This is a storage leak of about 340 KB per scan; it is not a security issue (the directory holds no file contents) but "deleted afterwards" is **not** true as written. Not fixed.

## B3. Device baseline

Cuttlefish `noxos_cf_x86_64_phone`, Android 17 (API 37, codename Baklava), build `CP2A.260605.016`, `eng.ubuntu`, `userdebug/dev-keys`, security patch 2026-06-05, kernel `6.12.74-android16-6` (x86_64). `cuttlefish_config.json`: 4 vCPUs, 4096 MB RAM (`/proc/meminfo` MemTotal 3.99 GB), `vm_manager: crosvm`, `enable_sandbox: false`. Host: 12th Gen Intel Core i7-1255U (12 logical CPUs), 16 GB RAM, Linux 6.18.38-lts, Cuttlefish `cvd` 1.57.0 inside a Docker container (`cuttlefish_orchestrator`). AVF: APEX `com.android.virt` versionCode 373399999; `ro.boot.hypervisor.vm.supported=1`, `ro.boot.hypervisor.protected_vm.supported=0` (no pVM support on this host, so only non-protected VMs were run); hypervisor `cf-crosvm`; Microdroid kernel/initrd from that APEX (`androidboot.microdroid.build_id=CP2A.260605.016`). Real-phone hardware: UNMEASURED.

## B4. vsock protocol (`VmPayloadProtocol.kt`, `VsockVmTransport.kt`, `MicrodroidVmSession.kt`)

- Port 5000, host connects with `vm.connectVsock(5000)` after the guest signals `AVmPayload_notifyPayloadReady` (`onPayloadReady`); one connection and one request per VM.
- Host→guest: `[u8 task][u32 BE length][payload]`. Task 0 = file scan (payload = raw file bytes); task 2 = file scan with declared metadata (payload = `[u16 BE name_len][name UTF-8, ≤1024 B][u16 BE mime_len][mime ASCII, ≤255 B][file bytes]`; a too-long name or mime is sent empty, never truncated); task 1 (network samples) is defined but unused/removed in the guest. If the guest answers status 2 `{"error":"unknown task type"}` (old payload) the app retries once as task 0 in a new VM.
- Guest→host: `[u32 BE length][u8 status][UTF-8 JSON]`; status 0 = verdict, 1 = malformed structure, 2 = malformed request; any other value is an error. The host rejects a response longer than 10 MiB (`VsockVmTransport.kt:36`).
- File transport: the file is streamed from the `ContentResolver` input stream in 64 KiB chunks straight onto the vsock (`sendStream`), never fully buffered when the length is known (`openAssetFileDescriptor`); if the length is unknown the app buffers up to 150 MiB then sends. Max payload 150 MiB (`MAX_PAYLOAD_BYTES = 150*1024*1024`), enforced on the host before any VM is created.
- Timeouts: one `withTimeout` around create + boot + transfer + response, default 60 s, user-selectable 15/30/60/120 s (`WardenSettingsRepository.kt:46`, `SettingsScreen.kt:23`). The `/analyze/file` advisory call has its own 5 s connect/read timeouts and runs after the VM response.

## B5. Fail-closed behaviour per failure mode

All paths below end in `ScanResult.Failure` or `ScanResult.Error`; `AutoScanner.scan` (`AutoScanner.kt:28-35`) and `MainActivity.scanFile` (`MainActivity.kt:181-189`) quarantine anything that is not `Success`.

| Failure | Where | On-device |
|---|---|---|
| Oversize (> 150 MiB) | `TriggerRouter.kt:51-57` → `Failure("File too large (151 MB, max 150 MB)")`, before any VM | **Yes, and it exposes a bug**: scan rejected in 7 ms, no VM; the follow-up quarantine copy reads the whole file into the heap (`QuarantineManager.kt:22`, `readBytes()`), threw `OutOfMemoryError: Failed to allocate a 158400016 byte allocation … growth limit 201326592`, which killed the whole Warden process (including the VPN monitoring service) at 20:04:19; nothing was quarantined, the original stayed in Downloads, and monitoring stayed off until the app was reopened, a new VPN consent given, and monitoring restarted. So for files above roughly the app heap size the contain-first step crashes instead of containing. Not fixed (user decision) |
| Guest reports a malformed or flagged file (status 1/2, `cheap_filter_flagged`) | `TriggerRouter.kt:115-120,141-150` → `Failure` | Yes: truncated APK (100 000 B of the real APK, no ZIP end record) → FAILURE "no ZIP end-of-central-directory record found", total 1493 ms, quarantined |
| VM fails to boot / payload exits before ready / VM error / VM stops early | `MicrodroidVmSession.kt:61-76` complete `payloadReady` exceptionally → `catch (e: Exception)` `TriggerRouter.kt:181-184` → `Error` | UNMEASURED on device (needs fault injection) |
| Timeout | `withTimeout` `TriggerRouter.kt:73`, `catch TimeoutCancellationException` `:173-176` → `Error("Scan timed out")` | UNMEASURED on device (minimum timeout 15 s is longer than any scan observed) |
| Malformed / oversized response (empty, length > 10 MiB, invalid JSON, unknown status) | `VsockVmTransport.kt:36`, `decodeResponse`, `JSONObject(...)` inside the same try → `Error`; unknown status → `Error` (`TriggerRouter.kt:151-155`) | UNMEASURED on device; unit tests in `trigger-router` cover decode and status handling |
| Unrecognised but structurally sane file (txt, unknown) | guest returns status 0 with only `file_type` | **Fail-open by policy** (user decision 2026-09-29): "not analyzed, not flagged", not quarantined |

## B6. Concurrency

No application-level cap: every arriving file launches its own coroutine and its own VM (`NetMonitorService.kt:192-193`: `serviceScope.launch { scanner.scan(uri, name) }`; `FileArrivalWatcher.kt:93`). Four simultaneous scans were run (above timings) and four VMs ran at once. Sampled every 0.5 s with `ps -A -o RSS,NAME` (sum over the `crosvm` processes + the app's `virtmgr` process): peak **612 MB total RSS** (≈ 150 MB per VM) with 4 VMs, ≈ 11.7 MB for `virtmgr` alone; the samples were taken with 4 × 10 MiB files; PSS and a larger count (8, 16 VMs) are UNMEASURED. The 512 MiB guest allocation is not fully touched, which is why RSS is well below 4 × 512.

## B7. Quarantine flow (`QuarantineManager.kt`)

Location: `/data/data/com.noxos.app/files/quarantine/<random-uuid>.bin` (directory mode `drwx------`, file `-rw-------`, owner the app uid `u0_a44`, so no other app can read it). Flow: read the whole file (`readBytes`), write the copy, then `ContentResolver.delete(uri)` of the original (best effort, logged on failure, the copy is kept regardless), then a Room row (`quarantine_entries`: original name, MIME, stored name, reason, timestamp). Measured: for the truncated APK the copy (100 000 B) appeared, the original disappeared from `/sdcard/Download`, and the DB row recorded the reason. Restore: `MediaStore.Downloads` insert with `IS_PENDING`, write bytes, clear pending, delete the copy, remove the row; the restored id is remembered (`recentlyRestoredIds`) so the watcher does not re-scan it. Delete-permanently and age-based purge (default 30 days, options 30/90/180/365) remove the file then the row. Restore/delete were not exercised on this device pass — UNMEASURED this pass (earlier v3.1.0 pass covered the quarantine list). The copy is not encrypted. The heap-bound `readBytes()` is the bug in B5 (it also makes `restore` fail for huge files).

## B8. Privilege model

Platform-signed priv-app: `dumpsys package com.noxos.app` shows `codePath=/system/priv-app/Warden` for the baked-in 2.2.2 and the updated 3.2.0 under `/data/app/` with `flags=[ SYSTEM HAS_CODE … UPDATED_SYSTEM_APP … ]`, `privateFlags=[ … PRIVILEGED … ]`, versionCode 17, versionName 3.2.0. Requested and granted (from the same `dumpsys`): `android.permission.MANAGE_VIRTUAL_MACHINE: granted=true` (a signature|privileged permission), `MANAGE_EXTERNAL_STORAGE: granted=true`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_SPECIAL_USE`, `INTERNET`, `POST_NOTIFICATIONS: granted=true`, `BIND_VPN_SERVICE` on the service (the VPN consent dialog is shown separately). Allowlist file on the image: `/system/etc/permissions/privapp-permissions-warden.xml` containing exactly `<privapp-permissions package="com.noxos.app"><permission name="android.permission.MANAGE_VIRTUAL_MACHINE" /></privapp-permissions>`. `USE_CUSTOM_VIRTUAL_MACHINE` is not requested (the app uses the stock Microdroid and no custom kernel/payload path). Signature cert on this build: platform key (see B9). The VM is non-protected (`setProtectedVm(false)`), and this host has `protected_vm.supported=0`, so no pVM isolation was exercised.

## B9. apksigner verify, v3.2.0 release APK

`apksigner verify --verbose --print-certs app-release.apk` (build-tools 34): **Verifies**. v1 false, **v2 false, v3 true**, v3.1 false, v4 false, 1 signer: `CN=NoxOS Platform, OU=NoxOS, O=NoxOS, C=US`, RSA 4096, cert SHA-256 `950e2918ebbdcdb78faeaed28495dd68b1e97ba59c093031cb74ed0000703861`, public key SHA-256 `81658b118d37abe4baecc82867ab0ec003163dfec12c6488e354108ec2f3f1a9`. Note: the APK is v3-only, not v2+v3 (minSdk 33). APK sha256 `2cc8205e…b768` (equals GitHub's digest).

## B10. What the guest handles, and what leaves the VM

Handled (from the payload's own PAPER-RESULTS; not re-measured here): JPEG/EXIF, PNG/GIF/WebP structure, PDF, ZIP, APK (AXML permission pool, signing scheme, dex header and entropy), OOXML, ELF/PE checks, a 4-entry signature list; everything else fails open as `file_type: unknown`/detected type. Leaving the VM: only the response over vsock — status byte + JSON of feature keys (`file_type`, type-specific counts/flags, `cheap_filter_flagged`, `cheap_filter_reason`, and for APKs the `permissions` list). The file itself never leaves the device. The VM has no network device configured (none requested) — direct isolation of guest egress was not tested on this pass (UNMEASURED). The host then sends only `{"permission_strings":[…]}` to the optional `/analyze/file` endpoint, only for a clean APK with the toggle on (see the earlier section); EXIF values (GPS etc.) are returned to the host as strings but are not sent anywhere by the app.

## B11. FileArrivalWatcher (`FileArrivalWatcher.kt`)

Watches `MediaStore.Downloads.EXTERNAL_CONTENT_URI` through a `ContentObserver` registered with `notifyForDescendants = true` on the main looper (`registerContentObserver`, `FileArrivalWatcher.kt:57`). No debounce: every `onChange` runs a query for `DATE_ADDED >= lastSeen` ordered ascending; `NewFileTracker` accepts each (second, id) pair once (the same-second fix), skips ids the app itself just restored, and skips files whose `OWNER_PACKAGE_NAME` is in the FILE_SOURCE ACL as ALLOWED (a null owner is untrusted). It lives in `NetMonitorService` (so auto-scan runs while monitoring is on, even if the activity is closed), one coroutine per file. What the user sees: the home screen scan state while the app is open, an audit row per scan, a "Scan completion" notification (title = file name; "Scan complete — sanitized", "Scan complete — type not deeply inspected, not flagged", "Quarantined: <reason>", "Scan flagged: <reason>", plus an advisory line for APKs), and the entry in the quarantine list. Observed in the audit rows: files with an unrecognised type say "Unrecognized file type (unknown) — not analyzed, not flagged". Limitation seen on this pass: it only runs while monitoring is on, and a crash of the app (B5) turns it off silently.

## B12. VPN relay, ACL states, seeded list — confirmed against code

- `NetMonitorService` reads IP packets from the VPN tun, handles **IPv4 only** (`NetMonitorService.kt:271-272`, `version != 4 → continue`), **TCP (via `WardenTcpRelay`) and UDP (`relayUdp`)** only (`when (protocol) { 17, 6, else -> false }` at `:303-307`; other protocols, including ICMP, are not relayed). Sockets are `protect()`-ed so relay traffic bypasses the tunnel (`WardenTcpRelay: protect() returned true` in logcat).
- Per-destination-IP ACL (`acl_entries`): states ALLOWED / BLOCKED / FLAGGED. A first packet to an unknown IP inserts FLAGGED ("new destination, pending analysis", `:286-300`); a BLOCKED verdict drops packets and logs "blocked host" (`:278-284`); FLAGGED and unknown flows are **relayed** while pending (observed: `relayed (tcp)` with `flagged=1`). The autoencoder moves a flow to ALLOWED (session-only: `allow(..., sessionOnly = true)`) or to BLOCKED ("autoencoder: flagged … escalating to student"); the student/server answer allows (session-only) or blocks; a user override wins. `clearSessionVerdicts(NETWORK)` runs each time monitoring starts, so session verdicts do not persist across restarts.
- Seeded allow list (`AclSeed.kt`, reason "seeded: well-known"), verified in the DB: `8.8.8.8`, `8.8.4.4`, `1.1.1.1`, `1.0.0.1`.

## Battery / energy per scan

UNMEASURED (not measured on any build).

## Open issues found in this pass (for the user to decide)

1. Quarantine copy reads the whole file into the heap: an oversize (or any very large) flagged file crashes the whole app and silently turns monitoring and auto-scan off. Small fix: stream-copy with `copyTo` in `quarantine()` and `restore()`.
2. VM instance directories are not deleted after a scan (~340 KB per scan).
3. Persisted FLAGGED/BLOCKED rows from an older model are never rescored.
4. No cap on concurrent scans (4 VMs ≈ 612 MB RSS; boot time 2–3× slower).
