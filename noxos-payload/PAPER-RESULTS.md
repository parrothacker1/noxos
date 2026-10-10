# noxos-payload — paper-ready results (file-scan side)

Evaluated commit: `noxos-payload` `feab206` (2026-10-10), released as payload **v1.0.5**. All numbers below were produced on that commit unless a row says otherwise. "Unmeasured" means exactly that: not measured, not estimated.

## 0. What is and is not claimed

NoxOS/Warden isolates the parsing of untrusted files inside a one-shot Android Virtualization Framework (AVF) Microdroid VM. `noxos-payload` is the native program that runs *inside* that VM. This document covers the guest-side file scanner only.

- **Claimed:** a cheap (milliseconds), static, no-execution pre-filter that detects a set of structural anomalies and known-technique indicators in common file types, runs in isolation, and is tested, fuzzed, and swept against real files for false flags.
- **Not claimed:** a detection rate. There is **no malware corpus** in this evaluation. True-positive behavior is demonstrated only with synthetic files built to exhibit each structural condition (unit tests), not with real exploit samples. Detection rate against real malware is **unmeasured**.
- **Not an antivirus engine.** It has a 4-entry signature list, no ML, no dynamic execution, and by user decision it *fails open* for file types it cannot specifically parse (section 2.3).
- All false-flag results come from **one developer workstation's files** (mostly benign). They are a false-positive check on that set, not a population estimate.

## 1. Isolation architecture

```
Host (Warden app)                           Microdroid VM (AVF, one-shot, per file)
 file → read bytes → vsock ───────────────► libnoxos_payload_stub.so (AVmPayload_main)
                                              accept → ScanFile → JSON → exit
 verdict ◄──────────────────────────────────  VM destroyed by host after the response
```

