# noxos-payload — paper-ready results (file-scan side)

Evaluated commit: `noxos-payload` `2b94021` (2026-10-11), the code intended for payload **v1.0.6**. v1.0.5 was released from `feab206`; **v1.0.6 has not been built or released, so its binary size is unmeasured**. All numbers below were produced on `2b94021` unless a row says otherwise. "Unmeasured" means exactly that: not measured, not estimated.

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

Source size at `2b94021`: 3,781 lines of C++ for the scanners and entry point, 2,178 lines of tests, plus the fuzz harnesses. The repository has no code comments by project rule.

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
| OLE2 (legacy Office) | compound-file header/FAT/DIFAT/directory walk with bounds and loop checks; VBA project storages (`VBA`, `_VBA_PROJECT`, `_VBA_PROJECT_CUR`, `Macros`, `PROJECTwm`); Excel 4.0 (XLM) macro sheets and VBA module sheets from BIFF `BOUNDSHEET` records; encryption (`EncryptedPackage`, BIFF `FilePass`); data after the last used sector | VBA/XLM macro delivery; password-protected-document evasion; structural parser exploits | independent Python directory lister on real files; synthetic compound-file builder tests; **real malicious macro documents untested (unmeasured)** |
| gzip | zlib stream inflate with CRC/trailer verification, concatenated members, 64 MiB output cap, ratio >200:1 at ≥10 MiB, truncation, reserved header bits, trailing data or foreign magic; inner tar walked on the first 8 MiB | Decompression bombs; appended payloads; tar-in-gzip path escape | tests + 40,620 real `.gz` files |
| tar | header-checksum walk (GNU sparse supported), size overflow, entry past EOF, `..`/absolute names, symlink/hardlink escapes, >1 GiB declared, data after the end marker | Tar path-traversal and symlink-escape extraction attacks (the CVE-2007-4559 class); tar bombs | tests + 84 real tars |
| 7z | start-header CRC, next-header range and CRC, trailing data, AES coder-id heuristic, version | Corrupt/appended 7z; encrypted 7z | tests + 5 real archives |
| RAR 4 / 5 | block walk with header CRC (RAR4 CRC16 on non-file blocks, RAR5 CRC32), encrypted headers/files, entry-name escape, end block, trailing data | Corrupt/appended RAR; password-protected RAR; extraction path escape | tests + 4 real archives |
| APK DEX (all files) | every root `classes*.dex`: magic, endian tag, header size, header `file_size` vs entry size, `map_off`, data bounds, signatures, entropy >7.2 | Malformed or packed multi-dex payloads | tests + 21 real APKs |
| APK manifest attributes | `targetSdkVersion`, `minSdkVersion`, `sharedUserId` (boolean + privileged `android.uid.*`), `debuggable` from AXML nodes (resource-id map, name fallback). Flags: privileged shared UID; target SDK <23 together with ≥2 high-risk permissions | Privileged shared-UID abuse; legacy-SDK runtime-permission bypass | tests; `debuggable` matched the debug-signed builds exactly on real APKs; **the two flag rules never fire on real files (true-positive behavior synthetic only)** |
| HTML / SVG / script | HTML/SVG indicators are evaluated only inside `<script>` blocks: HTML smuggling (Blob API + download trigger + decoded data within 4 KiB), `eval` of decoded strings, PowerShell encoded commands (needs a real ≥24-character base64 argument), PowerShell download-and-execute cradles (call-shaped `iex`/`iwr`/`irm` within 1 KiB), `WScript.Shell`/`Shell.Application` launch, living-off-the-land binaries (whole words). Script files only: `base64 -d` piped to a shell, `/dev/tcp` reverse shells. SVG: `<script>`, event-handler attributes, `javascript:` URLs, iframe/object in `foreignObject` | HTML smuggling; script one-liners; active SVG | tests + 114,409 real files |
| PNG / GIF ancillary | PNG: single IHDR, PLTE before IDAT, contiguous IDAT, IDAT present, unknown critical chunks, unknown ancillary chunk >64 KiB, text chunk >1 MiB. GIF: comment extension >64 KiB, application extension >256 KiB | Payloads hidden in ancillary chunks/extensions; malformed chunk order | tests; **the rules fire on none of 24,974 real PNG/GIF files (true-positive behavior synthetic only)** |

