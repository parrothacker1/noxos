# noxos-inference: results for the paper

Single source for writing up the threat-analysis backend of NoxOS ("Warden"). Everything here was measured in this repository's own runs unless marked **UNMEASURED**. Where a number has a catch, the catch is next to it. Details and history: `TASKS.md`, `ML-NETWORK-DESIGN.md`, `ML-FILE-DESIGN.md`, `ML-AUTOENCODER-CONTRACT.md` (and `ML-DEVICE-LOG-SPEC.md`, a logging design that was dropped). Written 2026-10-10.

## 0. What is and is not established (read this first)

Established (on the stated data):
- A supervised XGBoost teacher reaches **F1 0.9713** out-of-fold on all of UNSW-NB15 with a leak-free grouped split; a 100-tree distilled student agrees with it on **99.56%** of verdict buckets (F1 0.9849 vs 0.9862 on the same held-out fold).
- Standard random splits of UNSW-NB15 are badly inflated by duplicate feature patterns (54.68% of test rows had an exact duplicate in train). Grouped splitting is mandatory.
- A tree-JSON export format evaluates identically to the trained XGBoost model once split comparisons are done in float32 (a float64 comparison flips verdicts).
- Exact per-feature Shapley attributions (TreeSHAP), re-implemented in Go, match the reference Python `shap` library to ~1.9e-6.
- An APK permission classifier trained on Drebin reaches **F1 0.920** under grouped cross-validation, against **0.255** for a hand-written permission-count rule.

**Not** established:
- **No detection performance of the on-device autoencoder is measured.** The only attack-labelled data (UNSW-NB15) does not match the on-device feature definitions, and the only phone-realistic data (MIRAGE) contains no attacks. All reported autoencoder detection figures are proxies or synthetic shapes and are labelled so.
- No result here was measured on live Warden traffic or on a real device. The file classifier has not been evaluated on modern APKs.
- The UNSW-NB15 teacher/student numbers describe a 2015 lab network and probably benefit from generator artifacts (Section 3.3 shows one such artifact, destination TTL, in detail). They are not claims about real-world detection.

## 1. System and rationale

Goal: decide, with a low false-block cost and without sending raw payloads or files off the device, whether a newly seen network destination or a quarantined file is dangerous.

Network cascade (a destination is evaluated once per monitoring session):

1. **Autoencoder** (on device; unsupervised; trained on normal traffic only; ~974 parameters: 10 -> 32 -> 4 -> 32 -> heads). First gate for any unresolved destination. Rationale: it needs no attack labels and can flag shapes a supervised model never saw. Reconstruction error is compared with a per-protocol threshold. A flag blocks the destination until the student answers.
2. **Student** (on device; XGBoost regressor, 100 trees, depth 4) distilled from the teacher. Rationale: near-teacher accuracy at a fraction of the size (plain tree walk, no ML runtime). "Not a threat" allows the destination for the current monitoring session only.
3. **Teacher** (server; XGBoost classifier, 500 trees, depth 6, trained on 100% of the data) for the final verdict on whatever the student does not clear. Rationale: the larger model is affordable because it only sees the residue.
4. The user's override wins at every step.

File analysis: **server-only, advisory-only.** The device extracts features in an isolated VM and forwards only the list of requested permission strings (never the file, a hash, the file name or the package name). An XGBoost classifier trained on Drebin scores it. It must not gate quarantine or any verdict (Section 5).

Models are hot-loaded by the server and the app from GitHub Releases through a manifest + SHA-256 verification, so retrains are model-only releases.

## 2. Datasets and methodology

