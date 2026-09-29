# On-device feature-vector log — record format spec, 2026-09-29 (proposal for Warden App to implement; not built)

Purpose: train the network autoencoder on **normal traffic measured by Warden's own relay**, so the training distribution has exactly the on-device meaning of every feature (destination-IP aggregation, early scoring, chunk-counted inbound, header-inclusive outbound bytes). This removes the UNSW-NB15 unit mismatch and its generator artifacts (e.g. TTL). An autoencoder needs no attack labels, so normal phone traffic is enough.

## Rules (the privacy constraints are part of the spec)

1. **Opt-in, default OFF**, one Settings toggle, plus a "clear log" action. Nothing is ever uploaded automatically.
2. **Local only.** A JSON Lines file in app-private storage. Export happens only when the user chooses "Export feature log" and shares the file themselves. The file is human-readable so the user can inspect it before sharing.
3. **No identifiers.** Never log: IP address, domain/SNI, package name or UID, requesting app, DNS names, payload bytes, user or device IDs, exact timestamps. Not even hashed (a hashed IP is still a stable identifier).
4. **One record per scoring event, and it must be exactly the vector the model was given at that moment**, taken at the same point in the flow, computed by the same code path. Do not log a "cleaner" snapshot taken later. If the model scored a destination 12 s after first sight, the record is the 12 s snapshot.
5. **Bounded.** Rotate or cap (suggest 50,000 records, a few MB), drop oldest first.

## Record (one JSON object per line)

```json
{"v": 1, "def": 3, "day": "2026-09-30", "scored_after_s": 12, "proto": "tcp", "dst_port": 443, "state": "CON", "src_byte_count": 5231, "src_packet_count": 41, "dst_byte_count": 88214, "dst_chunk_count": 37, "duration_millis": 12044, "handshake_latency_millis": 31.2, "later_blocked": false}
```

| field | type | meaning |
|---|---|---|
| `v` | int | this record schema version (1) |
| `def` | int | **feature-definition version**: bump whenever any measurement changes (e.g. the fix in `ddb104b` that made inbound count every chunk instead of only the first). The trainer discards records with a stale `def`. |
| `day` | string | UTC date only (`YYYY-MM-DD`), no time of day. For time-based train/validation splits and drift checks. |
| `scored_after_s` | int | seconds between first sight of the destination and this snapshot (0 to ~30 with the 30 s poll; up to 60 for UDP that got no reply) |
| `proto` | `"tcp"`/`"udp"` | relayed protocols only |
| `dst_port` | int | destination port |
| `state` | string | exactly the state string given to the model (`FIN`,`CON`,`INT`,`REQ`,`RST`,`ECO`,`other`) per the agreed mapping |
| `src_byte_count` | int | outbound bytes as the app counts them (whole IP packets from the tunnel, headers and pure ACKs included) |
| `src_packet_count` | int | outbound packets (real packets) |
| `dst_byte_count` | int | inbound bytes as the app counts them (payload only) |
| `dst_chunk_count` | int | inbound read() chunks (TCP) or datagrams (UDP). Logged under a different name on purpose: it is **not** a packet count and must not be fed to the model as one. |
| `duration_millis` | int | now minus first-seen at snapshot time |
| `handshake_latency_millis` | float | SYN-seen to connect()-complete; `0.0` for UDP or when no handshake completed (same value the model would receive) |
| `later_blocked` | bool | true if this destination was later blocked by any tier (autoencoder+student+teacher verdict, or the user). Update the record when that happens. The trainer drops these rows to keep the training set closer to normal. |

Log raw ingredients, not derived features: the trainer derives `smean = src_byte_count / src_packet_count` (and any other derived value) itself, so a formula change never requires re-collecting.

If a later feature group is added (e.g. inter-chunk timing), add new fields and bump `def`; do not repurpose existing ones.

## What the trainer will do with it (for planning, this repo)

- Keep records with the current `def` and `later_blocked == false`; drop UDP records that were never scored.
- Fit the same two-head-per-categorical autoencoder on these records only; threshold = a percentile of reconstruction error on held-out **normal** days (e.g. 99th, so about 1% of normal destinations are flagged; the percentile is a product decision on how many false flags the user tolerates).
- Volume guidance: at least about 20,000 records across several days and several kinds of use (browsing, streaming, messaging, background sync). One person's traffic defines "normal" for that export.
- **Honest limits**: with no attack labels, the only measurable quantity is the false-flag rate on held-out normal days. Detection ability is not measured by this data. To measure it, generate anomalous traffic on purpose through the relay from a test device (port scan, UDP flood, many short connections to unusual ports) with the logger on, tag those sessions, and check they are flagged.
- The exported file may contain a small amount of malicious traffic the user did not notice; `later_blocked` filtering removes some but not all. Expect slight contamination and pick the threshold percentile with that in mind.

## Needs from Warden App

Implement rules 1–5 and the record above; tell me the `def` value you assign, and confirm the state mapping and `scored_after_s` semantics match how scoring really happens. Nothing else is needed from them until the trainer exists.
