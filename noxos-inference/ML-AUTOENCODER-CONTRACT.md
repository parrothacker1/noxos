# Autoencoder export contract, 2026-09-30 (the MIRAGE-trained first gate)

For `noxos-app`'s `OnDeviceAutoencoder`. This replaces the contract of the deprecated dttl model. Everything a consumer needs is inside `model.json`; nothing below should be hard-coded except the algorithm. **Future retrains keep this exact feature set, order, transforms and categories, so they are model-only releases** (new `model.json`, same code). Any change to `numeric_features`, `numeric_transforms`, `categorical_features` or the error formula is a breaking change and will be announced.

Status: a **low-trust first gate**, not a verdict. Trained on MIRAGE-2019 normal traffic only (20 apps, 2 devices). No attack data, so F1 is not measured. See `METRICS.md` in the release.

## Delivery

Release `autoencoder-latest` on `parrothacker1/noxos-inference`: `model.json`, `manifest.json` (`{"version": <int>, "sha256": "<hex of model.json>", "modelUrl": "<url>"}`, same as the other models), `model.json.sha256`, `METRICS.md`. Verify the SHA-256 before use, as for the other models.

## `model.json` shape

```json
{
  "numeric_features": ["dst_port", "src_byte_count", "src_packet_count", "dst_byte_count", "duration_millis", "handshake_latency_millis", "smean"],
  "numeric_mean": [7 floats],
  "numeric_std": [7 floats],
  "numeric_reduction": "mean",
  "numeric_transforms": {"dst_port": "log1p", "src_byte_count": "sqrt", "src_packet_count": "sqrt", "dst_byte_count": "sqrt", "duration_millis": "sqrt", "handshake_latency_millis": "sqrt", "smean": "sqrt"},
  "categorical_features": [{"name": "proto", "categories": ["tcp", "udp", "other"]}],
  "reconstruction_thresholds": {"tcp": <float>, "udp": <float>},
  "encoder": [{"weight": [[...]], "bias": [...], "activation": "leaky_relu"}, {"weight": [[...]], "bias": [...], "activation": "linear"}],
  "decoder_trunk": [{"weight": [[...]], "bias": [...], "activation": "leaky_relu"}],
  "decoder_numeric_head": {"weight": [[...]], "bias": [...], "activation": "linear"},
  "decoder_categorical_heads": [{"name": "proto", "weight": [[...]], "bias": [...], "activation": "linear"}],
  "leaky_relu_negative_slope": 0.01
}
```

`weight` is row-major `[out][in]` (`y = W x + b`). Shapes: encoder 32x10 then 4x32, trunk 32x4, numeric head 7x32, proto head 3x32.

## Inputs, in order, and what each means

| # | feature | definition (must match the capture) |
|---|---|---|
| 1 | `dst_port` | destination port of the destination's first connection |
| 2 | `src_byte_count` | outbound bytes: whole IP packets from the tunnel, headers and pure ACKs included |
| 3 | `src_packet_count` | outbound packets (real packets) |
| 4 | `dst_byte_count` | inbound payload bytes only (every chunk, not just the first) |
| 5 | `duration_millis` | milliseconds from first sight of the destination to this scoring moment (0 to about 30000) |
| 6 | `handshake_latency_millis` | SYN seen to connect() complete, `0.0` for UDP or when no handshake completed |
| 7 | `smean` | `src_byte_count / src_packet_count`, `0.0` if no outbound packets |

`proto` is `"tcp"` or `"udp"` (one-hot over `categories`; any other value maps to `"other"`, but only TCP and UDP are scored). **Not inputs anymore: `state`, `dttl`, `dst_packet_count`, `dmean`.**

## Algorithm

