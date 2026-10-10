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