### 2.2 Features emitted for server-side analysis

Every status-0 response carries machine-readable features (examples: `zip_entries`, `zip_flag_count`, `zip_encrypted_entries`, `zip_uncompressed_total`, `apk_signing`, `permission_strings`, `high_risk_permissions`, `permissions[]`, `dex_version`, `dex_entropy`, `ooxml_*`, `pdf_*` keyword counts, `image_*`). ZIP/APK/OOXML collect *all* findings before reporting (a flagged file's features are complete); only the first finding becomes `cheap_filter_reason`. EXIF tag values are personal data (GPS, device identifiers) and must be redacted before any off-device forwarding; that redaction is **not implemented in the guest**.

### 2.3 Design stance

Checks are deliberately cheap and structural. The unit of evidence is a *declared-vs-actual* inconsistency (lengths, names, types, checksums) or a well-known indicator, because those are cheap in a VM-boot budget and have low false-positive rates on well-formed files (section 4).

## 3. Tests and fuzzing

### 3.1 Unit tests

**10 suites, 362 `assert()` calls**, all passing under AddressSanitizer + UndefinedBehaviorSanitizer (leak detection on) on `2b94021`:

| Suite | asserts |
|---|---|
| exif_parser_test | 14 |
| file_cheap_filter_test | 16 |
| zip_scan_test (ZIP/APK/OOXML incl. DEX and manifest attributes; builders for ZIP, AXML, DEX, signing blocks) | 67 |
| pdf_scan_test | 25 |
| image_scan_test (PNG/GIF/WebP incl. ancillary rules) | 40 |
| ole2_scan_test (compound-file and BIFF builders) | 24 |
| archive_scan_test (gzip via zlib; hand-built tar, 7z, RAR4, RAR5) | 68 |
| text_scan_test | 71 |
| file_scan_test (whole policy: fail-open, task-2 framing, declared type, routing) | 32 |
| self_signature_test (scans the test binary's own bytes for the built-in signatures) | 5 |

These counts are source `assert(` occurrences, not executed-assert counts. Tests are synthetic; they exercise each flag and the main non-flag paths, including a regression test for every false flag found in the real-file sweeps.

### 3.2 Fuzzing

libFuzzer + ASan + UBSan, `-fno-sanitize-recover=all`, 9 harnesses (exif, file filter, zip/apk/ooxml, pdf, image, ole2, archive, text, whole pipeline including task-2 framing), seeded from synthetic seed files, `-max_len=65536`. Final run on `2b94021`: 60 s per harness, all nine in parallel on a 12-thread Intel Core i7-1255U (clang 22.1.6, zlib 1.3.2, Linux 6.18.38):

| Harness | runs | errors |
|---|---|---|
| exif | 2,517,276 | 0 |
| file filter | 3,331,280 | 0 |
| zip / apk / ooxml | 918,749 | 0 |
| pdf | 387,949 | 0 |
| image | 1,114,793 | 0 |
| ole2 | 317,529 | 0 |
| archive (gzip/tar/7z/rar) | 1,150,985 | 0 |
| text | 210,470 | 0 |
| whole pipeline | 487,755 | 0 |
| **total** | **10,436,786** | **0** |

Longer development-time runs (minutes each) are not added to this total. CI runs a 60 s pass per harness on every push.

### 3.3 Real bugs found, by how

| Bug | Found by | Status |
|---|---|---|
| EXIF `seg_len` heap-buffer-overflow read (12-byte input) | adversarial input + ASan during the P7 fuzz/adversarial work | fixed, regression seed |
| `memmem(nullptr, 0, …)` undefined behavior at 3 call sites (signature scan, v1-cert scan, PDF stream search) | libFuzzer + UBSan | fixed |
| EXIF-less JPEGs rejected as malformed (segment walk did not stop at SOS) | reproduced on a real JPEG | fixed |
| `startxref` accepted any digit as valid | unit test | fixed |
| APK padding prefix flagged as "data before first entry" | real-file sweep | fixed |
| "embedded file + auto action" PDF rule flagged 2 real research PDFs | real-file sweep | rule dropped |
| **Self-detection:** plaintext signature list inside the payload `.so` (stored uncompressed in the APK) made Warden's own v3.1.0 APK flag as EICAR | real-file sweep | fixed by masking signatures at rest; regression test; **published v1.0.4 has this bug, v1.0.5 does not** |
| **PDF false positive:** `/JS`, `/AA` byte patterns inside inflated binary streams counted as keywords | real-file sweep | fixed: names counted only in `/ObjStm` streams |
| **ZIP mis-routing:** any file with a `PK\5\6` record in its last 64 KiB went to the ZIP scanner, so ~20 real OLE2 `.xls/.ppt/.pub` files were flagged "appended data after ZIP end record" | real-file sweep (OLE2) | fixed: ZIP scanner only for `PK` files or when a ZIP genuinely ends the file (keeps Janus-style prepended-DEX detection) |
| `ParseOctal` never stored its result (every tar header checksum failed) | compiler warning (`-Wunused-parameter`) + unit test | fixed |
| GNU sparse tar entries mis-walked (extension blocks not skipped) | real-file sweep (Go `sparse-formats.tar`) | fixed |
| Text heuristics matched scattered tokens in multi-megabyte JS bundles and documentation, tool names inside base64 data, installer scripts, PowerShell alias lists, and command deny-list object keys (51 flags on first sweep) | real-file sweep, 4 iterations | fixed with script-block scoping, whole-word and call-shape matching, 1-4 KiB proximity rules, object-key exclusion; 10 flags remain, all explained (4.7) |
| "gzip contains an ELF" flagged kernel images and a core dump | real-file sweep | decision: feature (`gzip_inner`), not a flag |

## 4. Real-file sweeps (final code, `2b94021`)

Method: every matching file found on one developer workstation, scanned through the full `ScanFile` pipeline (no payload-size cap applied on the host) with an ASan+UBSan build; own synthetic seeds and scratch directories excluded; text-like files scanned with their file name (task-2 behavior) so that `.js/.ps1/.bat/.sh` are recognized as scripts. **Sanitizer errors across every sweep: 0.** File names containing tabs or newlines split some result rows; rows that could not be re-joined are excluded from the counts below and stated as such.

| Set | files scanned | MB | flagged | outcome |
|---|---|---|---|---|
| APK | 21 | ~810 | 12 | 11 debug-certificate (correct), 1 EICAR (Warden v3.1.0, explained) |
| PDF | 299 (of 300 listed) | 366 | **0** | includes the 10 Elsevier template PDFs |
| Office OOXML + encrypted OLE2 | 131 | 13 | 5 | 4 password-encrypted `.xlsx` fixtures, 1 truncated test fixture |
| OLE2 (legacy Office, msi, other) | 109 ole2-typed rows, 67 unique by content | 603 | 11 of 67 unique | 5 truncated fixtures, 4 VBA projects, 2 encrypted |
| PNG / GIF / WebP | 25,112 (of 25,204 listed) | 3,076 | 5 | all structurally defective |
| gzip / tgz | 40,492 (of 40,620 listed) | 927 | 9 | all explained |
| tar / 7z / RAR | 84 / 5 / 4 | 286 (with 7 other) | 8 | all explained; 7z and RAR 9/9 clean |
| HTML / SVG / scripts (+20,000 random `.js`) | 114,409 (of 114,869 listed) | n/a | 10 | all explained |

### 4.1 APKs (21 real APK files; several are byte-identical copies)

- Clean (9): Warden v3.0.0, **v3.2.0 and v3.2.1 (the current release)**, v2.2.1–v2.2.4 builds, the Warden check build, and the AOSP `MicrodroidDemoApp`.
- 11 flagged `signed with the Android debug certificate`: 9 Warden debug/early builds and the 2 Playwright test-driver APKs. Ground truth is provenance (debug builds by name and origin), not independent `apksigner` verification (unmeasured). All 11 also report `apk_debuggable: true`, the only APKs that do, which is an independent cross-check of the manifest parser.
- 1 flagged `contains EICAR antivirus test string`: **`app-release-v3.1.0.apk`**, which bundles payload v1.0.4 with plaintext signatures (see 3.3). **Warden v3.2.0 and v3.2.1 do not self-flag**: their bundled `libnoxos_payload_stub.so` files (v3.2.1: 267,552 B arm64-v8a, 267,376 B x86_64, the v1.0.5 sizes) contain no plaintext signature string.
- The new manifest rules (privileged shared UID; target SDK <23 with ≥2 high-risk permissions) flag **zero** real APKs. Real values: Warden targetSdk 35 / minSdk 33; MicrodroidDemoApp 33/33; Playwright driver 29/21; dex counts 1–9 as expected.

### 4.2 PDFs (299)

0 flagged (the object-stream fix removed the 2 Elsevier-template false flags of the first sweep). With 0 false flags in 299 PDFs the one-sided 95% upper bound on the false-flag rate for this kind of file is about 1% (rule of three). No real malicious PDF was tested: **PDF detection rate is unmeasured.**

### 4.3 Office files and OLE2

- 131 Office-extension files: 126 OOXML, 4 OLE2 (password-encrypted `.xlsx`, all 4 now flagged as encrypted, by design), 1 truncated ZIP fixture. Zero OOXML macros, ActiveX controls, or dangerous external relationships exist in this set: **true-positive behavior on real macro/Follina documents is unmeasured**.
- OLE2 candidates (584 paths by extension/magic; 67 unique OLE2 files by content): 56 clean (documents, `.msi` installers up to 85 MB, `.msg`, `.sdv`), 11 flagged: 5 truncated 2–4 KB test fixtures (correct), 4 VBA projects (two Microsoft Project `.mpp` templates, one Publisher file, one `vbaProject.bin`; confirmed with an independent Python directory lister; Project and Publisher templates ship a VBA project that may be empty, so the finding is "VBA project present", not "malicious"), 2 encrypted. No unexplained false flag.

### 4.4 Images (25,112 rows)

24,684 PNG, 290 GIF, 132 WebP, 6 files named `.png` that are not images (text-mode-damaged copies, typed `unknown`). Five flagged, identical to the earlier sweep: three Go standard-library `invalid-*` test PNGs, a corrupt documentation `logo.png` (bad IDAT CRC, mangled IEND), and one 1×1 tracking-pixel GIF whose comment extension declares more bytes than it holds (structurally defective; lenient decoders may still display it: the one arguably debatable flag). False-flag count: 0, or 1 if that GIF is judged benign. The new ancillary-chunk rules fired on none of these files.

### 4.5 Archives

- RAR (4) and 7z (5): all clean on real archives, which validated the RAR CRC logic and the 7z header checks.
- tar (84): 8 flagged: 3 truncated minikube image-cache downloads (a 545 MB entry cut off at 5, 42 and 102 MB), Go `writer-big.tar` (declares >1 GiB), Python `testtar.tar` (symlink escape) and `recursion.tar` (declared-size fixture), `pg_control.tar` (absolute entry path: GNU tar strips the slash, so this one is debatable).
- gzip (40,492 of 40,620 listed; 927 MB): 9 flagged: 7 byte-identical copies of a klauspost `issue6550.gz` fixture (reserved header bits set on purpose), 1 truncated `.json.gz` temporary download, `pg_control.tar.gz` (the same absolute path). 3 gzip files that contain ELF executables (kernel images, a core dump) are deliberately **not** flagged.

### 4.6 What the first text sweep showed (kept for honesty)

The first sweep of the text heuristics flagged **51 of 114,386** files: JS bundles with scattered tokens, documentation pages that mention tools, installer scripts, alias lists, base64 data containing "mshta". Four rounds of fixes driven by those files reduced the count to 10; none of the fixes weakened the synthetic true-positive tests.

### 4.7 Text-like files after the fixes (114,409 rows: 78,954 HTML, 13,106 SVG, 21,839 scripts)

10 flagged:
- 5 HTML pages using `eval(unescape(…))` (old analytics/obfuscation in test data: `metalreview.html` ×3, a German test page, a bank list): the rule's description is accurate (evaluates an unescaped string) but the pages are benign.
- 1 PowerShell test script with a Chocolatey install cradle in a **comment**, and 1 nvim installer `.cmd` that is a self-executing PowerShell wrapper plus `Invoke-WebRequest`: patterns present, intent benign.
- 3 Inkscape wallpaper SVGs with the standard gradient-mesh polyfill `<script>`. This is a known false-flag class; it is not whitelisted by element id, because an attacker could copy the id.

Counted strictly, these are 10 false-flag-like results out of 114,409 (0.009%), all of them real instances of the described pattern with benign intent.

## 5. Performance (host, optimized build)

Measured on the workstation above, `-O2`, `ScanFile` call only (excludes reading the file and the vsock transfer), median of 5 runs:

| Input | size | scan time | process peak RSS (host harness) |
|---|---|---|---|
| APK, smallest | 0.6 MB | 5.2 ms | 5.8 MB |
| APK | 7.6 MB | 9.2 ms | 13.0 MB |
| APK (Warden v3.2.1) | 43.5 MB | 15.3 ms | 68.0 MB |
| APK, largest | 57.3 MB | 20.9 ms | 67.9 MB |
| PDF, largest | 10.0 MB | 10.2 ms | 20.9 MB |
| PNG, largest | 17.9 MB | 10.8 ms | 36.9 MB |
| OLE2 (`.msi`), largest | 85.5 MB | 25.9 ms | 132.9 MB |
| gzip, largest (inflates up to the 64 MiB cap) | 108.2 MB | 383.6 ms | 132.9 MB |
| tar, largest | 102.1 MB | 30.1 ms | 132.9 MB |
| 150 MiB random ELF (worst case for the entropy pass) | 157.3 MB | 107.0 ms | 259.8 MB |
| 150 MiB zeros (untyped) | 157.3 MB | 33.1 ms | 259.8 MB |

Notes: (1) peak RSS comes from a harness that reads the file through a growing buffer, so it is *larger* than a guest that receives the length first and allocates once (hence identical values for three different large inputs: buffer doubling to 128 MiB); scan overhead beyond the read is a few MB, except gzip, which adds its 8 MiB inspect buffer and a 64 KiB chunk. (2) These are desktop-CPU times; **in-guest time on a 1-vCPU Microdroid VM, vsock transfer time, and VM boot time for these builds are unmeasured.** The only guest timing available is the 2026-09-22 v1.0.3 log (payload entered 1.382 s after guest boot). (3) **Whether a 150 MiB file fits in the default 256 MiB guest alongside the guest OS is unmeasured.** A guest out-of-memory would surface as a payload exit (fail-closed), not silent truncation.

Threshold provenance: the entropy threshold of 7.2 bits/byte was chosen from local measurement: all `classes*.dex` files examined during development (about 13 files across 4 APKs) measured 5.05–6.73 bits/byte, random data ≈ 7.99. That set is small; the threshold is hand-picked.

## 6. Limitations (explicit)

1. **No detection-rate evaluation.** No malware corpus; all true-positive evidence is synthetic. No real Master Key, Janus, Follina, VBA/XLM macro, malicious-PDF, malicious-script, or Fifield-bomb samples were tested.
2. **Permission heuristic untested on popular apps.** The ≥4-of-14 high-risk-permission rule, the SMS+accessibility rule, and the target-SDK-<23 rule are hand-picked, never run against a corpus of popular Play Store apps, and never fire on this workstation's real APKs.
3. **Hand-picked thresholds:** entropy 7.2 bits/byte, zip/gzip-bomb ratio 200:1 at ≥10 MiB, 1 GiB total, 4096 B trailing data, 2^28 pixels, 64 KiB unknown-chunk/comment limits, 4 permissions, 1–4 KiB text proximity windows. None tuned on labeled data.
4. **No signature database:** four compiled-in, masked strings (EICAR plus three Metasploit stager strings). Dynamically loadable signatures were deliberately skipped: a loadable list risks reintroducing the self-flagging bug and four signatures do not justify a transport.
5. **ZIP64 is not parsed** (reported as zero entries, unflagged); skipped on purpose since it only matters above 65,535 entries or 4 GiB and the 150 MiB input cap excludes the latter.
6. **Archive and container depth:** nested archives are scanned one level; gzip inflation stops at a 64 MiB output cap (ratio test still applies), the inner tar walk covers the first 8 MiB; tar/RAR/7z *contents* are not inspected (names, sizes, CRCs only); 7z encryption is detected by the AES coder id only when it is visible in the (possibly compressed) header, so LZMA-compressed headers hide it; RAR "unicode" names and multi-volume archives are not modeled.
7. **OLE2:** macro detection is "a VBA project is present" (may be empty; real Project/Publisher templates trigger it); XLM sheets are found only in `Workbook` streams stored in the regular FAT (≥4096 B) and within their first 1 MiB; mini-stream workbooks, RTF, and Equation Editor exploits (`Equation Native` is counted, not flagged) are not covered; password-protected documents are flagged, not opened.
8. **Fail-open by policy** for unparsed types: media, `isobmff`, PE/ELF (except UPX/entropy), fonts, and others pass unflagged. Plain unnamed text (no shebang, not HTML/SVG, no script extension via task 2) is **not** scanned for script patterns, because plain `curl | sh` and PowerShell snippets are common in legitimate documentation.
9. **Text heuristics have known benign matches** (4.7): `eval(unescape(…))` pages, installer cradles, Inkscape mesh-polyfill SVGs. They fail closed (quarantine) by design.
10. **PDF scope:** only zlib-compressed `/ObjStm` streams are inflated (other filters, encryption, incremental-update tricks are not decoded); keywords are counted over raw bytes like pdfid, so a random byte collision in compressed data is possible in principle (0 observed in 299); `/Encrypt` is not flagged.
11. **Non-protected VM:** no hardware root of trust; VM-escape resistance was not tested.
12. **The declared-name/MIME check (task 2) is implemented but not yet used by the app** (to the author's knowledge). v1.0.4–v1.0.6 are not validated on a device.
13. **False-flag evidence is one workstation, mostly developer artifacts**, not a representative file population; counts, not rates, are the honest statement. Several test-fixture directories (Go, Python, Playwright) over-represent deliberately broken files.
14. **Published v1.0.4 flags APKs that embed it (including Warden v3.1.0)**; fixed in v1.0.5 and later.
15. **Guest memory:** 150 MiB payload cap vs the default 256 MiB guest is unverified.
16. **Privacy:** EXIF values returned in status-0 JSON are personal data; redaction before any server upload is the host's responsibility and is not implemented in the guest. The shared-user-ID value and package identity are deliberately not emitted.

## 7. Backlog not started

RTF object/`objupdate` checks and Equation Editor (`Equation Native`) exploit flagging; OLE2 mini-stream workbooks and `Ole10Native` embedded-executable inspection; PDF streams with non-Flate filters; native `.so` and ELF/PE sanity inside APKs and archives; contents inspection of tar/RAR/7z entries; HTML/JS deobfuscation beyond string patterns; a signature database (static or loadable) and fuzzy hashing; ZIP64 (skipped by decision); APK Signature verification (`apksigner`-grade) rather than certificate-string detection.

## 8. Reproduction

```
git -C noxos-payload checkout 2b94021
clang++ -std=c++17 -g -fsanitize=address,undefined -o zip_scan_test zip_scan.cpp test/zip_scan_test.cpp -lz && ./zip_scan_test
# (same pattern for exif_parser, file_cheap_filter, pdf_scan, image_scan, ole2_scan, archive_scan (+ file_type.cpp text_scan.cpp), text_scan, file_scan (all sources), self_signature; see README "Testing & Fuzzing")
clang++ -std=c++17 -g -O1 -fsanitize=fuzzer,address,undefined -fno-sanitize-recover=all -o zip_fuzzer zip_scan.cpp fuzz/zip_scan_fuzzer.cpp -lz
mkdir -p corpus && cp fuzz/seeds_zip/* corpus/ && ./zip_fuzzer corpus -max_total_time=60 -max_len=65536
```

Release artifacts: `https://github.com/parrothacker1/noxos-payload/releases/tag/v1.0.5` (built from `feab206`; v1.0.6, intended to be built from `2b94021`, does not exist yet). Commit history for the file-scan work: `a56c29f` (ZIP/APK, network code removed, 150 MiB cap), `92f34c1` (fail-open, task 2, encrypted ZIP, PDF, OOXML), `c1ba94b` (permission names), `6f777a6` (images), `2b94021` (self-detection and PDF fixes).

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
