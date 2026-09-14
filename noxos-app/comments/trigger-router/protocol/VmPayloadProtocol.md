# trigger-router/src/main/java/com/noxos/triggerrouter/protocol/VmPayloadProtocol.kt

## `TASK_FILE_SCAN`

Parse the request payload as an image file and return its EXIF metadata (or a parse error).

## `TASK_NETWORK_SAMPLE`

Run a header-sanity/protocol-conformance check on a raw packet sample and return a flagged verdict.

## `encodePacketSamples`

`TASK_NETWORK_SAMPLE`'s payload shape: a small, self-contained list of raw packets, not
always exactly one - a newly-flagged destination's sample can include both the outbound
packet that caused the flag and the first inbound reply, captured separately (see
`NetMonitorService.pendingPacketSamples`). Framing: `[2-byte unsigned count][per packet:
4-byte length][packet bytes]...`. Note the packets themselves aren't uniform: the outbound
one is a full captured IPv4 packet (as seen on the tun interface); an inbound UDP reply is
bare UDP payload bytes only (as received from the real OS socket - no synthetic IP/UDP
header reconstructed), while an inbound TCP reply is the raw bytes read from the relayed
socket's InputStream (also no synthetic header). The guest-side check needs to handle a
mixed list, not assume every entry is a parseable IPv4 packet.

**Note for the noxos-payload contract**: this exact framing is documented in full in
`knowledge-graph/noxos-payload/TASKS.md` — that's the canonical cross-repo copy, this is
just the same rationale kept next to the code that implements it.