1. For each numeric feature `f`: apply `numeric_transforms[f]` to the raw value clamped at 0 (`log1p(x)` or `sqrt(x)`), then `z = (t - numeric_mean[i]) / numeric_std[i]` (mean and std are of the transformed values).
2. Input vector = the 7 z-scores, then the one-hot of `proto` in `categories` order (length 10).
3. `h = leaky_relu(W1 x + b1)`; `code = W2 h + b2` (no activation); `t = leaky_relu(W3 code + b3)`. `leaky_relu(v) = v if v >= 0 else 0.01 * v`.
4. `numeric_recon = Wn t + bn` (7 values); `logits = Wp t + bp` (3 values).
5. **Error** = mean over the 7 features of `(numeric_recon[i] - z[i])^2`, plus the proto cross-entropy `-(logits[k] - log(sum(exp(logits))))` where `k` is the index of the true proto (use a numerically stable log-sum-exp). Unweighted sum. Natural log.
6. **Flag** when `error > reconstruction_thresholds[proto]`. A destination with any other protocol is not scored (fail-open).

## Thresholds

One per protocol, set on calibration data of that protocol (TCP at the 97th percentile, UDP at the 99th, of normal traffic from apps held out of training). They change on every retrain: **always read them from `model.json`.**

## Measured behaviour (MIRAGE, unseen apps, mean over 5 app splits; details in METRICS.md)

- Normal traffic flagged: **TCP 2.1% (0.6-3.5%), UDP 9.1% (0.8-19.4%)**.
- Synthetic shapes I defined (sanity only): UDP flood 99%, big upload 99%, SYN scan 44% (0-75%).
- F1 is **not measurable** (no attacks). Awaits Warden-logged traffic plus deliberate test traffic.

## Known weaknesses (accepted)

UDP calibration is thin (132-807 calibration rows per split) and UDP false flags are high and vary by app; SYN-scan-like traffic is detected only partly; "normal" is 20 apps on 2 devices, so an unfamiliar app can look unusual; training used per-destination snapshots aggregated from flows that are assumed to start together; no attack data.

## Golden test vectors (check your Kotlin against these; tolerance 1e-4)

**TCP sample (not flagged)**  
`input`: `{"proto": "tcp", "dst_port": 80.0, "src_byte_count": 102123.89269626162, "src_packet_count": 1894.6602989194519, "dst_byte_count": 5167702.0398060735, "duration_millis": 19908.723520133364, "handshake_latency_millis": 50.00185966491699, "smean": 53.90089862256793}`  
expected reconstruction error `0.021474`, threshold `0.322667`, flagged `false`
**UDP sample (flagged)**  
`input`: `{"proto": "udp", "dst_port": 44790.0, "src_byte_count": 197483.59723275586, "src_packet_count": 340.5582810061172, "dst_byte_count": 109026.41195575793, "duration_millis": 12103.02585013446, "handshake_latency_millis": 0.0, "smean": 579.8819416439578}`  
expected reconstruction error `0.140742`, threshold `0.125071`, flagged `true`
**TCP big upload (flagged)**  
`input`: `{"proto": "tcp", "dst_port": 443.0, "src_byte_count": 40000000.0, "src_packet_count": 30000.0, "dst_byte_count": 50000.0, "duration_millis": 20000.0, "handshake_latency_millis": 30.0, "smean": 1333.3333333333333}`  
expected reconstruction error `17.171206`, threshold `0.322667`, flagged `true`

## What changed for the current consumer (vs the deprecated dttl model)

- `numeric_features`: 7, not 9 or 10 (`dst_packet_count`, `dmean`, `dttl` removed).
- Categorical: `proto` only, categories `tcp, udp, other` (no `state`).
- **Scaling is now explicit in the file** (`numeric_transforms`): `dst_port` uses `log1p`, every other numeric uses `sqrt`, then z-score. The old model used `log1p` on everything and the file did not say so.
- `reconstruction_thresholds` (object with `tcp` and `udp`) replaces the single `reconstruction_threshold`.
- Activation is `leaky_relu` with slope in `leaky_relu_negative_slope` (was ReLU in the very first release).
- Error formula is unchanged in shape: mean of numeric squared errors plus the categorical cross-entropies.
- Model size is about 22 KB.