- **Isolation boundary:** AVF/Microdroid VM created by the app per scan (`MicrodroidVmSession`); the file parser never runs in the app process. The guest holds only the bytes of the file being scanned.
- **Platform scope (project's stated boundary):** development and testing on a **Cuttlefish** virtual device (`cvd-1`), **non-protected** VM (`setProtectedVm(false)`): **no hardware root of trust**. Protected pKVM needs Pixel 6+ hardware and is out of scope. The isolation guarantee measured here is therefore AVF's software VM boundary, not a hardware-backed one. Escape resistance of the VM boundary itself was **not tested**.
- **VM resources:** the app does not set a memory size, so the VM runs at the AVF default. The captured crosvm launch line on `cvd-1` shows `--mem 256` (256 MiB) and 1 vCPU.
- **Guest binary:** one shared library, `libnoxos_payload_stub.so`, Soong-built (`cc_library_shared`) with the C++ runtime and zlib **statically linked** (`stl: "libc++_static"`, `static_libs: ["libz"]`). Static linking is deliberate: Microdroid's restricted linker namespace does not provide `libc++.so`, and a dynamic dependency caused the project's long-running `exit=1` failure (every payload build before v1.0.3 failed to `dlopen` on the device; fixed in v1.0.3). v1.0.5 artifacts: `x86_64` **267,376 B**, `arm64-v8a` **267,552 B** (v1.0.4: 267,320 / 267,496 B). `readelf -d` NEEDED on v1.0.5, both ABIs: only `libvm_payload.so`, `libc.so`, `libm.so`, `libdl.so`; no `libz.so`, no `libc++.so` (verified by the build session, 2026-10-10).
- **Wire contract** (vsock port 5000, one request per VM): host→guest `[u8 task][u32 BE length][payload]`; guest→host `[u32 BE length][u8 status][UTF-8 JSON]`.
  - Task 0: payload = raw file bytes (≤ 150 MiB = 157,286,400 B).
  - Task 2: payload = `[u16 name_len][name ≤1024 B][u16 mime_len][mime ≤255 B][file bytes]` (adds declared-name/MIME checks). Any other task type → status 2 `unknown task type`. (Former task 1, network samples, was removed 2026-09-29 as dead code.)
  - Status 0 = verdict JSON, always containing `file_type` plus type-specific feature keys, and `cheap_filter_flagged`/`cheap_filter_reason` only when flagged. Status 1 = malformed internal structure, status 2 = malformed request/size.
- **Policy (user decision, 2026-09-29):** **fail-open only for unsupported-but-structurally-sane files** (status 0, unflagged, `file_type` = detected type or `unknown`). Anything flagged, any status 1/2, and any VM error or timeout is **fail-closed** (the host quarantines). Consequence, stated plainly: an attacker who delivers a file of a type with no parser (for example RAR, 7z, gzip, tar, HTML, SVG, legacy OLE2 Office) is *not* flagged.
- **On-device validation:** payload v1.0.3 was confirmed end-to-end on the Cuttlefish device on 2026-09-22 (VM boot → payload → vsock request → verdict → clean exit, `exit status 0`; guest log shows `AVmPayload_main` entered at 1.382 s of guest uptime and "scan complete" at 1.395 s for a small PNG). **v1.0.4/v1.0.5 have not been run on a device by the author of this document: on-device behavior of the current checks is unmeasured.** The host app has not yet been observed sending task 2 (to the author's knowledge).

## 2. Implemented checks and what each targets

Source size at `feab206`: 2,032 lines of C++ for the scanner and entry point, 1,154 lines of tests, 77 lines of fuzz harnesses. The repository has no code comments by project rule.

### 2.1 Check inventory

| Area | Check | Targets (technique / CVE) | Evidence it works |
|---|---|---|---|
| JPEG / EXIF | EXIF TIFF/IFD parser with bounds-checking; segment-length validation | Parser-bug exploitation via inconsistent declared lengths. A pre-fix heap-buffer-overflow read from an attacker-controlled APP1 `seg_len` (12-byte input) was found and fixed (regression-seeded). | unit test, fuzz, regression seed |
| JPEG polyglot | Foreign magic after EOI (ZIP, gzip, ELF, PDF, PHP, `<script`, DEX, RAR, 7z); >4096 B trailing data; missing/short scan data | Appended-archive/executable image polyglots ("GIFAR"-style smuggling) | unit test |
| JPEG without EXIF | Parsed as clean `{"file_type":"jpeg","exif":"none"}` | Not an attack check: fixes a bug where the segment walk ran into compressed scan data and rejected every EXIF-less JPEG (screenshots, messaging-app photos) as malformed | unit test, real JPEG |
| ZIP structure | EOCD/central-directory bounds; local-vs-central name equality; **duplicate entry names**; overlapping entries; data before first entry (allowing a `PK\3\4` padding prefix); data after EOCD | **Master Key, CVE-2013-4787** (duplicate/mismatched entry names so verification and installation see different content); **Janus, CVE-2017-13156** (a DEX prepended to an APK so one file is both); overlapping-entry structure used by non-recursive bombs | synthetic tests reproducing each structural condition; **not tested against the original exploit APKs (unmeasured)** |
| ZIP bombs | declared uncompressed/compressed ratio >200:1 for entries ≥10 MiB; >1 GiB total declared; overlap check | **Fifield, "A better zip bomb" (WOOT 2019)**: overlapped, non-recursive bomb; ordinary high-ratio bombs | synthetic tests; **Fifield's published bomb files not obtained or tested (unmeasured)** |
| ZIP paths | leading `/` or `\`, drive letters, NUL, any `..` component | Zip-slip path traversal | unit test |
| ZIP content/name | ELF/DEX/PE magic inside entries named like data (images, text, media, fonts) | Payload hidden in assets | unit test |
| Encrypted ZIP | entries with the encryption flag; also APK "pseudo-encryption" | Archives whose contents cannot be inspected; anti-analysis flag on APKs | unit test, real `zip -P` archive |
| APK signing | detects APK Signing Block (v2/v3/v3.1) and v1 `META-INF` certs; flags unsigned; flags the Android debug certificate CN (`Android Debug`) in the signing block or v1 cert | Unsigned/test-signed (repackaged) APKs | real APKs; ground truth by provenance, not by `apksigner` (see 4.1) |
| APK permissions | binary-AXML string-pool parse (no full XML parse); flags SMS + accessibility together, or ≥4 of 14 listed high-risk permissions; emits the deduplicated permission names (≤2000, printable ASCII, ≤256 B) for the server | Banking-trojan permission combinations; feature source for server-side analysis | unit test; **rule untested on popular apps (unmeasured)** |
| APK `classes.dex` | header sanity (magic, endian tag, header size, header `file_size` == entry size, `map_off`, data bounds); known-bad signatures; entropy >7.2 bits/byte on the first 1 MiB | Malformed/truncated DEX, packed/encrypted code | unit test; entropy threshold from local measurement (see 5) |
| PDF | pdfid-style counts of `/JS /JavaScript /OpenAction /AA /Launch /EmbeddedFile /RichMedia /XFA /ObjStm /AcroForm /JBIG2Decode /URI /SubmitForm /GoToR` over raw bytes and inflated `/ObjStm` streams; `#xx`-obfuscated names; header offset; `%%EOF`; data after `%%EOF`; `startxref` validity. Flags: JavaScript + auto-action, `/Launch`, obfuscated keywords, structural anomalies | Document-borne JavaScript/launch actions; keyword hiding by hex escapes and object streams | unit tests incl. JS hidden in a compressed `/ObjStm` |
| OOXML | `*vbaProject.bin`; `/activeX/*.bin`; external relationships of type `attachedTemplate`, `oleObject`, `frame`, `subDocument` in every `.rels` part | VBA macros; **Follina, CVE-2022-30190** (remote template/object loaded through an external relationship); remote template injection | synthetic documents; **no real macro or Follina sample tested (unmeasured)** |
| PNG / GIF / WebP | PNG chunk walk with CRC32 verification, `IHDR`/`IEND`; GIF block walk to trailer; WebP RIFF size and chunk tiling; foreign magic or >4096 B after the image; declared pixel count >2^28 | Truncated/corrupt images, appended payloads, decompression-bomb dimensions | unit tests, 25,126 real images |
| Declared type (task 2 only) | Unicode bidi-override characters in the name; double extensions (`.jpg.apk`, `.pdf.exe` …); extension and MIME vs detected content (media↔media mislabels allowed) | RTLO filename spoofing; disguised executables | unit tests; **not yet exercised by the app (unmeasured)** |
| Signatures | EICAR; three Metasploit Android stager strings | Test/known-stager strings only. **This is not a signature database.** | unit tests |
| Packed executables | ELF/PE: `UPX!` marker in first 4 KiB, or whole-file entropy >7.2 | UPX/packed native binaries | unit test |

### 2.2 Features emitted for server-side analysis

Every status-0 response carries machine-readable features (examples: `zip_entries`, `zip_flag_count`, `zip_encrypted_entries`, `zip_uncompressed_total`, `apk_signing`, `permission_strings`, `high_risk_permissions`, `permissions[]`, `dex_version`, `dex_entropy`, `ooxml_*`, `pdf_*` keyword counts, `image_*`). ZIP/APK/OOXML collect *all* findings before reporting (a flagged file's features are complete); only the first finding becomes `cheap_filter_reason`. EXIF tag values are personal data (GPS, device identifiers) and must be redacted before any off-device forwarding; that redaction is **not implemented in the guest**.

### 2.3 Design stance

Checks are deliberately cheap and structural. The unit of evidence is a *declared-vs-actual* inconsistency (lengths, names, types, checksums) or a well-known indicator, because those are cheap in a VM-boot budget and have low false-positive rates on well-formed files (section 4).

## 3. Tests and fuzzing

### 3.1 Unit tests

**7 suites, 161 `assert()` calls**, all passing under AddressSanitizer + UndefinedBehaviorSanitizer (leak detection on) on `feab206`:

| Suite | asserts |
|---|---|
| exif_parser_test | 14 |
| file_cheap_filter_test | 16 |
| zip_scan_test (ZIP/APK/OOXML, includes a builder for ZIP, AXML, DEX, signing blocks) | 49 |
| pdf_scan_test | 25 |
| image_scan_test | 23 |
| file_scan_test (whole policy: fail-open, task-2 metadata framing, declared type) | 29 |
| self_signature_test (scans the test binary's own bytes for the built-in signatures) | 5 |

These counts are source `assert(` occurrences, not executed-assert counts. Tests are synthetic; they exercise each flag and the main non-flag paths.

### 3.2 Fuzzing

libFuzzer + ASan + UBSan, `-fno-sanitize-recover=all`, 6 harnesses (exif, file filter, zip/apk/ooxml, pdf, image, whole pipeline including task-2 metadata framing), seeded from 14 synthetic seed files, `-max_len=65536`. Final run on `feab206`: 60 s per harness, all six in parallel on a 12-thread Intel Core i7-1255U (clang 22.1.6, zlib 1.3.2, Linux 6.18.38):

| Harness | runs | errors |
|---|---|---|
| exif | 4,304,223 | 0 |
| file filter | 1,611,097 | 0 |
| zip / apk / ooxml | 1,342,896 | 0 |
| pdf | 636,088 | 0 |
| image | 1,020,393 | 0 |
| whole pipeline | 606,210 | 0 |
| **total** | **9,520,907** | **0** |

Earlier longer runs during development (minutes each, before the last two fixes) are not added to this total. CI runs a 60 s pass per harness on every push.

### 3.3 Real bugs found, by how

| Bug | Found by | Status |
|---|---|---|
| EXIF `seg_len` heap-buffer-overflow read (12-byte input) | adversarial input + ASan during the P7 fuzz/adversarial work | fixed, regression seed |
| `memmem(nullptr, 0, …)` undefined behavior at 3 call sites (signature scan, v1-cert scan, PDF stream search) | libFuzzer + UBSan (three separate crashes) | fixed |
| EXIF-less JPEGs rejected as malformed (segment walk did not stop at SOS) | reading the response path while implementing fail-open; reproduced on a real JPEG | fixed |
| `startxref` accepted any digit as valid | unit test | fixed |
| APK padding prefix (a harmless leading empty local header) flagged as "data before first entry" | real-file sweep (an APK from a test-tooling package) | fixed |
| An "embedded file + auto action" PDF rule flagged 2 real research PDFs (OpenAction is routinely just "open at page N") | real-file sweep | rule dropped |
| **Self-detection:** the plaintext signature list inside the payload `.so` (stored uncompressed in the APK) made Warden's own v3.1.0 APK flag as EICAR | real-file sweep, `feab206` | fixed by masking signatures at rest; regression test; **published v1.0.4 has this bug** |
| **PDF false positive:** `/JS`, `/AA` byte patterns inside inflated *binary* streams counted as keywords (2 Elsevier-template PDFs flagged as running JavaScript) | real-file sweep | fixed: names counted only in inflated `/ObjStm` streams |

## 4. Real-file sweeps (final code, `feab206`)

Method: every matching file found on one developer workstation, scanned through the full `ScanFile` pipeline (no payload-size cap applied on the host) with an ASan+UBSan build; own synthetic seeds and scratch directories excluded. **Sanitizer errors across all 25,586 scanned files: 0.** Status was 0 for every scanned file.

| Set | files | MB | flagged | outcome |
|---|---|---|---|---|
| APK | 19 | 821.8 | 12 | 11 debug-certificate (correct), 1 EICAR (explained below) |
| PDF | 310 | 376.6 | **0** | 0 false flags; includes the 10 Elsevier template PDFs that were false-flagged before the fix |
| Office (docx/xlsx/pptx/docm/xlsm) | 131 | 12.7 | 1 | the flagged file is a deliberately truncated 4,096 B test fixture |
| PNG / GIF / WebP | 25,126 (from 25,204 list entries) | 3177.5 | 5 | all five structurally defective (below) |

### 4.1 APKs (19)

- 7 clean: Warden release builds v2.2.1–v3.0.0 (several), the Warden check build, and the AOSP `MicrodroidDemoApp`.
- 11 flagged `signed with the Android debug certificate`: 9 Warden debug/early builds and the 2 Playwright test-driver APKs. Ground truth here is provenance (debug builds by name and origin), **not** an independent `apksigner` verification (unmeasured); all 11 do carry the `Android Debug` CN the check looks for.
- 1 flagged `contains EICAR antivirus test string`: **`app-release-v3.1.0.apk`, Warden's own release**. Cause: that APK bundles payload **v1.0.4**, whose native library holds the scanner's plaintext signature list; libraries are stored uncompressed in an APK, so the raw-byte signature scan matches it (a scanner flagging itself, the classic signature-database self-detection problem). Fixed in `feab206`/v1.0.5 (signatures XOR-masked at rest). **No Warden APK that bundles v1.0.5 existed when this was measured, so the fix could not be confirmed on a real Warden APK.** What was verified instead, on the released binaries: v1.0.4 libraries (extracted from the v3.1.0 APK) packed into a stored ZIP are flagged as EICAR for both ABIs; the v1.0.5 libraries packed into a plain stored ZIP are **not** flagged (type `zip`, both ABIs); and `strings -a` finds 0 occurrences of the EICAR or Metasploit strings in both v1.0.5 libraries (build session). This is a reproduction, not the real artifact.

### 4.2 PDFs (310)

Before the object-stream fix, the same real set (plus the author's own synthetic seeds) flagged 2 real PDFs as running JavaScript; after the fix the final set has 0 flags. With 0 false flags in 310 clean PDFs, the one-sided 95% upper bound on the false-flag rate for *this kind of file* is about 1% (rule of three, 3/310). No real malicious PDF was tested: **PDF detection rate is unmeasured.**

### 4.3 Office files (131)

126 classified OOXML, 1 truncated ZIP (flagged: no end-of-central-directory record), 4 classified `ole2` (password-encrypted `.xlsx` fixtures, which are OLE2 containers). Zero VBA macros, ActiveX controls, or dangerous external relationships exist in this set, so **true-positive behavior on real macro/Follina documents is unmeasured**; it is shown only with synthetic documents. The 4 OLE2 files are *not* deep-checked (fail-open).

### 4.4 Images (25,126 rows)

Types: 24,696 PNG, 290 GIF, 134 WebP, 6 files named `.png` that are not images (they begin with `EF BF BD`, a UTF-8 replacement character: text-mode-damaged copies; detected as `unknown`). Five flagged:

| Flag | File | Judgment |
|---|---|---|
| PNG has no IEND (×2), 4 CRC mismatches, … | three Go standard-library test images named `invalid-*` | correct: deliberately invalid |
| IDAT CRC error and a mangled IEND header declaring 1.6 GB | a documentation `logo.png` | correct: corrupt file |
| GIF block runs past end of file | one 1×1 tracking-pixel GIF | structurally defective (comment extension declares 30 bytes, holds 10); lenient decoders may still display it, so this is the one arguably debatable flag |

False-flag count: 0 if the five are judged defective as above; 1 if the lenient-decoder GIF is counted as benign. 77 file names contain newlines and were re-joined; the remaining 78 list entries were fragments of those split names, not additional files.

## 5. Performance (host, optimized build)

Measured on the workstation above, `-O2`, `ScanFile` call only (excludes reading the file and the vsock transfer), median of 5 runs:

| Input | size | scan time | process peak RSS (host harness) |
|---|---|---|---|
| APK, smallest | 0.6 MB | 5.6 ms | 5.8 MB |
| APK | 7.6 MB | 8.6 ms | 12.9 MB |
| APK (Warden v3.1.0) | 43.5 MB | 3.8 ms | 68.8 MB |
| APK, largest | 57.3 MB | 19.0 ms | 69.3 MB |
| PDF, largest | 10.0 MB | 10.7 ms | 21.0 MB |
| PNG, largest | 17.9 MB | 10.9 ms | 36.8 MB |
| Office, largest | 1.0 MB | 0.7 ms | 5.1 MB |
| 150 MiB random ELF (worst case for the entropy pass) | 157.3 MB | 87.9 ms | 261.3 MB |
| 150 MiB zeros (untyped) | 157.3 MB | 31.0 ms | 260.9 MB |

Notes on reading this table: (1) peak RSS comes from the harness that reads the file through a growing buffer, so it is *larger* than a guest that receives the length first and allocates once; scan overhead beyond the read was ≈0–1 MB in every row. (2) Times are for a 12-thread desktop CPU; **in-guest time on a 1-vCPU Microdroid VM, the vsock transfer time, and VM boot time for these builds are unmeasured.** The only guest timing available is the 2026-09-22 v1.0.3 log (payload entered 1.382 s after guest boot). (3) **Whether a 150 MiB file fits in the default 256 MiB guest alongside the guest OS is unmeasured**; the design needs about file size + a few MiB. A guest out-of-memory would surface as a payload exit (fail-closed), not silent truncation.

Threshold provenance: the entropy threshold of 7.2 bits/byte was chosen from local measurement: all `classes*.dex` files examined during development (about 13 files across 4 APKs) measured 5.05–6.73 bits/byte, random data ≈ 7.99. That set is small; the threshold is hand-picked, not tuned on a labeled corpus.

## 6. Limitations (explicit)

1. **No detection-rate evaluation.** No malware corpus; all true-positive evidence is synthetic. No real Master Key, Janus, Follina, macro, malicious-PDF, or Fifield-bomb samples were tested.
2. **Permission heuristic untested on popular apps.** The ≥4-of-14 high-risk-permission rule and the SMS+accessibility rule are hand-picked, not derived from the cited research's exact features, and have never been run against a corpus of popular Play Store apps; their false-flag rate on such apps is unknown and could be high (many legitimate apps request several of the 14).
3. **Hand-picked thresholds:** entropy 7.2 bits/byte, zip-bomb ratio 200:1 at ≥10 MiB, 1 GiB total, 4096 B trailing data, 2^28 pixels, 4 permissions. None tuned on labeled data.
4. **No signature database:** four compiled-in strings (EICAR plus three Metasploit stager strings). No dynamic or updatable signatures.
5. **ZIP64 is not parsed** (reported as zero entries, unflagged). ZIP64 inputs are not inspected.
6. **Only `classes.dex` is deep-checked** in APKs, not `classes2.dex … classesN.dex`; nested archives are scanned one level only; native `.so` files inside APKs are not analyzed.
7. **Encrypted archives are opaque:** encrypted ZIP entries are flagged, but password-protected OOXML (OLE2-wrapped) and other encrypted containers are not inspected and, being OLE2, fail open.
8. **Fail-open by policy** for unparsed types: RAR, 7z, gzip, tar, OLE2 (`.doc/.xls/.ppt`, `.msi`), HTML, SVG, scripts, and others pass unflagged unless a signature or ELF/PE check hits.
9. **PDF scope:** only zlib-compressed `/ObjStm` streams are inflated (other filters, encryption, and incremental-update tricks are not decoded); keywords are counted over raw bytes as pdfid does, so a random byte collision in compressed data is possible in principle (0 observed in 310); a wrong `/Length` or parser-differential tricks are not modeled; `/Encrypt` is not flagged.
10. **Non-protected VM:** no hardware root of trust; VM-escape resistance was not tested; the scanner's own bugs are contained only by that software boundary.
11. **The declared-name/MIME check (task 2) is implemented but not yet used by the app** (to the author's knowledge). v1.0.4/v1.0.5 are not validated on a device.
12. **False-flag evidence is one workstation, mostly developer artifacts**, not a representative file population; counts, not rates, are the honest statement.
13. **Published v1.0.4 flags APKs that embed it (including Warden's own v3.1.0)**; fixed in v1.0.5, which is not yet bundled in a Warden release.
14. **Guest memory:** 150 MiB payload cap vs the default 256 MiB guest is unverified.
15. **Privacy:** EXIF values returned in status-0 JSON are personal data; redaction before any server upload is the host's responsibility and is not implemented in the guest.

## 7. Backlog not started

OLE2 macro detection (legacy `.doc/.xls/.ppt`; compound-file directory walk for `VBA`/`_VBA_PROJECT`/`Macros`/`EncryptedPackage`); RAR / 7z / gzip / tar identification with appended-data checks (7z start-header CRC and size consistency, gzip trailer and expansion ratio, tar header-checksum and path-traversal walk); `classes2…N.dex` header checks; HTML/SVG smuggling patterns (script in SVG, HTML smuggling via blob URLs, script one-liners); APK `targetSdkVersion`/`sharedUserId` via AXML attributes; dynamically loadable signatures; PNG/GIF ancillary-chunk checks.

## 8. Reproduction

```
git -C noxos-payload checkout feab206
clang++ -std=c++17 -g -fsanitize=address,undefined -o zip_scan_test zip_scan.cpp test/zip_scan_test.cpp -lz && ./zip_scan_test
# (same pattern for exif_parser, file_cheap_filter, pdf_scan, image_scan, file_scan, self_signature; see README "Testing & Fuzzing")
clang++ -std=c++17 -g -O1 -fsanitize=fuzzer,address,undefined -fno-sanitize-recover=all -o zip_fuzzer zip_scan.cpp fuzz/zip_scan_fuzzer.cpp -lz
mkdir -p corpus && cp fuzz/seeds_zip/* corpus/ && ./zip_fuzzer corpus -max_total_time=60 -max_len=65536
```

Release artifacts: `https://github.com/parrothacker1/noxos-payload/releases/tag/v1.0.5` (built from `feab206`). Commit history for the file-scan work: `a56c29f` (ZIP/APK, network code removed, 150 MiB cap), `92f34c1` (fail-open, task 2, encrypted ZIP, PDF, OOXML), `c1ba94b` (permission names), `6f777a6` (images), `feab206` (self-detection and PDF fixes).

## 9. References

Cited from memory by the author; **verify each URL and date before submission.**

- CVE-2013-4787, "Master Key" Android APK signature bypass via duplicate ZIP entry names: https://nvd.nist.gov/vuln/detail/CVE-2013-4787 (disclosed by Bluebox Security, July 2013).
- CVE-2017-13156, "Janus" Android DEX/APK dual-file signature bypass: https://nvd.nist.gov/vuln/detail/CVE-2017-13156 (disclosed by GuardSquare, December 2017).
- CVE-2022-30190, "Follina" Microsoft Support Diagnostic Tool remote code execution through a remote Office template/object: https://nvd.nist.gov/vuln/detail/CVE-2022-30190 (Microsoft MSRC guidance, 2022).
- D. Fifield, "A better zip bomb," 13th USENIX Workshop on Offensive Technologies (WOOT '19), 2019. https://www.bamsoftware.com/hacks/zipbomb/
- Zip Slip vulnerability research, Snyk, 2018. https://security.snyk.io/research/zip-slip-vulnerability
- D. Stevens, pdfid / PDF tools. https://blog.didierstevens.com/programs/pdf-tools/
- EICAR anti-malware test file. https://www.eicar.org/download-anti-malware-testfile/
- Android APK Signature Scheme v2/v3; Dalvik Executable format; Android Virtualization Framework. https://source.android.com/docs/security/features/apksigning , https://source.android.com/docs/core/runtime/dex-format , https://source.android.com/docs/core/virtualization
- Permission-based APK detection and static-scanner design ideas (an arXiv entropy+structure+YARA lightweight scanner; a static-analysis survey of malicious-APK detection): relayed by the project's root agent; **not independently fetched or replicated here, and the permission rule above is not a replication of any cited result.**