| dataset | what we used | size | licence / terms |
|---|---|---|---|
| UNSW-NB15 [1] (HuggingFace mirror `Mouwiya/UNSW-NB15`, last modified 2024-05-15, two parquet files of 124,419,404 and 105,596,940 bytes) | supervised teacher/student; autoencoder history and proxy checks | 2,280,090 rows; 7 dropped (unparseable destination port) -> 2,280,083; 1,199,022 distinct 10-feature patterns; attack rate 11.09% | The mirror declares no licence field. The data is published by UNSW for research with citation. **Redistribution terms UNMEASURED/unverified; check before releasing anything derived.** |
| MIRAGE-2019 [2] (public download `MIRAGE-2019_traffic_dataset_downloadable_v2.tar.gz`, 1,457,287,750 bytes) | normal-only autoencoder | **20 apps on 2 devices** (the paper describes 40 apps; the public release is a subset); 1,642 capture files; 124,950 destination snapshots (118,890 TCP, 6,060 UDP) | CC BY-NC-ND 4.0: non-commercial, no derivatives. A commercial product must retrain on its own traffic. |
| Drebin-215 feature CSV [3] (third-party GitHub mirror, SHA-256 pinned) | file classifier | 15,036 apps (5,560 malware / 9,476 benign), 215 features (113 permissions, 23 intents, 72 API calls, 6 commands); 5 rows with `?` dropped -> 15,031; **7,256 distinct feature patterns**, 3 patterns carry both labels | The original paper describes 123,453 benign apps; the downloadable feature file is the smaller one. Redistribution rights of the mirror **unverified**; nothing from the CSV is committed. |

UNSW-NB15 feature set (locked): `proto` (categorical), `dst_port`, source/destination bytes and packets, duration (ms), handshake latency (ms), derived mean packet sizes (`smean`, `dmean`). Cleaning: hexadecimal and `-` ports parsed or dropped; seconds converted to milliseconds.

**Leak-free evaluation.** Many rows share an identical feature pattern. All supervised evaluations therefore use `StratifiedGroupKFold` (scikit-learn [7]) with the group = the exact feature pattern, and a hard assertion that no pattern is in both train and held-out. The teacher uses 5 folds so every row is scored exactly once by a model that never saw its pattern (out-of-fold, OOF). The file classifier groups by pattern within each feature set. For MIRAGE the split is **by app** (train 14 / calibration 2 / test 4 apps for the primary split), repeated over 5 different app splits, so the test measures unseen apps. A trainer for an opt-in on-device feature log (split by day) was written and tested on synthetic records only; the logger was later dropped by decision, so that trainer is unused and is not part of the results.

**Selection caveat that applies to every autoencoder figure on UNSW-NB15:** thresholds were chosen by sweeping percentiles on the same held-out data that is reported, so those F1 values are optimistic. MIRAGE thresholds come from separate calibration apps and are evaluated on separate test apps.

## 3. Results

### 3.1 Why random splits are wrong here (history of the first model)

| split | result | note |
|---|---|---|
| random row split (80/20, stratified) | F1 0.9724 | 92,702 feature patterns (54.68% of test rows) also occurred in train |
| row-level result restricted post hoc to novel patterns | F1 ~0.8831 | coarse estimate on the already-leaky split, kept only as history |
| `GroupShuffleSplit` | attack rate train 9.36% vs test 17.06% | no stratification: 82.3% relative skew, rejected |
| `StratifiedGroupKFold`, first fold | F1 0.9858 (accuracy 0.9968, precision 0.9816, recall 0.9900); attack rate 11.09% on both sides; 0 shared patterns | that single-model pipeline was later replaced by the teacher/student pipeline |

### 3.2 Teacher and student (UNSW-NB15)

Teacher: 5 XGBoost classifiers, 500 trees, depth 6, learning rate 0.1, `subsample` 0.8, `colsample_bytree` 0.8, seed 42, one per grouped fold.

| teacher out-of-fold, all 2,280,083 rows | value |
|---|---|
| accuracy | 0.9937 |
| precision | 0.9773 |
| recall | 0.9654 |
| F1 | **0.9713** |

The deployed teacher is a separate single model trained on 100% of the data (the fold models only exist to produce leak-free targets). **Its own held-out F1 is UNMEASURED** (there is no held-out data left); it is assumed close to the fold models.

Student: `XGBRegressor(objective="reg:logistic")`, 100 trees, depth 4, trained to regress the teacher's OOF probability (distillation [8], not the true label). Evaluated on one grouped held-out fold (20% of the data), against the teacher's OOF predictions on the same rows:

