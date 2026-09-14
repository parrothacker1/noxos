# noxos-app

**Kotlin, Gradle (Kotlin DSL)** — host-side Android app, branded **Warden**. Detects untrusted content, routes it to the Microdroid pVM for isolated scanning, monitors app network traffic (UDP + TCP), shows the audit trail. Latest release: `v1.1.0`.

## Cross-project pointers

| Need to know… | Go to |
|---|---|
| What actually runs inside the VM this app launches | `noxos-payload` |
| Minimum SDK reasoning (33 = Android 13) | [`../PROJECT.md`](../PROJECT.md) — "Key technical decisions" (AVF/Microdroid shipped since Android 13) |
| Full session-by-session history of how this app got built | [`../TASKS.md`](../TASKS.md) |

## Modules

| Module | Role | Status |
|---|---|---|
| `app` | Launcher activity, composition root, wires every repository/service together, Compose `Screen` sealed-class navigation | Real |
| `trigger-router` | Reads a picked file's bytes, opens a Microdroid VM session over vsock, sends/receives the scan protocol, records a real-time `ScanProgress` step timeline, guarantees VM teardown + audit write even on cancel | Real orchestration; VM-launch layer (`MicrodroidVmSession`, `VsockVmTransport`) unverified against real AVF |
| `netmonitor` | `VpnService`-based monitor. Real UDP relay (per-client protected `DatagramSocket`) and real TCP relay (`TcpRelayManager` — hand-rolled split-relay), blocked-host enforcement, throttled audit logging | Real, CI-tested against real sockets; unverified on real hardware |
| `audit` | Domain model, Room database, blocked-hosts table, DataStore-backed settings, and **every Compose screen except Home** (theme system lives here too) | Real |

## `:audit` — domain, persistence, settings, screens, theme

- `AuditEvent`/`AuditEventType`/`AuditOutcome` — domain model. Events carry `flagged: Boolean` and `remoteHost: String?` (added for the Warden redesign) alongside the original fields (`resultSummary`, `durationMillis`, `errorMessage`, `stepTimingsCsv`).
- `AuditRepository` interface + `RoomAuditRepository` impl; `AuditDao`/`AuditEntryEntity`/`AuditConverters`/`AuditDatabase` — Room, `implementation`-scoped so Room itself never leaks onto `trigger-router`'s or `netmonitor`'s classpath.
- `BlockedHostRepository`/`BlockedHostDao`/`BlockedHostEntity` — the blocklist `netmonitor` enforces live.
- `WardenSettingsRepository` — DataStore-backed: theme mode, VM session timeout (15/30/60/120s, dropdown-picker in Settings), audit retention (30/90/180/365 days, also a dropdown), flagged-event/scan-completion notification toggles.
- `RetentionPolicy` — pure `cutoffEpochMillis()` function, unit-tested, drives a real `DELETE ... WHERE timestampEpochMillis < cutoff` purge on app start and on retention-setting change.
- `AuditListFiltering` — pure functions behind Audit Trail's search/filter/date-bucketing, unit-tested.
- `AuditExport` — writes JSON (single event or the whole log) via SAF `CreateDocument`.
- `AuditScreens.kt` — `AuditListScreen`, `AuditDetailScreen` (flag/unflag, delete, export, "Block Host" from a network event).
- `BlockedHostsScreen.kt` — view/unblock/manually-add.
- `SettingsScreen.kt` — real dropdown pickers (`SettingsDropdownRow<T>`, anchored to the trailing value+chevron, not the whole row — see the v1.0.2/v1.1.0 UX fixes below) for VM timeout and retention, switch rows for notifications, the theme segmented-button row, and a **permanently locked-ON** "Auto-destroy on completion" switch (security invariant, not a real toggle — see "Deliberately simplified" below).
- `theme/` — `WardenTheme`, `ContainmentMark` (the dashed-circle motif from the redesign mockup, drawn as a Compose `Canvas`), `Color.kt`/`Type.kt` (bundled real `.ttf` font resources — Archivo + JetBrains Mono — not Compose's downloadable-font provider, since that needs GMS and this project's a stated GMS-independent design).

**Module placement note:** the whole theme system and every screen except Home live in `:audit`, not `:app`. First pass put it in `:app`; `:audit`'s own screens need the same `CompositionLocal` for tertiary text color, and `:audit` can't depend on `:app` (wrong direction), so everything moved into `:audit` — the one leaf module everything else already depends on.

## `:trigger-router` — scan orchestration

