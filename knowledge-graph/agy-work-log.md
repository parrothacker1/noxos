# Antigravity Session Work Log — 2026-08-15

This log summarizes the implementations and changes done in the `noxos-app` workspace to enable file scanning orchestration and audit trail tracking under NoxOS.

All changes are currently **uncommitted and unpushed** in the working tree to allow Claude to review them, as instructed.

## Summary of Changes

### 1. Build and Dependency Configuration
*   **[libs.versions.toml](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/noxos-app/gradle/libs.versions.toml)**: Updated version catalog to add Compose (BOM `2026.08.00`), Room (`2.6.1`), KSP (`2.0.21-1.0.28`), Coroutines, Robolectric, JUnit, and AndroidX test dependencies.
*   **[Root build.gradle.kts](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/noxos-app/build.gradle.kts)**: Registered `ksp` and `compose-compiler` Gradle plugins.
*   **[audit/build.gradle.kts](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/noxos-app/audit/build.gradle.kts)**: Enabled Compose feature, applied KSP/Compose-Compiler plugins, and added dependencies for Room, Compose, Coroutines, and local JVM tests.
*   **[trigger-router/build.gradle.kts](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/noxos-app/trigger-router/build.gradle.kts)**: Added module dependency on `:audit`, and local test dependencies including Robolectric.
*   **[netmonitor/build.gradle.kts](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/noxos-app/netmonitor/build.gradle.kts)**: Added module dependency on `:audit`.
*   **[app/build.gradle.kts](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/noxos-app/app/build.gradle.kts)**: Applied Compose compiler plugin, enabled Compose, and added Compose BOM/UI runtime dependencies.

### 2. Implementation of `:audit` Module
*   **[AuditEvent.kt](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/noxos-app/audit/src/main/java/com/noxos/audit/AuditEvent.kt)**: Created domain types `AuditEvent`, `AuditEventType`, and `AuditOutcome`.
*   **[AuditRepository.kt](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/noxos-app/audit/src/main/java/com/noxos/audit/AuditRepository.kt)**: Created `AuditRepository` interface and `AuditModule` factory (the DIY dependency injection container).
*   **[AuditEntryEntity.kt](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/noxos-app/audit/src/main/java/com/noxos/audit/AuditEntryEntity.kt)**: Room entity class representing individual audit events.
*   **[AuditConverters.kt](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/noxos-app/audit/src/main/java/com/noxos/audit/AuditConverters.kt)**: Room type converters for mapping Kotlin enums to strings in Sqlite.
*   **[AuditDao.kt](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/noxos-app/audit/src/main/java/com/noxos/audit/AuditDao.kt)**: DAO interface declaring database query operations (inserts, descending order observations).
*   **[AuditDatabase.kt](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/noxos-app/audit/src/main/java/com/noxos/audit/AuditDatabase.kt)**: Room database singleton setup.
*   **[RoomAuditRepository.kt](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/noxos-app/audit/src/main/java/com/noxos/audit/RoomAuditRepository.kt)**: Repository implementation delegating to the DAO and mapping DB entities to domain objects.
*   **[AuditScreens.kt](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/noxos-app/audit/src/main/java/com/noxos/audit/AuditScreens.kt)**: Declarative Compose UI screens: `AuditListScreen` (LazyColumn display of logs) and `AuditDetailScreen` (displays detailed logs for a chosen scan).
*   **`AuditLog.kt`**: Removed the old placeholder object.
*   **[RoomAuditRepositoryTest.kt](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/noxos-app/audit/src/test/java/com/noxos/audit/RoomAuditRepositoryTest.kt)**: Created Robolectric JVM tests verifying repository/database write and read flows.