| | teacher (OOF) | student |
|---|---|---|
| accuracy | 0.9969 | 0.9966 |
| precision | 0.9825 | 0.9837 |
| recall | 0.9899 | 0.9861 |
| F1 | 0.9862 | **0.9849** |

Fidelity: RMSE 0.0230 between student and teacher probabilities; verdict-bucket agreement (allow < 0.4, uncertain 0.4-0.6, block > 0.6) **99.56%**. Note the teacher's F1 on this fold (0.9862) is higher than its full-data OOF F1 (0.9713): the fold is a 20% subset, not the whole dataset, so compare only within the table.
Caveat: the student's training targets are OOF predictions, so it is not trained on any model's memorization of that row; it is not compared against a plain 100-tree model trained on raw labels (**UNMEASURED**), so the benefit of distillation over a same-size model is not shown.

### 3.3 Destination TTL: a generator artifact in UNSW-NB15

The autoencoder first reached F1 0.80-0.86 only after adding destination TTL (`dttl`) and connection `state`. Measured on held-out rows of the released model:

- TCP normal rows: TTL 29 in 1,038,354 of ~1.06M (98%). TCP attack rows: TTL 252 in 45,311 of 45,327 (99.96%). UDP normal is 29 or 0. The lab generated attacks and normal traffic from different hosts with different TTLs, so TTL alone separates the classes.
- With the true `dttl`, UDP held-out F1 was 0.989 but TCP only 0.256 (precision 0.147). Replacing `dttl` with 29 dropped UDP to 0.720 and left TCP unchanged (0.2554 vs 0.2556).
- Conclusion: the 0.80-0.86 figures were mostly this artifact. Separately, an Android app cannot read the destination TTL for TCP (kernel returns a constant; raw sockets are blocked), so the feature was removed. The deprecated releases are kept for history but marked deprecated.
- Other UNSW features may contain comparable artifacts. A per-feature, per-protocol artifact check was done for `dttl` only; it was **not** done for the 10 features used by the teacher/student (**UNMEASURED**). Treat 0.97-0.99 as an upper bound on UNSW-NB15, not as real-world accuracy.

### 3.4 Autoencoder on UNSW-NB15: history and the honest number

| step | features | F1 | status |
|---|---|---|---|
| first model, ReLU | 10 features incl. `dst_packet_count`, `dmean`; all protocols | 0.750 local (92nd percentile), 0.757 in CI | threshold cliff: F1 0.076 at the 93rd percentile because ~90% of attack rows sit at one reconstruction error (row duplication). Threshold chosen on the evaluation set |
| LeakyReLU only | same | 0.711 (30-epoch screen) | no gain; 0 of 4 bottleneck units and 0 of 32 hidden ReLU units were dead, so there was nothing for LeakyReLU to fix |
| + `dttl` | + destination TTL | 0.860 (30 ep) | artifact |
| + `dttl` + `state` (state as its own head) | 12 inputs | 0.805 local / 0.856 CI (60 ep); screen 0.882 | artifact; run-to-run spread ~0.05 from threaded floating-point training |
| TCP/UDP only, no `dttl`, first stratified split | Warden-reproducible features, `state` | 0.852 | **invalid**: the held-out set contained zero TCP attacks |
| same, split stratified on label x protocol (435,593 held-out rows; TCP attack rate 3.6%, UDP 18.0%) | log1p on `dst_port` only | **0.701** overall (P 0.619, R 0.809) | UDP F1 0.941 (normal UDP flagged 0.8%); **TCP F1 0.280** (P 0.199, R 0.474; normal TCP flagged 7.2%) |
| same, log1p on all counts | | **0.687** overall (P 0.541, R 0.942) | UDP F1 0.976 (normal UDP flagged 0.13%); **TCP F1 0.349** (P 0.217, R 0.891; normal TCP flagged 12.1%) |

