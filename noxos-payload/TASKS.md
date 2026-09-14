# noxos-payload — Task List

Last updated: 2026-09-14 (session 5, this repo — both guest-side cheap filters implemented for real, closing the gap this file flagged as "hasn't implemented either task type yet"). Read [`../README.md`](../README.md) (hub) and [`../PROJECT.md`](../PROJECT.md) (architecture, source of truth) first for cross-repo context — this file is `noxos-payload`'s own task history, split out from the old combined `TASKS.md` (now just an index at `../TASKS.md`). See also this repo's own [`README.md`](README.md).

This repo has had the least session activity of the four original repos so far — most of the project's work has concentrated in `noxos-app`/`noxos-os`. That's expected: `noxos-payload` is gated behind Phase 1c's jniLibs handoff (see [`../noxos-os/TASKS.md`](../noxos-os/TASKS.md)), which hasn't happened yet.

## What happened, in order

**Session 5** (2026-09-14) — implemented both guest-side cheap filters against the wire contract this file locked in session 17 (`noxos-app` side). Nothing here was built before this session; the app-side callers existed but had nothing real to call.

1. **Task-type dispatch, matching the locked contract.** `payload_main.cpp` previously implemented the *old* pre-task-byte wire format (bare 4-byte length + file bytes) — it never actually spoke the contract this file documents. Rewrote `handle_scan` into `handle_connection`, which reads the 1-byte task type + 4-byte BE length prefix first, then dispatches to `handle_file_scan` (task 0) or `handle_network_sample` (task 1). Both task types share the same vsock session/response envelope, no new build target, exactly as designed.

2. **File cheap filter (`file_cheap_filter.h`/`.cpp`, new).** The PROJECT.md framing ("magic-header-vs-declared-extension mismatch, size sanity") doesn't translate literally — the wire protocol never sends a declared filename/extension, only raw file bytes (checked `TriggerRouter.kt`/`readFileBytes` on the `noxos-app` side to confirm before assuming). Reinterpreted as two checks that are actually buildable from bytes alone, and arguably closer to the real threat model for a Microdroid-isolated parser:
   - **Embedded foreign-magic scan**: after locating the true JPEG EOI marker (searched from the end, since encoders always escape a lone `0xFF` byte inside entropy-coded scan data — a real unescaped `FF D9` pair is reliably the terminal marker), scan only the *trailing* bytes after it for known foreign container magics (ZIP local-file-header, gzip, ELF, PE, PDF, shebang, `<?php`, `<script`). This is the classic JPEG+ZIP-style polyglot/append attack, and scanning only the post-EOI region (not the whole compressed body) keeps the false-positive rate low — a full-file scan for 2-byte magics like `MZ` would false-positive constantly against high-entropy JPEG scan data.
   - **Scan-data size sanity**: walks JPEG markers (same bounds-checked style already in `exif_parser.cpp`) to find the SOS marker; flags if no SOS exists before EOI/EOF (a "JPEG" with EXIF but no actual image data), or if fewer than 32 bytes of scan data follow it (too little to be a real photo).
   - Both checks are additive: only added to the response JSON (`cheap_filter_flagged`/`cheap_filter_reason`) when the file already parsed successfully (status 0) — matches how `TriggerRouter.kt` only reads these keys inside its `status == 0` branch.