### 3. Implementation of `:trigger-router` Module
*   **[ScanResult.kt](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/noxos-app/trigger-router/src/main/java/com/noxos/triggerrouter/ScanResult.kt)**: Sealed scan outcome class (`Success`, `Failure`, `Error`).
*   **[ExifData.kt](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/noxos-app/trigger-router/src/main/java/com/noxos/triggerrouter/ExifData.kt)**: Created domain representation for parsed metadata.
*   **[VmPayloadProtocol.kt](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/noxos-app/trigger-router/src/main/java/com/noxos/triggerrouter/protocol/VmPayloadProtocol.kt)**: Encoder/decoder for vsock protocol framing (length-prefixed stream, `[4-byte big-endian length][payload]`).
*   **[VmPayloadProtocolTest.kt](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/noxos-app/trigger-router/src/test/java/com/noxos/triggerrouter/protocol/VmPayloadProtocolTest.kt)**: Pure unit tests verifying protocol serialization logic.
*   **[VmTransport.kt](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/noxos-app/trigger-router/src/main/java/com/noxos/triggerrouter/vm/VmTransport.kt)**: Connection transport abstraction interface.
*   **[FakeVmTransport.kt](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/noxos-app/trigger-router/src/test/java/com/noxos/triggerrouter/vm/FakeVmTransport.kt)**: Test double implementing `VmTransport`.
*   **[VmSession.kt](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/noxos-app/trigger-router/src/main/java/com/noxos/triggerrouter/vm/VmSession.kt)**: Interface for managing isolated VM lifecycles.
*   **[TriggerRouter.kt](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/noxos-app/trigger-router/src/main/java/com/noxos/triggerrouter/TriggerRouter.kt)**: Core orchestrator class reading files, initiating VM session, processing outputs, and logging database entries.
*   **[TriggerRouterTest.kt](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/noxos-app/trigger-router/src/test/java/com/noxos/triggerrouter/TriggerRouterTest.kt)**: Robolectric JVM tests verifying orchestration workflows against fakes.
*   **[VsockVmTransport.kt](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/noxos-app/trigger-router/src/main/java/com/noxos/triggerrouter/vm/VsockVmTransport.kt)**: Real vsock socket communications wrapper. *Flagged unverified.*
*   **[MicrodroidVmSession.kt](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/noxos-app/trigger-router/src/main/java/com/noxos/triggerrouter/vm/MicrodroidVmSession.kt)**: Real AVF API integration. *Flagged unverified.*

### 4. Implementation of `:netmonitor` Module
*   **[NetMonitor.kt](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/noxos-app/netmonitor/src/main/java/com/noxos/netmonitor/NetMonitor.kt)**: Converted `object` to a `class` taking `AuditRepository`, containing a stub as defined by the plan.

### 5. Integration in `:app` Module
*   **[MainActivity.kt](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/noxos-app/app/src/main/java/com/noxos/app/MainActivity.kt)**: ComponentActivity setting up the application modules composition root and launching a Jetpack Compose HomeScreen containing a file picker launcher and log navigation.
*   **[AndroidManifest.xml](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/noxos-app/app/src/main/AndroidManifest.xml)**: Declared `MANAGE_VIRTUAL_MACHINE` permission. *Flagged unverified.*
*   **[vm_config.json](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/noxos-app/app/src/main/assets/vm_config.json)**: Copied configuration from `noxos-payload` into app assets.

### 6. Knowledge Graph Updates
*   **[knowledge-graph/TASKS.md](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/knowledge-graph/TASKS.md)**: Updated task logs to flag the completion of `noxos-app` implementation steps 1-7 in the working tree.
*   **[knowledge-graph/noxos-app/README.md](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/knowledge-graph/noxos-app/README.md)**: Updated status section to declare logic implementation completion.


---

## Session 2 — 2026-08-15 (continued)

### 7. EXIF Parser Payload (`noxos-payload`)
*   **[payload_main.cpp](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/noxos-payload/payload_main.cpp)**: Replaced the "hello microdroid" stub with a complete self-contained EXIF parser. Implements:
    - `AVmPayload_main()` entry point opens a vsock listener on port 5000 (matches `VmPayloadProtocol.VSOCK_PORT`).
    - `handle_scan()` reads the length-framed request, calls the parser, sends the length-framed `[status][JSON]` response.
    - `parse_exif()` scans JPEG segments for APP1/Exif, parses the TIFF IFD structure (handles both little-endian "II" and big-endian "MM"), walks IFD0 + ExifSubIFD + GPS IFD, and serializes recognized tags into a JSON object.
    - Tag name table covers ~40 standard EXIF tags (Make, Model, DateTime, focal length, GPS pointer, etc.).
    - No third-party libs — all libc/POSIX, suitable for Microdroid's minimal environment.
    - Accepts one connection per process invocation and then exits cleanly (ephemeral VM pattern).
    - Status codes (`0=OK, 1=PARSE_ERROR, 2=MALFORMED_INPUT`) exactly match `VmPayloadProtocol.kt`.