Reading: without the artifact, the unsupervised autoencoder is a UDP detector (F1 0.94-0.98) and a weak TCP detector (F1 0.28-0.35, with 7-12% of normal TCP flagged). The overall F1 is dominated by UDP. This is a property of unsupervised detection on coarse aggregates (most UNSW TCP attacks look normal on them), not evidence about phones.

### 3.5 Autoencoder on MIRAGE-2019 (real Android traffic, normal only; the shipped model)

Features rebuilt per destination IP at a random snapshot time in 0-30 s (matching how Warden scores): `proto`, `dst_port`, upstream IP bytes and packets, downstream payload bytes, handshake latency (real SYN to SYN-ACK), duration, `smean`. Scaling: `log1p` for `dst_port`, `sqrt` for the others, then z-score (sqrt chosen over log1p because log1p hid large transfers). Loss: mean squared error over numeric features plus protocol cross-entropy; LeakyReLU (slope 0.01), Adam 1e-3, batch 512, 60 epochs, ~974 parameters. One threshold per protocol from calibration apps of that protocol: **TCP at the 97th percentile, UDP at the 99th**.

Honest data limits: per-packet detail covers only each flow's first 32 packets (later counts interpolated linearly from flow totals); flows have no absolute start time, so a destination's flows are assumed to start together; upstream IP bytes are payload plus the flow's average header overhead; the data has no TCP flags, so `state` is not a feature; 95% of snapshots are TCP and "normal" means 20 apps.

False-flag rate on normal traffic from apps never seen in training, mean (min-max) over 5 app splits:

| calibration percentile | all | TCP | UDP |
|---|---|---|---|
| 95 | 0.0615 (0.0278-0.1257) | 0.0355 (0.0134-0.0568) | 0.2548 (0.0903-0.4562) |
| 97 | 0.0430 (0.0145-0.0918) | 0.0212 (0.0064-0.0347) | 0.1836 (0.0625-0.3553) |
| 99 | 0.0196 (0.0049-0.0408) | 0.0073 (0.0021-0.0129) | 0.0909 (0.0077-0.1944) |

**First-publication configuration (TCP 97th, UDP 99th; the UDP part was superseded, see 3.5.1): normal TCP flagged 2.1% (0.6-3.5%), normal UDP flagged 9.1% (0.8-19.4%).** UDP calibration is thin (132-807 calibration UDP rows per split) and varies strongly by which apps are held out. Choosing the threshold percentile per protocol from the same splits makes these rates slightly optimistic.

Synthetic anomaly shapes defined by us in feature space (**sanity checks, not validation**; detected fraction, mean (min-max)): at the shipped thresholds SYN-scan-like 44% (0-75%), UDP-flood-like 99% (98-100%), big-upload-like 99% (97-100%). With `log1p` scaling instead of `sqrt`, big uploads were detected only 57% (0-90%) at the 97th percentile, which motivated the change; `sqrt` raised normal UDP false flags (13.8% to 22.8% at the 97th percentile, 3-split comparison).

#### 3.5.1 UDP threshold recalibration (v1791661543, 2026-10-11)

Trigger: on a Cuttlefish device the app flagged 15 of 15 fresh UDP destinations as unusual, including 4 real DNS exchanges (errors 0.14-0.27 against the 0.125 threshold). These were tiny test flows on one device, so a true rate is unmeasured; the threshold was deliberately not tuned to them. Instead the rule was changed on MIRAGE alone, weights and contract untouched.

Problem with the old rule: one split's calibration apps (132-807 UDP rows) gave thresholds from 0.125 to 0.499 across the five splits, and YouTube alone is 69% of pooled UDP rows.

