# POST /analyze/network: request and error contract (teacher-server 90dd840 and newer)

Why this exists: Warden v3.3.0 sent only `ip, priority, reason, first_flagged_epoch_millis, proto, dst_port`. The old server filled every other feature from the model's training-set medians and answered "allow", safety 1.0, with one identical reasoning sentence for a 30 MB TCP upload and two 2 MB UDP bursts. A flagged flow was being allowed on no evidence. The server now refuses to score a request that lacks the flow features.

## Request

`Authorization: Bearer <token>`, `Content-Type: application/json`, one JSON object. Key order is irrelevant. Unknown keys (`ip`, `priority`, `reason`, `first_flagged_epoch_millis`, anything future) are ignored. All numbers are plain JSON numbers (not strings), finite and not negative.

| key | type, unit | required | meaning |
|---|---|---|---|
| `proto` | string, lowercase protocol name, `"tcp"` or `"udp"` in practice | **yes** | the **string**, not the class index the on-device student uses (`encodeProto` returns a float index into the student's own list; the server maps the string to its own index) |
| `dst_port` | number | **yes** | destination port |
| `src_byte_count` | number, bytes | **yes** | bytes sent by the device to this destination |
| `src_packet_count` | number | **yes** | packets sent |
| `dst_byte_count` | number, bytes | **yes** | bytes received |
| `dst_packet_count` | number | **yes** | packets received (0 is valid) |
| `duration_millis` | number, **milliseconds** | **yes** | time since the destination was first seen |
| `handshake_latency_millis` | number, **milliseconds** | no | SYN to connect() complete; omit or send 0 for UDP or when no handshake was seen. Server fills 0 (never the training median) |
| `smean` | number, bytes per packet | no | `src_byte_count / src_packet_count`; the server derives it if absent (0 when `src_packet_count` is 0) |
| `dmean` | number, bytes per packet | no | `dst_byte_count / dst_packet_count`; derived if absent (0 when `dst_packet_count` is 0) |

The set of required keys is read from the model (`feature_defaults` keys, minus the three optional ones above), so a retrained model with the same 10 inputs keeps this contract; a model with different inputs would change it and be announced.

## Responses

| status | body | client meaning |
|---|---|---|
| 200 | `{"verdict":"allow"\|"uncertain"\|"block","safety_score":0-1,"reasoning":string\|null}` | a real verdict. `reasoning` is null when the model has no coverage statistics |
| 422 | `{"detail":"no verdict: ...","missing":[names],"invalid":[names]}` | **no verdict.** `missing` = required keys absent, `invalid` = present but wrong (not a number, negative, or an unknown `proto`) |
| 400 | `{"detail":"invalid JSON body"}` | malformed JSON |
| 401 | `{"detail":"invalid or missing API key"}` | token wrong or absent |
| 503 | `{"detail":"model not loaded"}` | server has no model yet |

A 422 body never contains `verdict` or `safety_score`, so it cannot be misread as "allow" by a lenient parser. 422 was chosen over a 200 with an error field because the app's existing handling (`analyze/network ... returned HTTP n`) already treats every non-200 as "no verdict".

## What the client must do

1. **Only a 200 with `verdict == "allow"` may allow.** `block` blocks. `uncertain` (probability between 0.4 and 0.6) is not an allow: keep the destination blocked and ask the user.
2. **On 422, 400, 401, 503, a timeout or no connection: do not allow.** A destination flagged by the on-device stages stays blocked and falls back to the user prompt, exactly as if the cloud were unreachable. Do not retry the same body in a loop on 422: it is a client bug, log `missing`/`invalid` and surface it.
3. Never put the token in logs.

## Mapping to the on-device feature definitions

The student and the teacher use **the same ten names**. `networkFlowFeatures(entry, ...)` in `noxos-app/netmonitor` already builds exactly `dst_port, src_byte_count, src_packet_count, dst_byte_count, dst_packet_count, duration_millis, handshake_latency_millis, smean, dmean, proto`, from `AclEntry.withLiveStats`. **Warden does not need to compute anything new**: send that same map with the live stats at escalation time, with `proto` as the lowercase string instead of the encoded float, and omit `smean`/`dmean` when it omits them (zero packets). It currently drops smean/dmean when the packet count is 0; the server now derives 0 for those, which matches the UNSW definition (mean size is 0 when there are no packets).

The autoencoder (`ML-AUTOENCODER-CONTRACT.md`) uses a subset with the same names: `dst_port, src_byte_count, src_packet_count, dst_byte_count, duration_millis, handshake_latency_millis, smean`, plus `proto`; it does not use `dst_packet_count` or `dmean`.

## Known mismatches (teacher trained on UNSW-NB15, device features measured differently)

- UNSW rows are whole-flow records at the IP layer from a lab capture; the device scores one destination IP early in the flow, aggregated over that destination's flows, with its own byte counting and inbound packets counted per received chunk. Packet and byte magnitudes are therefore not on the same footing, and the teacher has **never been evaluated on device-measured features**. A teacher "block" or "allow" on live flows is unvalidated.
- UNSW `dur` and `tcprtt` are seconds, the app sends milliseconds; the training pipeline converts to milliseconds, so send milliseconds.
- UNSW `proto` has 130 values; only `tcp` and `udp` are meaningful here. Other strings in the list are accepted, strings outside it are 422.
- The teacher was trained with the dataset's `dttl` artifact removed from the inputs (TTL separated the classes by lab setup), and with `state` removed; neither is sent.
- Verdict thresholds: attack probability below 0.4 allow, above 0.6 block, between uncertain.

## Verified

Unit tests in `teacher-server/network_test.go` (identity-only request, empty body, some missing, invalid values, extra keys tolerated, derived means, handshake default, valid request unchanged). Against the real published teacher v1791623224: the Warden v3.3.0 body shape gets 422 naming the five missing keys; a complete 30 MB TCP upload gets `block`; a 2 MB one-way UDP burst (zero downstream packets) gets `block` with `dmean (0)` in the reasoning.
