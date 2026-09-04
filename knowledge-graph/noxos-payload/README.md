# noxos-payload

**C++ / Android.bp (Soong)** — native code that runs *inside* the disposable Microdroid pVM. Kept as a separate repo deliberately: its commit history is the audit trail for everything that has ever executed inside the trust boundary.

## Cross-project pointers

| Need to know… | Go to |
|---|---|
| How this gets built into the OS image | `noxos-os` — AOSP tree this Soong module needs to live inside |
| Which app launches this VM and receives its result | `noxos-app` — Host Trigger/Router |
| Why Phase 2 (reference demo) must happen before Phase 6 (this payload) is trusted | [`../PROJECT.md`](../PROJECT.md) — roadmap |

## Research findings (2026-08-14, AOSP docs as of that date)

Checked directly against `source.android.com/docs/core/virtualization` and `android.googlesource.com/platform/packages/modules/Virtualization` before writing any code — nothing here is guessed.

- **Entry point — confirmed.** `AVmPayload_main()` via `<vm_payload/api.h>`, documented in `packages/modules/Virtualization/build/microdroid/README.md`.
- **Build path — Android.bp/Soong confirmed as the only documented path.** `cc_library_shared` inside the AOSP tree, embedded into a hosting app via `jni_libs` + `use_embedded_native_libs`. No official standalone NDK/CMake path was found for the payload binary itself — so no `CMakeLists.txt` was added; adding one would mean inventing an unconfirmed build path.
- **`vm_config.json` shape — confirmed** from `writeavfapp` doc: `{"os":{"name":"microdroid"}, "task":{"type":"microdroid_launcher","command":"<payload>.so"}}`. Loaded by the host app via `VirtualMachineConfig.Builder(context, "assets/vm_config.json")`.
- `shared_libs: ["libvm_payload#current"]` in `Android.bp` — found in an actual AOSP build diff, not in the trimmed README example. Flagged as slightly less certain than the entry point.

### Open questions (deliberately left unresolved, not guessed)

- Whether a standalone NDK/CMake build path for the payload exists anywhere undocumented — would simplify this repo if it does (buildable without a full AOSP checkout). Needs checking against a real AOSP tree in Phase 2.
- Whether the host app's `AndroidManifest.xml` needs entries beyond bundling `assets/vm_config.json`.
- Two official demos disagree on entry point shape: `demo_native`/`vm_demo_native` uses `android_native_main(int, char**)` for *system-level* VMs; the `writeavfapp` guide's app-hosted flow uses `AVmPayload_main()`. NoxOS matches the second (app-triggered, ephemeral, not a system component) — Phase 2 should build **both** unmodified to confirm this reading before P6 proceeds.
- Cuttlefish only supports **non-protected** VMs — protected-VM behavior needs real Pixel 6+ hardware, untested here.

## Layout

| File | Purpose |
|---|---|
| `payload_main.cpp` | `AVmPayload_main()` + vsock I/O only — the parsing logic was pulled out (see below). |
| `exif_parser.h`/`.cpp` | Pure EXIF parsing logic, zero AOSP/Android dependencies — pulled out of `payload_main.cpp` 2026-08-16 specifically so it's testable with a plain `clang++`, no AOSP tree needed. |
| `test/exif_parser_test.cpp` | Self-contained assert-based test, no framework. |
| `fuzz/exif_fuzzer.cpp` + `fuzz/seeds/` | libFuzzer harness + seed corpus. |
| `.github/workflows/ci.yml` | Builds + runs the self-check and a 60s bounded fuzz pass (ASan+UBSan) on every push — this is real CI that actually runs, unlike the AOSP/Soong build itself which still needs Phase 2 infra. |
| `Android.bp` | Soong module for the payload shared library — no `android_app` wrapper (that's `noxos-app`'s job). |
| `vm_config.json` | VM config manifest — still not wired into any hosting app; see `noxos-app`'s open question about whether the API-35 Builder still reads this. |

## Status (2026-08-16)

**A real bug was found and fixed via fuzzing, not hypothetical.** The EXIF parser's `tiff_len` computation trusted the attacker-controlled APP1 segment length (`seg_len`) without validating it against the actual buffer size. A 12-byte crafted JPEG (`FF D8 FF E1 00 2D 45 78 69 66 00 00`) reproducibly triggered a heap-buffer-overflow read under `-fsanitize=address` — confirmed by extracting the pre-fix logic standalone and running it before the fix landed. Fixed by validating `seg_len` against both a minimum (8, avoiding a `size_t` underflow) and the real buffer size before trusting it. Regression-tested and kept as a fuzz seed. A 60-second local libFuzzer run post-fix (~9.3M executions, ASan+UBSan) found nothing further.

This closes backlog item 9 in `../TASKS.md` (P7 adversarial test suite) at the "parser is fuzz-tested standalone" level. **Still unverified inside a real AOSP/Soong build** — the pure-logic split means the fuzzing/testing done here never touched the actual `cc_library_shared` compile path, `vm_payload/api.h`, or vsock I/O, which still need Phase 2 (real AOSP tree + Cuttlefish) to confirm.