New rule: the 99th percentile of normal UDP error pooled over out-of-fold rows of all five splits (each scored by a model that never saw its app), every app weighted equally. Shipped UDP threshold 0.125071 -> **0.429368**; TCP 0.322667 unchanged. Leave-split-out evaluation (threshold from the other splits, excluding the evaluated split's test apps), mean (min-max) over 5 splits:

| rule | UDP false-flag, unseen apps | per-app mean | synthetic UDP flood detected | DNS-like MIRAGE flows flagged |
|---|---|---|---|---|
| old: 99th of one split's calibration | 5.9% (0.3-19.4%) | 3.3% (0.2-9.5%) | 98.1% (95.9-99.9%) | 14.3% (0-40%) |
| new: app-balanced pooled 99th | **2.2% (0-5.1%)** | 1.6% (0-6.2%) | 94.6% (86.3-99.3%) | 6.1% (0-26.5%) |

Cost: UDP flood sensitivity drops by about 3.5 points on average, and in the worst split to 86%. DNS-like means at most 3 source packets, under 400 source bytes and under 2000 destination bytes; MIRAGE has no port-53 traffic, so this is a shape proxy (Spotify discovery, STUN, DHCP) and real DNS remains untested in training. Rerunning the old procedure gave 5.9% where the first publication reported 9.1%: training is not bit-reproducible between runs. Plain higher percentiles of the calibration set were rejected: 99.9th and the maximum still left up to 8-10% on a bad split because the threshold itself was unstable. Not fixed: F1 is still unmeasured, and a few percent of normal UDP is still flagged. Reproduce with `training/recalibrate_udp.py`.

Proxy check (scoring UNSW-NB15 with the MIRAGE-trained model) gave F1 0.18-0.29 overall, ~0.05 on TCP, and rated UNSW normal TCP as *more* anomalous (median error 0.572) than UNSW attack TCP (0.217). It measures the gap between two networks, not attacks, and is **discarded**.

**The detection rate and F1 of the shipped autoencoder are UNMEASURED**, and no further autoencoder retraining or data collection is planned. It is presented as it is: a low-trust first gate trained on MIRAGE normal traffic only, whose only in-domain measurements are false-flag rates on unseen apps and responses to synthetic shapes.

### 3.6 File classifier (Drebin permissions)

XGBoost, 300 trees, depth 6; 5-fold grouped out-of-fold evaluation (each feature set grouped by its own patterns):

| feature set | columns | precision | recall | F1 | AUC |
|---|---|---|---|---|---|
| **permissions (deployed)** | 113 | 0.950 | 0.893 | **0.920** | 0.980 |
| permissions + intents | 136 | 0.956 | 0.894 | 0.924 | 0.983 |
| all 215 (API calls; not extractable cheaply on device) | 215 | 0.985 | 0.969 | 0.977 | 0.998 |
| baseline: `noxos-payload` rule, >= 4 high-risk permissions (12 of its 14 names exist in Drebin) | 12 | 0.588 | 0.163 | 0.255 | n/a |

Reading: the learned model beats the hand rule by a wide margin because most Drebin malware requests few dangerous permissions; intents add only +0.004 F1; the signal missing from permissions is in API calls. Top features include `SEND_SMS` (0.146) and several legacy permissions (history/bookmarks, account management), suggesting it partly recognises 2010-2012 malware families (an inference from the importance ranking, not checked per family).
**Limits:** it only knows the 2012 permission vocabulary, so modern permissions are invisible to it (3 of the 8 permissions declared by Warden itself are in the vocabulary). A single sanity check on the locally available modern APKs (one app family, so weak evidence) gave p_malware 0.275 for Warden's own builds and 0.015-0.034 for two demo apps. **Performance on modern benign or malicious APKs is UNMEASURED.** The server marks every response `advisory: true`.

### 3.7 TreeSHAP explanations (server)

The path-dependent TreeSHAP algorithm [5] (the algorithm behind `shap.TreeExplainer` [4]) was ported from the reference C++ source into Go, working directly on the exported tree JSON (which carries per-node cover). Verification against the Python `shap` library on 10 real rows and the full 500-tree production teacher: maximum |phi| difference **1.85e-6**, maximum base-value difference **2.0e-7**, and the efficiency property (base value + sum of phi = the model margin) holds. A small synthetic tree is the permanent regression test, hand-checked (base 0.07; margin -1.4 = 0.07 + (-0.6617 - 0.8083)). The response `reasoning` names the features with the largest attributions in the direction of the verdict. On device, reasoning uses a simpler deviation-from-normal ranking (not implemented in the app yet).

### 3.8 Export and serving parity

| artifact | check | result |
|---|---|---|
| student tree JSON vs `XGBRegressor.predict` | 30 real rows, float32-aware comparison | max diff < 1e-6 |
| teacher tree JSON vs `predict_proba` | 30 real rows | exact (0.000000) |
| Drebin file model JSON | 200 real rows | max diff 1.5e-7, 100% verdict-bucket agreement |
| autoencoder JSON (network math) | 200 real rows | max error diff 1.3e-7 |
| autoencoder encoding rebuilt from the JSON alone (transforms, z-score, one-hot) | 200 real rows | max diff 4.5e-7 |
| autoencoder golden vectors reproduced from the published file | 3 vectors | all match |

## 4. Engineering findings worth reporting

1. **Float32 split comparisons.** XGBoost stores and compares feature values as float32. Re-implementations that compare in float64 take the wrong branch when a value is within float32 rounding of a threshold (`duration_millis = 0.001` against a threshold of `0.00100000005` are the same float32). Observed: 7 of 100 trees landed on the wrong leaf for one sample, flipping a verdict (real 0.6782 "block" vs exported 0.3465 "allow"). An earlier session had loosened a test tolerance (0.05 -> 0.2 -> 0.3) instead of root-causing it. Casting both sides to float32 gave exact parity; a regression test reproduces the boundary case. Any consumer of the export (including the Kotlin interpreter) must do the same.
2. **Duplicate patterns drive both leakage and a threshold cliff.** The dataset has 1.2M distinct patterns in 2.28M rows. Beyond leaking across random splits, duplication concentrated ~90% of attacks at one reconstruction error and produced an F1 cliff (0.75 to 0.076 between the 92nd and 93rd percentile).
3. **Evaluation set construction can silently invalidate a metric.** A grouped split put all TCP attacks in the training side, so a held-out F1 of 0.852 had no TCP attacks in it. Stratifying on label and protocol together exposed TCP F1 of 0.28-0.35. Always report per-protocol (per-stratum) results.
4. **Dataset generator artifacts** (TTL 29 vs 252) can supply most of a model's apparent accuracy; check any feature that is a property of the capture setup rather than of behavior.
5. **Silent degradation of explanations.** The teacher and student models first published predated the export extension that adds per-node cover; with zero cover the TreeSHAP division is 0/0 and every attribution is NaN, so the server returned a generic "nothing stood out" sentence for every request. Fixed on 2026-10-10 by re-publishing both models with cover (teacher v1791623224, student v1791623396; a local server run against the new teacher now returns a real TreeSHAP sentence, not the fallback) and by returning an explicit `reasoning: null` when a model has no coverage statistics (with tests).
6. **Under-specified contracts cost round trips.** The autoencoder export originally omitted the input transforms (they lived only in messages) and left open whether the numeric loss term is a mean or a sum (a sum would inflate it ~9x against the calibrated threshold). The export now carries `numeric_transforms`, `numeric_reduction`, per-protocol `reconstruction_thresholds`, and golden test vectors.
7. **Train/serve unit mismatch** is the main validity risk for network models: dataset rows are whole-flow records at the IP layer, while the app scores per destination IP early in the flow with different byte counting, chunk-counted inbound packets, TCP/UDP only. This is why the final autoencoder was rebuilt from per-packet data truncated to the first 30 s.
8. **Resource limits on tiny instances.** Compiling the Go server on a 1 GiB instance was killed by the out-of-memory killer (46 minutes, no service); the fix is to cross-compile and ship a SHA-256-verified static binary.
9. **Capture bug found by the consumer.** Until app commit `ddb104b` the on-device inbound counter only counted the first chunk, so destination features were near-meaningless; the specified opt-in feature log recorded a definition version (`def`) so stale records would be discarded by a trainer (the feature log itself was later dropped).

## 5. Limitations and threats to validity

- **Unit mismatch** (UNSW-NB15 flow records vs per-destination early snapshots) means no UNSW number describes on-device behavior. MIRAGE removes most of the mismatch but has its own approximations (Section 3.5).
- **No attack data on device.** Autoencoder detection is unmeasured; only normal-traffic false-flag rates and synthetic shapes exist.
- **Generator artifacts.** UNSW-NB15 is synthetic traffic from a lab; only one artifact was characterised. The teacher and student numbers are likely optimistic for real networks.
- **Small normal-traffic coverage.** MIRAGE public release is 20 apps on 2 devices (mostly HTTPS over TCP); UDP calibration is based on 132-807 rows. False-flag rates vary widely by app (UDP 0.8%-19.4%). Thresholds are tuned on 2 calibration apps per split.
- **Threshold selection on the evaluation data** for the UNSW autoencoder figures (optimistic); floating-point run-to-run spread of ~0.05 F1 for the neural model on different hardware.
- **File model is advisory only.** 2012 vocabulary, no modern-APK evaluation, trained on a third-party feature mirror; the OR-gate with rule-based checks and ClamAV-style signatures is deliberately not used (raw bytes never reach the server).
- **Cascade effect not measured end to end.** The interaction of the stages (a false autoencoder flag blocks a destination until the student answers) has not been evaluated on live traffic.
- **Distillation benefit not isolated** (no same-size direct-label baseline).
- **Licences.** MIRAGE-2019 is CC BY-NC-ND 4.0 (non-commercial, no derivatives); the UNSW-NB15 mirror and the Drebin mirror have unverified redistribution terms.
- **Privacy design, not a privacy proof.** The system sends only extracted features (network feature vectors, permission strings) and never raw files; no formal privacy analysis was done.

## 6. Reproducibility

Repository: `github.com/parrothacker1/noxos-inference`. Code lives on topic branches; `main` holds only the CI workflows and README. Software versions are pinned in each branch's `training/pyproject.toml` / `uv.lock` (Python 3.12, pandas 3.0.5, scikit-learn 1.9.1, xgboost 3.4.1, torch 2.14.0 CPU) and in `go.mod` (Go 1.26.5, gin 1.12.0).

| component | branch @ commit | release tag (latest) | model.json SHA-256 | CI run |
|---|---|---|---|---|
| teacher (production, with cover) | `teacher-xgboost` @ 0df9183 | `teacher-latest` | 4e108fa98ea890ac153c4580a73318ad0a4ff97f883e2049182b55c22d6fe524 (v1791623224) | 38039833310 (earlier: 35819294512) |
| student (with cover) | `student-xgboost` @ e0d4b43 | `student-latest` | 1e564271588e73d9fd1b5102d08f2b28120b4385f5538a6359d192f88a8ab0d0 (v1791623396) | 38040268937 (earlier: 35819656301) |
| file classifier (advisory) | `file-classifier` @ a577db9 | `file-latest` (v1790706350) | `7edf44588f7370cbd8b4ed46719216289ff3dc8a8e58b0e955d9abd84edb8224` | 36611942530 |
| autoencoder (MIRAGE; published by hand) | `filter-autoencoder` @ 657d956 / 07ebe25 | `autoencoder-latest` (v1791661543, UDP threshold recalibrated, @ 07ebe25; v1790722998 sha `e6cd5822c8c27718d2a7835d21bdc9a51537885ad0e24a8ff0906e59300c2206` superseded) | `ba13d20e3f118b6247a5b5d9c11162b30b7b148204dc14c7d5d8e3cd7b218950` | manual (CI disabled: archive too large) |
| server (Go, TreeSHAP, hot reload) | `teacher-server` @ b06fc49 | `teacher-server-latest` | 38bec4fc4afef4e826249747c853b1c656a81558bc618bb4ad714e98c141dfc0 | n/a (cross-compiled by hand) |

Earlier CI runs for reference: teacher 35793397584, student 35793896196, production teacher 35819294512, student retrain 35819656301; autoencoder (UNSW, deprecated) 36494365223 and 36605909523. Older releases `autoencoder-1790636404` and `autoencoder-1790704070` are marked DEPRECATED.

Dataset pins: Drebin features SHA-256 `710f2c11b0cad04c36f56dd16398127feb697fd99e8efa7f75890b792fba3ad5`, categories `186ff7911d80f0c7268047886e50761ef0221d028e0ed140024cd89e5e57725b`; MIRAGE archive `14d8f0a86cc288492dab0ddba4178255873c3c8bba1c3440aa38a908fad60221`; UNSW parquet files `2aada2a26d061111f4e8fb84e716f5f11264fee71abe04697d42cb89e488d047` and `7c6699ae967567977dee9e9193543b515255f4e1671ca79bf9ae65e7866ffef1`.

Commands (each from the branch's `training/` directory after `uv sync`):
- Teacher: fetch the two UNSW parquet URLs from `config.toml` into `data/raw/`, then `uv run train_teacher.py && uv run train_teacher_production.py && uv run export_teacher_model.py && uv run test_export.py`. CI: workflow `Train and publish teacher model` (manual dispatch), which also triggers the student workflow.
- Student: `uv run train_student.py && uv run export_student_model.py && uv run test_export.py` with the teacher's `oof_predictions.parquet` downloaded to `data/teacher_oof.parquet`.
- File classifier: fetch the two pinned Drebin files into `data/`, then `uv run train_file.py && uv run test_export.py`.
- Autoencoder (MIRAGE): download and extract the MIRAGE archive to `data/raw/mirage/`, then `uv run mirage_features.py && uv run train_mirage.py && uv run test_export.py`; publish `model.json`, `manifest.json`, `model.json.sha256`, `METRICS.md` as a release. Training uses seed 42 for the primary model; app splits use seeds 42-46.
- Server: `go test ./...` then `CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build`; environment variables `NOXOS_MANIFEST_URL`, `NOXOS_FILE_MANIFEST_URL`, `NOXOS_INFERENCE_API_KEY`.
- XGBoost training was bit-reproducible across local and CI runs (identical model hash); the neural autoencoder was not (F1 0.805 local vs 0.856 CI for the same code and seed, different hardware).

## 7. References

1. N. Moustafa and J. Slay, "UNSW-NB15: a comprehensive data set for network intrusion detection systems (UNSW-NB15 network data set)," in *Military Communications and Information Systems Conference (MilCIS)*, 2015.
2. G. Aceto, D. Ciuonzo, A. Montieri, V. Persico and A. Pescapè, "MIRAGE: Mobile-app Traffic Capture and Ground-truth Creation," in *4th IEEE International Conference on Computing, Communications and Security (ICCCS)*, 2019. Dataset licence CC BY-NC-ND 4.0.
3. D. Arp, M. Spreitzenbarth, M. Hübner, H. Gascon and K. Rieck, "Drebin: Effective and Explainable Detection of Android Malware in Your Pocket," in *Network and Distributed System Security Symposium (NDSS)*, 2014.
4. S. M. Lundberg and S.-I. Lee, "A Unified Approach to Interpreting Model Predictions," in *Advances in Neural Information Processing Systems (NeurIPS)*, 2017.
5. S. M. Lundberg, G. G. Erion and S.-I. Lee, "Consistent Individualized Feature Attribution for Tree Ensembles," arXiv:1802.03888, 2018.
6. T. Chen and C. Guestrin, "XGBoost: A Scalable Tree Boosting System," in *ACM SIGKDD*, 2016.
7. F. Pedregosa et al., "Scikit-learn: Machine Learning in Python," *Journal of Machine Learning Research* 12, 2011 (`StratifiedGroupKFold`).
8. G. Hinton, O. Vinyals and J. Dean, "Distilling the Knowledge in a Neural Network," arXiv:1503.02531, 2015.

Not used in the final results: CIC-AndMal2017 (download gated behind a personal-information form, skipped), UTMobileNetTraffic2021 (loader written, never evaluated).
