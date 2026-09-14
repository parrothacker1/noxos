# trigger-router/src/main/java/com/noxos/triggerrouter/vm/MicrodroidVmSession.kt

## `MicrodroidVmSession.close`

Best effort (the `vm.stop()` call is wrapped in try/catch and swallows any exception).

## `MicrodroidVmSessionFactory.createSession` (config building)

API 35's Builder has no (Context, path) ctor — vm_config.json (the Microdroid
payload manifest) is a guest-side asset convention, not parsed by this Java API.
Payload binary name is set explicitly instead; see knowledge-graph/TASKS.md.