3. **Network cheap filter (`network_cheap_filter.h`/`.cpp`, new).** `DecodePacketSamples` parses the `encodePacketSamples()` multi-packet framing (BE uint16 count, then per-packet BE int32 length + bytes), strict about exact consumption. `CheckNetworkCheapFilter` treats entry 0 as a real IPv4 packet (per the documented contract) and validates: version nibble, IHL bounds, `total_length` field matching the captured size exactly, nonzero TTL, a known IP protocol number, a correct IPv4 header checksum (computed the standard one's-complement way), and — for TCP/UDP — L4 header-length/length-field sanity. Entries beyond index 0 (the optional inbound reply) have no header to validate per the documented wire contract, so they only get a size-sanity cap (65535 bytes). This is the "header-sanity/protocol-conformance" check named but not specified in `../PROJECT.md` — the exact heuristics were this repo's design call, now made and documented here.

4. **Shared `json_util.h`** (`JsonEscape`, previously duplicated privately inside `exif_parser.cpp`) so the new filters' `reason` strings and `exif_parser.cpp`'s tag values escape the same way without copy-pasting the function a third time.

5. **Tests + fuzzing, same standard as the existing EXIF parser.** Both filters are pure, zero-AOSP-dependency `.h`/`.cpp` pairs (same split as `exif_parser`), each with a `test/*_test.cpp` self-check and a `fuzz/*_fuzzer.cpp` libFuzzer harness, wired into CI (`.github/workflows/ci.yml`) alongside the existing EXIF jobs. Local bounded fuzz runs before landing: ~3.7M executions (file filter), ~10M executions (network filter), both clean under ASan+UBSan — no crash found, so (unlike the EXIF parser's real regression seed) there's no known-bug seed to check in yet; both fuzzers start from an empty corpus in CI.

6. **README.md brought back in sync** — the wire protocol section still described the pre-task-byte format from before session 17's `noxos-app` work; updated to the real task-type-dispatch contract, both response shapes, and the new architecture/testing sections.

**Verification note, same day**: `handle_file_scan`'s `result_json.pop_back()` (dropping the JSON's trailing `}` to splice in `cheap_filter_flagged`/`cheap_filter_reason` before re-closing it) looked worth double-checking for an empty-string edge case, since `pop_back()` on an empty `std::string` is UB. Traced it: `ParseExif` has exactly one `kStatusOk` return site (`exif_parser.cpp:253`), gated by an `if (pairs.empty()) return kStatusParseError;` check just above it (line 240-243) — so `kStatusOk` is never reached with zero pairs. `WalkIfd` (line 181-182) only ever pushes a pair when `!val.empty()`. So by construction, any `kStatusOk` response JSON is `{` + at least one real `"key":"value"` + `}` — never empty, always `}`-terminated. Not a bug; the invariant is proven by reading the source, not by the fuzzing that exists today. **Real gap, worth flagging**: neither fuzz harness drives the actual `handle_connection` → `handle_file_scan` splice path in `payload_main.cpp` (it can't — that file pulls in `vm_payload/api.h`, AOSP-only, not linkable with plain `clang++`), so this specific invariant is currently proven by static reasoning about `exif_parser.cpp` and `file_cheap_filter.cpp` in isolation, not exercised end-to-end. Worth a one-line awareness note, not worth building new test scaffolding to fuzz an already-proven invariant.

**Not done, deliberately out of scope this session**: the jniLibs/naming reconciliation (`_stub` suffix question) flagged below is still open and still not this session's job — nothing here changes the binary's name. Real Soong/AOSP compile and vsock I/O against a live VM are still Phase-2-gated, unchanged by this session (everything above is proven against the same plain-`clang++`/ASan testing style the EXIF parser already used, not against a real Microdroid guest).

**Session 4** (2026-08-16) — closed out backlog item 9 (EXIF parser fuzz testing) in parallel with `noxos-app`'s Warden redesign work:

1. **P7: adversarial test suite for the EXIF parser (fuzz testing) — done.** Parsing logic pulled out into `exif_parser.h`/`.cpp` (zero AOSP deps, plain-`clang++` testable). Real self-check test + libFuzzer harness added, both CI-enforced (`.github/workflows/ci.yml`, new for this repo). **Found and fixed a real heap-buffer-overflow read**: the APP1 segment's declared length (`seg_len`, attacker-controlled) wasn't validated against the actual buffer size, so a crafted 12-byte JPEG could make the parser read past the end of the file bytes — reproduced with ASan against the pre-fix code before fixing it, not hypothetical. Fixed, regression-tested, kept as a fuzz seed. A 60s/~9.3M-execution local fuzz run post-fix found nothing further. Still only tests the pure parsing logic standalone — the real Soong/AOSP compile path and vsock I/O remain unverified until Phase 2 (see `../noxos-os/TASKS.md`). See [`README.md`](README.md) for detail.

## Cross-repo dependencies (not this repo's own work, tracked elsewhere)

- **jniLibs handoff** (`noxos-payload`'s compiled `.so` → `noxos-app`'s `jniLibs/<abi>/`) — nothing builds this mechanism yet. Tracked in [`../noxos-os/TASKS.md`](../noxos-os/TASKS.md) Phase 1c item 9 (the OS-level integration work) and [`../noxos-app/TASKS.md`](../noxos-app/TASKS.md) (the consuming side, `MicrodroidVmSession.kt`'s `setPayloadBinaryName("libnoxos_payload_stub.so")` reference).
- **Real Soong/AOSP compile + vsock I/O verification** — gated on Phase 2 (Google's own AVF/Microdroid reference demo running first) — see [`../noxos-os/TASKS.md`](../noxos-os/TASKS.md).
- **Naming heads-up, not yet reconciled**: the host side currently hardcodes the payload binary name as `libnoxos_payload_stub.so` (`MicrodroidVmSession.kt`'s `setPayloadBinaryName(...)`) and `noxos_payload_stub.so` (`vm_config.json`'s `task.command`) — both still say `_stub`, a leftover from before this repo had a real EXIF parser. Whoever wires up the real Soong build output should either keep that exact filename (simplest — no host-side change needed) or, if the real build produces a differently-named `.so`, that's a two-line host-side rename (`noxos-app`'s job, not this repo's) — flag it in a commit/PR rather than silently changing one side only, since a mismatch here fails at `vmm.getOrCreate()`/`vm.run()`, not at compile time.

### The wire contract, locked 2026-09-13 (`noxos-app` session 15) — this is what to build against, not a sketch

`VmPayloadProtocol` (`noxos-app`'s `trigger-router/.../protocol/VmPayloadProtocol.kt`) now prefixes every request with a **task-type byte** so one payload binary can serve two jobs. Full request envelope, guest side needs to parse exactly this:

```
byte 0:       task type (0 = file scan, 1 = network sample)
bytes 1-4:    big-endian Int32, payload length in bytes (Java ByteBuffer default order)
bytes 5...:   the payload itself
```

Response envelope (unchanged, both task types share it):
```
byte 0:       status (0 = ok, 1 = parse error, 2 = malformed input, anything else = unknown/error)
bytes 1...:   UTF-8 JSON string, rest of the message
```

**Task 0 — file scan (`VmPayloadProtocol.TASK_FILE_SCAN`)**: unchanged from before — payload is the raw file bytes, a status-0 response's JSON is EXIF key/value metadata. **New, additive, optional**: the JSON may now also carry `"cheap_filter_flagged": true` and `"cheap_filter_reason": "<string>"` alongside (or instead of) the EXIF fields. `noxos-app`'s `TriggerRouter` already checks for these two keys on every status-0 response (`json.optBoolean("cheap_filter_flagged", false)`) — when present and `true`, it treats the whole scan as a `Failure` (triggers real quarantine on the auto-scan path) regardless of whether EXIF parsing itself succeeded. **Backward compatible**: their absence (today's real behavior) parses as `false`, nothing breaks. This is the mechanism for the file-side cheap filter design in `../PROJECT.md` ("magic-header-vs-declared-type mismatch, size sanity") — implement the check, add these two keys to the same JSON response you already build, no protocol version bump needed.

**Task 1 — network sample (`VmPayloadProtocol.TASK_NETWORK_SAMPLE`)**: brand new, not built in this repo yet. **Framing finalized 2026-09-13 (session 17) — this is what's sent today, not a placeholder.** The payload (the bytes after the task-type byte and length prefix in the outer envelope) is itself a small self-contained list, via `VmPayloadProtocol.encodePacketSamples()`:

```
bytes 0-1:    unsigned Int16, count of packets in this sample (today: 1 or 2)
per packet:
  4 bytes:    Int32, this packet's length
  N bytes:    the packet's raw bytes
```

**Real, honest wrinkle — the packets in that list aren't uniform, parse each independently rather than assuming they're all the same shape**: entry 0 is always the full outbound IPv4 packet that caused the flag (the exact bytes captured off the tun interface — real IP header, real protocol header, real payload). A second entry, when present, is the **first inbound reply** from that destination — for UDP, this is the bare UDP payload only (as delivered by a real `DatagramSocket.receive()`, no IP/UDP header exists to include); for TCP, it's the raw bytes read off the relayed socket's `InputStream` (also no synthetic header — this is post-handshake application data, not a TCP segment). So: don't assume every entry parses as an IPv4 packet — entry 0 does, later entries are protocol/direction-dependent payload bytes. The count is 1 whenever the dispatcher fires before any reply has arrived yet (expected to be the common case, given the cheap-filter poll runs every 30s and most reachable destinations reply within milliseconds — but not guaranteed, don't require entry 2 to design the check).

Expected response JSON, status 0: `{"flagged": <bool>, "reason": "<string>"}` — `reason` is optional (defaults to a generic string on the app side if absent), `flagged` absent defaults to `false` (clean). `noxos-app`'s `NetworkSampleVmDispatcher` opens a one-shot VM per newly-flagged destination, sends exactly this, and acts on the verdict: `flagged: false` → the destination is marked `ALLOWED` directly (session-scoped, real audit trail, never silently passed through); `flagged: true` → the destination stays `FLAGGED` and becomes eligible for the existing AI-based escalation (`AnalysisDispatcher` → `noxos-inference`). **What the actual check should look for is this repo's design call** — the "network equivalent of magic-header-vs-declared-type" framing from before still stands (header-sanity/protocol-conformance against what the IPv4 header claims for entry 0; whatever's appropriate for a bare payload/stream blob for a second entry), but the exact heuristics aren't specified anywhere — decide and document here when built.

**Still open, not this repo's blocker**: batching *multiple different newly-flagged destinations* into one VM call (to amortize VM-boot cost) is a separate, still-undesigned idea (`../discussions.md` item 7) — today it's still strictly one VM session per destination, this session's work only changed how many packets ride along in that one session's request.

Both task types are dispatched through the *same* `libnoxos_payload_stub.so` / `vsock` session — no new build target, no new `vm_config.json` entry, just a `switch` on that first request byte in the guest's read loop.

**Real, tested today (`noxos-app` side, CI-green, commits `56ff09d` and `bcfda8e`)**: `VmPayloadProtocolTest` covers both task-type byte values and the multi-packet framing (`encodePacketSamples`) encode correctly; `TriggerRouterTest` covers the file-scan `cheap_filter_flagged` response path end-to-end against a fake transport; `NetworkSampleVmDispatcherTest` covers the network-sample response parsing (clean/flagged/malformed-status/thrown-exception, plus that both an outbound and inbound sample land in one request) all against a fake `VmSession`/`VmTransport` — no real VM involved, same as every other VM-touching test in `noxos-app`, since real Microdroid I/O is still Phase-2-gated. None of this exercises a real payload binary — it's the host side of the contract, proven against fakes, waiting on this repo to implement the guest side that actually matches it.

## Backlog

9. ~~**P7: adversarial test suite** for the EXIF parser (fuzz testing)~~ — **done 2026-08-16**, see above.

## Not real tasks — deliberately not building these

- A general malware-detonation engine — scoped to one payload type (JPEG EXIF) end-to-end, that's the whole point of the "honest proof-of-concept, not Cuckoo Sandbox" framing in `../PROJECT.md`.
