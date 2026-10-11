# Deferred fixes and open items (2026-10-11)

User decision (2026-10-11): software work is stopped for now. Known issues below are documented, stated in the paper as limitations, and clubbed into one future release (Warden v3.3.2 or later, plus a payload release if payload items are taken). Nothing here is scheduled. Sources: noxos-app/PAPER-RESULTS.md ("E2E matrix", addenda), noxos-payload/PAPER-RESULTS.md, noxos-inference/PAPER-RESULTS.md.

## Warden app (noxos-app), copy-only fixes
1. Home screen text "Untrusted files and flagged traffic run inside a disposable VM, sealed from your device" is wrong on two counts: network traffic no longer enters a VM (network VM task removed 2026-09-29) and "sealed" overstates a non-protected VM.
2. Quarantine header "Files the scanner found genuinely malformed are held here" is wrong: the list also holds flagged files (EICAR, VBA/XLM macros, SVG script) that are not malformed.
3. Event detail banner "FLAGGED — SCAN DID NOT COMPLETE CLEANLY" shows for a scan that completed and flagged a macro; it reads like the error path. Step label "Boot sealed VM" has the same "sealed" problem.

## Warden app, behaviour
4. Files that arrive while monitoring is off or starting are not scanned (the watcher only sees files added after it registers; 3 of 20 reboots lost the first file).
5. F11: the audit row does not say the `/analyze/file` advisory was unavailable when the server is down, unauthorised or unconfigured.
6. A refused (never completed) connection attempt gets a high autoencoder reconstruction error and is flagged.
7. Non-first IP fragments of large UDP datagrams show as flagged "udp relay failed" rows on port 0.
8. ICMP is dropped by design with a flagged "not relayed" row and a notification per ping (N20, documented limitation). Option: pass ICMP through or suppress the alert.
9. One Start Monitoring after a force-stop logged "auditRepository was null at startMonitor(), stopping" (possible race, not investigated).
10. "Allowed manually" ACL entry did not appear on one device attempt (unverified, may be a test-state issue).
11. BOOTING median is higher on v3.3.1 (1069 ms warm) than the earlier v3.2.0 series (821 ms); cause not isolated. The v1.0.6 guest is slower per file than v1.0.5 (10 MiB: 147 ms vs 55 ms; 43.5 MB APK 423 ms vs 223 ms).
12. Pinned self-hosted copy of the AVF stub android.jar (CI currently pulls from the Microsoft mirror of AOSP prebuilts).
13. The "Sync Payload" workflow stays disabled (it auto-cuts a signed release); payload is synced by hand.

## Payload (noxos-payload)
14. HTML with a plain script tag is not flagged.
15. Formats without a parser fail open (ZIP64, other archive and document formats). Dynamic loadable signatures skipped (self-flag risk).
16. In-guest timing, 150 MiB file fit in the guest, and VM-boot cost of the v1.0.6 guest beyond the E2E series are only partly measured.

## Inference / models
17. Autoencoder F1 unmeasured (MIRAGE normal-only; 20 apps, 2 devices); real fix is retraining on real labelled traffic.
18. Teacher trained on UNSW-NB15, never evaluated on device-measured features; deployed teacher's held-out F1 unmeasured (the 0.9713 is the five fold models' out-of-fold score).
19. `/analyze/file` is advisory only and trained on 2012-era Drebin permissions; the on-device 4-of-14 permission rule is untested on popular apps (left as is by the user).
20. Cloud deployment of the server is unverified on the current binary (old EC2 box stopped; verification was laptop-local).

## Not testable or not run
21. F9 trusted-source package (MediaStore owner), F15 malformed guest frame, N17 checksum mismatch on device, IPv6 (guest has none), guest network egress, protected-VM (pVM) behaviour (no pKVM hardware), battery per scan, detection rates (no malware or attack corpus), real exploit samples.

## Housekeeping (user)
22. Retroactive GPG signing of unsigned commits (each repo's TASKS.md logs them).
23. Two old unattached EBS volumes (400 GB, 620 GB) may still bill; IAM gap for `ec2:ModifyInstanceAttribute`.
24. The ACL screenshots (`scr_acl.png`, `scr_acl_teacher_detail.png`) need the API key typed in the app by the user; optional for the paper.
25. Verify the three NVD pages in a browser before submission; fill the paper placeholders (authors, affiliation, guide, venue, page limit).
26. Push `context` (several local commits) when wanted.
