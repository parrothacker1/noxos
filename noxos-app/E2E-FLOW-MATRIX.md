# End-to-end flow matrix (final live check, 2026-10-11)

Owner: Warden App (device runs). Inputs: Inference (live server on the laptop, 172.17.0.1:8080, token in a chmod 600 file, never in chat or logs), Payload (v1.0.6 guest), AWS (nothing needed). Run on the final released build (v3.3.1 or whatever the final tag is) on Cuttlefish, with the live server running the current binary. Record per case: build, server binary/model versions, exact input, observed outcome, timings, and the evidence (log excerpt or audit row id). A case that was not run is marked NOT RUN with the reason; nothing is estimated. Results go in `noxos-app/PAPER-RESULTS.md` section "E2E matrix", one row per case ID.

Environment limits to state in the paper: Cuttlefish with nested virtualization, non-protected VM; laptop-local server (not cloud); tiny synthetic flows from one device; teacher trained on UNSW-NB15, never evaluated on device features; autoencoder trained on MIRAGE normal-only (F1 unmeasured).

## A. Network path (VpnService relay, ACL, cascade)

| ID | Case | Expected |
|---|---|---|
| N1 | Unknown TCP destination, normal-shaped flow | allowed, autoencoder not flagged, no server call |
| N2 | Unknown UDP destination incl. real DNS (recalibrated UDP threshold) | not flagged (record flagged/total) |
| N3 | Flow shaped like a big upload (autoencoder flags) | destination BLOCKED until student answers |
| N4 | Student says not a threat | allowed for this monitoring session only |
| N5 | New monitoring session after N4 | session verdict cleared, destination re-evaluated |
| N6 | Student says threat, server reachable, teacher "block" | blocked, audit row with reasoning |
| N7 | Student says threat, teacher "allow" | allowed, session-only, reasoning shown |
| N8 | Teacher "uncertain" (0.4-0.6) | NOT allowed; stays blocked and asks the user |
| N9 | Server 422 (request missing features; force with a patched/old body or test hook) | stays blocked, falls back to user, no retry loop, missing names logged |
| N10 | Server 401 (wrong token) | stays blocked, falls back to user |
| N11 | Server stopped / timeout / unreachable | stays blocked, falls back to user |
| N12 | No endpoint configured | flagged UDP/TCP stays blocked until the student or user releases |
| N13 | Request body check | contains the ten feature names with proto as lowercase string and live stats (record the values sent) |
| N14 | User override ALLOW on a flagged destination | wins over every stage; survives model update and restart |
| N15 | User override BLOCK on an otherwise allowed destination | wins; survives restart |
| N16 | Seeded allow-list destination | allowed without evaluation |
| N17 | Autoencoder model download: ok / sha256 mismatch / network failure | ok loads; mismatch and failure fall back safely (record behaviour) |
| N18 | Model version change at runtime | session-only autoencoder verdicts cleared and destinations re-evaluated; user overrides untouched |
| N19 | Stale persisted FLAGGED rows at monitoring start | cleared and re-evaluated |
| N20 | Non-TCP/UDP or IPv6 traffic | not scored. The relay's scope is IPv4 TCP/UDP by design: ICMP and other protocols are not relayed (dropped), each logged as a flagged "not relayed" audit row with a notification; IPv6 packets are skipped. IPv6 is untestable when the guest has no IPv6 (NOT RUN). (Corrected 2026-10-11: the first version of this row said "passes", which was wrong.) |
| N21 | Teacher reasoning | TreeSHAP sentence references the sent feature values (not the defaults sentence seen on v3.3.0) |

## B. File path (arrival -> VM -> verdict -> quarantine)

| ID | Case | Expected |
|---|---|---|
| F1 | SAF picker scan: PNG, JPEG (with and without EXIF), PDF, plain text, DOCX, legacy OLE2 .doc/.xls, ZIP, gzip, tar, SVG/HTML, APK | clean files Safe; unsupported-but-sane "not analyzed, not flagged" (record each) |
| F2 | Files that must be flagged: EICAR, malformed/truncated APK, debug-signed APK, OLE2 with VBA macro, truncated PNG, encrypted ZIP, SVG with script | flagged or quarantined per policy; record reason strings |
| F3 | Declared-name/MIME mismatch (e.g. holiday_photo.jpg that is not a JPEG) | flagged |
| F4 | Warden's own release APK | scans clean, not quarantined (self-flag regression) |
| F5 | Auto-scan via Downloads watcher | runs while monitoring is on (app backgrounded); records audit row and notification |
| F6 | Four files pushed in the same second | four VMs / four audit rows (queue cap 2 in effect, record timings) |
| F7 | Oversize file (151 MB) | rejected, quarantined in full, app survives |
| F8 | Quarantine: list, restore, force-allow, retention purge | each works (restore of a huge file may be NOT RUN) |
| F9 | Trusted source package (FILE_SOURCE ALLOWED) | skipped by the watcher |
| F10 | `/analyze/file` for an APK with permissions | request carries permission strings only; advisory text shown; verdict and quarantine unchanged by it |
| F11 | `/analyze/file` server down/401/unconfigured | scan outcome unchanged, no crash, audit row notes advisory unavailable |
| F12 | Boot-failure fault injection | fail-closed: Error, file quarantined, no hang |
| F13 | Guest crash / exit != 0 | fail-closed |
| F14 | VM timeout | fail-closed |
| F15 | Malformed response from guest | fail-closed |
| F16 | Queue expiry (5 min wait) | Error, no VM booted, quarantined |
| F17 | Concurrency: 4 simultaneous scans | at most 2 VMs at once, all complete (record peak RSS, total time) |
| F18 | VM lifecycle | instance directories removed after each scan; none left after N scans |
| F19 | Timing series | warm N>=40 per phase (median, p95), cold N>=10 with real reboots |

## C. Platform and privilege

| ID | Case | Expected |
|---|---|---|
| P1 | `dumpsys package` | MANAGE_VIRTUAL_MACHINE granted, platform-signed priv-app |
| P2 | `apksigner verify` on the release APK | record signature scheme(s) |
| P3 | Payload in the APK | v1.0.6 hashes match release; no plaintext EICAR/metasploit strings |
| P4 | Update path | same-signature update keeps the grant (only if the user wants this claim) |

## Reporting rules
- One table row per ID in `PAPER-RESULTS.md` (PASS / FAIL / NOT RUN, with evidence). Any FAIL is a defect: report it to the root agent immediately, do not paper over it. Defects become a patch release only on the user's direct confirmation in Warden's session.
- Never put the token in a log, command line shown in docs, or commit.
- Not in this matrix because it cannot be built or measured here: pKVM on protected hardware, detection rates (no malware or attack corpus), real exploit samples, cloud deployment.
