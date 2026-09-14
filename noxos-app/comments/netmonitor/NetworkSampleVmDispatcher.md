# netmonitor/src/main/java/com/noxos/netmonitor/NetworkSampleVmDispatcher.kt

## `CheapFilterVerdict.Unknown`

VM unreachable, a non-zero protocol status, or a malformed response - left for a human, never a self-DoS retry loop.

## `NetworkSampleVmDispatcher` (class)

The pVM-gated cheap filter ahead of AI, per PROJECT.md's "Network-side pKVM-gated cheap filter"
design: for each newly-flagged destination, opens a one-shot VM with a raw packet sample and
runs a header-sanity/protocol-conformance check. A clean result resolves the destination
directly (a real, session-scoped ALLOWED - never silently passed through); a flagged result
marks it eligible for `AnalysisDispatcher`'s existing AI escalation instead of resolving it here.