### 8. Network Monitor (`noxos-app/netmonitor`)
*   **[NetMonitorService.kt](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/noxos-app/netmonitor/src/main/java/com/noxos/netmonitor/NetMonitorService.kt)**: Full `VpnService` subclass. Establishes a local TUN interface, runs a coroutine capture loop that reads raw IPv4 packets, forwards them unchanged (pass-through mode), extracts TCP/UDP/ICMP flow descriptors (`proto src:port → dst:port`), and records each flow as an `AuditEvent` in the Room database. Foreground service with a notification channel.
*   **[NetMonitor.kt](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/noxos-app/netmonitor/src/main/java/com/noxos/netmonitor/NetMonitor.kt)**: Updated controller — `prepareIntent()` (checks VPN permission), `start()`, `stop()`.
*   **[AndroidManifest.xml](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/noxos-app/app/src/main/AndroidManifest.xml)**: Added `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_SPECIAL_USE`, `INTERNET` permissions; declared `NetMonitorService` with `BIND_VPN_SERVICE` permission and the required `android.net.VpnService` intent filter.
*   **[MainActivity.kt](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/noxos-app/app/src/main/java/com/noxos/app/MainActivity.kt)**: Updated `HomeScreen` with a "Start/Stop Network Monitor" toggle button; added `vpnPermissionLauncher` to handle the system VPN consent dialog before starting the service.

### 9. README Updates
*   **[Root README.md](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/README.md)**: Center-aligned SVG logo, three-pillar architecture prose, repo table, and phase roadmap checklist.
*   **[noxos-app/README.md](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/noxos-app/README.md)**: Module graph diagram, vsock protocol diagram, build SDK floor.
*   **[noxos-os/README.md](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/noxos-os/README.md)**: Build overlay / local manifest explanation, EC2 spot instance caching rationale, boot animation pipeline.
*   **[noxos-payload/README.md](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/noxos-payload/README.md)**: Guest sandbox diagram, vsock parse-and-respond flow, Soong build rationale, open questions.
*   **[noxos-server/README.md](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/noxos-server/README.md)**: Static manifest flow diagram, manifest schema, serverless decision rationale.

### 10. Knowledge Graph Updates
*   **[TASKS.md](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/knowledge-graph/TASKS.md)**: Marked tasks 9 and 10 as coded+uncommitted.
*   **[noxos-payload KG README](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/knowledge-graph/noxos-payload/README.md)**: Status section reflects real EXIF implementation.


---

## Session 3 — 2026-08-15 (README beautification)

### README Rewrites

All five READMEs rewritten with full GitHub-rendered formatting: center-aligned logo, shields.io badges, architecture diagrams (ASCII art), tables, protocol specs, and sub-footers.

| File | What's in it |
|------|-------------|
| [Root README.md](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/README.md) | Logo + badges, three-pillar table, full architecture diagram, repo comparison table, roadmap checklist, "why this matters" section, branding note |
| [noxos-app/README.md](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/noxos-app/README.md) | Badges, ASCII module graph, module responsibility table, host↔guest protocol framing diagram, scan lifecycle flow, AuditEvent schema, full build config table |
| [noxos-os/README.md](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/noxos-os/README.md) | Badges, repo layout tree, full build pipeline diagram, EC2 infrastructure spec table (instance/storage/spot/cost), local manifest example, Phase 1 exit criterion |
| [noxos-payload/README.md](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/noxos-payload/README.md) | Badges, pKVM isolation boundary diagram, in-VM architecture flow, wire protocol box-drawing, EXIF tag coverage table, Soong build snippet, status verification table |
| [noxos-server/README.md](file:///home/parrot/Projects/Furnace/Anvil/NoxOS/noxos-server/README.md) | Badges, full 6-hour pipeline flow diagram, manifest JSON schema, release naming convention, why-not-a-server decision table, deliberate non-features, verify command |

---
**No commits or pushes have been executed.** All files are present in git status.