- `TriggerRouter.scanFile(uri, descriptor): ScanResult` — reads file bytes, opens a VM session (`vmSessionFactory.createSession()`, `Closeable`), sends bytes over vsock via `VmPayloadProtocol`, decodes the response, **always** records an `AuditEvent` and enters `ScanStep.DONE` in a `finally` block (via `withContext(NonCancellable)`, so a cancelled scan still gets logged and its VM still torn down — `Closeable.use{}`'s `close()` isn't a suspending call, so cancellation doesn't skip it).
- `progress: StateFlow<ScanProgress>` — real per-step timestamps (`BOOTING`/`EXECUTING`/`SANITIZING`/`DESTROYING`/`DONE`), persisted as `stepTimingsCsv` on the audit event, drives Home's live scan timeline UI.
- VM session timeout is read from `WardenSettingsRepository` per scan (was a hardcoded `10_000L` before the redesign).
- Real cancellation: Home's "Cancel Scan" calls `Job.cancel()`; a pre-existing bug where a broad `catch (e: Exception)` silently swallowed `CancellationException` (breaking structured-concurrency propagation) was found and fixed while building this.
- `VmPayloadProtocol` — pure encode/decode, zero Android deps, unit-tested. Wire format: vsock, one fixed port, `[4-byte big-endian length][bytes]` framing. Host→guest: raw file bytes. Guest→host: `[1-byte status][UTF-8 JSON]` (`0=OK,1=PARSE_ERROR,2=MALFORMED_INPUT`).
- `VsockVmTransport`/`MicrodroidVmSession` — real AVF API calls (`VirtualMachineManager`, `VirtualMachineConfig`, `getOrCreate`). **Still unverified** — written against documented AVF APIs, never run against real Cuttlefish/hardware. This is the one part of the app Phase 2 exists to confirm.
- `FakeVmTransport` — test double; `TriggerRouterTest` covers the orchestration (read → send → receive → record → guaranteed teardown) entirely on the JVM without touching AVF.

## `:netmonitor` — real UDP + TCP relay

`NetMonitorService : VpnService()` captures all device IPv4 traffic through a tun interface (`10.0.0.1/32`, default route). Per packet: check the live blocklist first (covers UDP and TCP alike, since the check runs before protocol dispatch), then relay.

- **UDP** (`relayUdp`/`pumpUdpReplies`) — one `protect()`'d `DatagramSocket` per client `srcIp:srcPort`, replies re-wrapped as spoofed IPv4/UDP packets via `PacketUtils.buildUdpPacket` and written back into the tun.
- **TCP** (`TcpRelayManager`, new 2026-08-17) — a hand-rolled split-relay, not a native stack (the repo has no NDK/CMake toolchain, and lwIP/tun2socks/NetGuard-native-style are all C). Parses each TCP segment, keys a session table by the 4-tuple, and on SYN opens a real `protect()`'d `Socket` to the destination. Once connected it synthesizes a SYN-ACK back into the tun — the app on the device has no idea it's talking to a relay — then a background coroutine pumps the real socket's input straight into synthesized data/FIN segments, while inbound data/FIN/RST get their payload written to the real socket and ACKed. Sequence/ack numbers tracked as unsigned 32-bit (`Long`, masked `and 0xFFFFFFFFL`). `PacketUtils` gained `readUInt`/`writeUInt` and `buildTcpPacket` (real pseudo-header checksum) for this.
  - **Deliberate simplifications, not bugs:** no retransmission, no window scaling, no reordering — relies on the real destination's own TCP for reliability and on the tun fd (a local kernel path, not a lossy network) rarely dropping. Synthesized segments never carry TCP options.
  - **Verified with a real JVM integration test** (`TcpRelayManagerTest`) that drives a full SYN → data → reply → FIN cycle against an actual loopback `ServerSocket` and asserts on the real relayed bytes each direction — no mocking, no Android/Robolectric needed.
- `BlockedHostChecker.isBlocked()` — pure, unit-tested.
- Audit logging is throttled per-flow-descriptor (5s dedupe window via `lastLoggedAt`), not per-packet.
- **Still unverified against real traffic** — everything above compiles and passes its own unit/integration tests, but has never run on a real device against a real destination. Backlog item 16 in `TASKS.md`: turn the monitor on, hit an HTTPS site, confirm `NETWORK_TRAFFIC` audit entries appear for TCP.

## `:app`

`MainActivity` — composition root: builds every repository/service, requests `POST_NOTIFICATIONS` (Android 13+, was missing pre-redesign), runs the retention purge on launch, holds a `sealed class Screen` (`Home`/`AuditList`/`AuditDetail`/`BlockedHosts`/`Settings`) navigated with a plain `when` (no `androidx-navigation-compose` — not enough screens to justify it). `HomeScreen.kt` — scan trigger (SAF `ACTION_OPEN_DOCUMENT` picker), live scan progress/cancel, network-monitor toggle (`VpnService.prepare()` → permission launcher → `NetMonitor.start()`), scan-completion notifications gated by the real settings toggle.

## Deliberately simplified, not faked

The external design mockup (`Warden isolation redesign.zip`, fed into this app's 2026-08-16 redesign) showed some UI that this app doesn't have real backing logic for. Built down to what's real instead of inventing fake data:

- **No fabricated threat detection** — no TLS inspection/fingerprinting exists. `flagged=true` fires only when a flow genuinely wasn't relayed (a real TCP connect failure, or a non-UDP/TCP protocol like ICMP) or a user manually flags an event.
- **No fake request/response bodies or byte counters** on network-event detail — the monitor never captured payloads or byte counts, so those mockup fields were dropped.
- **No fake "Result hash"** on file-scan detail — `TriggerRouter` doesn't hash scanned files.
- **"Network sensitivity" picker dropped entirely** — the mockup showed a picker with no real backing logic to vary.
- **"Auto-destroy on completion" is real UI, permanently locked ON** — the VM is always destroyed after a scan; this is the ephemeral-by-design security invariant the whole project is built around, so it's a disabled `Switch` (always `checked=true`), not a real toggle. Making it togglable would be a security regression, not a settings nicety.

## Real-device bugs found and fixed (all via user screenshots on a real Samsung phone, not emulator/CI)

1. **Duplicate white system ActionBar** (`v1.0.0`) — `android:theme="@android:style/Theme.Material.Light"` renders its own ActionBar above the Compose `TopAppBar`. Fixed → `@android:style/Theme.Material.NoActionBar`, re-tagged `v1.0.1`.
2. **VM-timeout/retention settings cycled on tap instead of showing a dropdown** — replaced with real `DropdownMenu`-based pickers, tagged `v1.0.2`.
3. **Settings dropdown menu opened from the far-left edge, overlapping the row label** (`v1.0.2`) — the anchor `Box` wrapped the entire row instead of just the trailing value+chevron. Fixed, shipped in `v1.1.0` alongside the TCP relay.
4. **Unresolved:** "Select & Scan File" reported as failing (notification says scan failed, not reflected in Home UI) on this same non-Pixel Samsung device. `TriggerRouter`'s `finally` block always writes an audit event and fires the completion notification regardless of outcome, so the mechanism itself looks correct by code inspection — the actual scan result should be visible in the Audit Trail, just not on Home. Leading (unconfirmed) hypothesis: AVF/pKVM simply isn't available on stock Samsung OneUI hardware (Pixel-6+/Cuttlefish-only capability), not a bug. Needs the user to check the Audit Trail entry and report the exact error text to confirm either way.

## Build config

- `minSdk 33`, `compileSdk`/`targetSdk 35`, AGP 8.7.3, Kotlin 2.0.21, Gradle 8.9 (version catalog `gradle/libs.versions.toml`)
- New dependencies added during the redesign: `androidx.datastore:datastore-preferences`, `androidx.compose.material:material-icons-extended` (standard icons instead of hand-porting ~20 custom SVG paths from the mockup), `androidx.core:core-ktx`, `androidx.lifecycle:lifecycle-runtime-ktx`.
- `.github/workflows/ci.yml` — `setup-java` (temurin 17) → `gradle/actions/setup-gradle` → `./gradlew build`, GitHub-hosted runners. Green on every push this session.
- `.github/workflows/release.yml` — tag-push (`v*`) triggered, builds a release APK (unsigned — no signing infra yet, see `TASKS.md` backlog item 12) and runs `gh release create --generate-notes`.
- Local `CLAUDE.md` (gitignored, not in the public repo; renamed from `AGENTS.md` session 21 so Claude Code auto-loads it every session, compaction-proof — see `TASKS.md` session 21) documents the commit-message convention (`type: message`, single-line, no `Co-Authored-By`) and the no-comments rule, added after repeatedly needing to be re-corrected on commit formatting.

## Local verification note

This dev machine has no Android SDK installed — real dev/testing happens on the EC2 instance once provisioned (blocked on the pending AWS quota request), or on the user's real Samsung device for UI/UX issues. All Kotlin/Android verification in this repo is CI-only; `netmonitor`'s packet-math and TCP-relay logic happen to be plain-JVM-testable (no Android deps) and are covered by real JUnit tests that also run in CI.

## Icon

Adaptive launcher icon (vector drawables, `res/mipmap-anydpi-v26/`) + legacy PNG fallbacks (API < 26, all 5 densities). Source SVGs: root repo `assets/branding/` (source of truth) — this repo has its own vendored copy since Gradle needs it physically present to build.

## Releases

`v0.0.1`, `v0.0.2` (pre-redesign scaffolding) → `v1.0.0` (full Warden redesign) → `v1.0.1` (ActionBar fix) → `v1.0.2` (dropdown pickers) → `v1.1.0` (real TCP relay + dropdown-anchor fix). https://github.com/parrothacker1/noxos-app/releases
