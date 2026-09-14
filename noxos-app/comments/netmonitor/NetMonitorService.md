# netmonitor/src/main/java/com/noxos/netmonitor/NetMonitorService.kt

## `pendingPacketSamples`

Packet samples captured for a newly-flagged destination, keyed by destination IP -
consumed (and removed) by `NetworkSampleVmDispatcher` when it submits that destination
to the pVM cheap filter. Starts with the outbound packet that caused the flag; the first
inbound reply (if one arrives before the dispatcher consumes it) is appended too, via
`appendPendingSample` - see `TcpRelayManager`'s `onInboundSample` callback and
`pumpUdpReplies`. Capped at `MAX_SAMPLES_PER_DESTINATION` per destination.
In-memory only: a destination that survives an app restart without ever being consumed
loses its sample and won't get cheap-filter checked until it's flagged again in a fresh
process. Known, deliberate limitation.

## `appendPendingSample`

No-op if `ip` isn't already pending (never buffers samples for a destination nobody asked about).
