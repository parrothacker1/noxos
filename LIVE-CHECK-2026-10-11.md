# Live inference check, 2026-10-11

Setup: teacher-server (cb50ad0, adds NOXOS_BIND_ADDRESS) running on the laptop, bound to the Docker bridge address 172.17.0.1:8080 only. Serves teacher v1791623224 and file v1790706350 (the student runs on-device only). Token in a chmod 600 file on the host, never in chat or commits. This is a localhost verification, not a cloud deployment: the EC2 box is stopped and was verified earlier only on an older binary. Details: noxos-inference/SERVER-DEPLOY.md.

Reachability: from the Android guest (192.168.97.2) the path guest -> 192.168.97.1 -> container -> 172.17.0.1 works; 10.0.2.2 does not. `GET /health` returned 200.

Results from Warden v3.3.0 on Cuttlefish (reported by Warden, 2026-10-11):
- `/analyze/file` from the app: 200 in 3.83 ms, advisory text shown ("advisory only (permission-based model trained on 2012-era apps, do not use this to block) ..."); scan outcome stayed "Scan completed, no issues found", nothing quarantined.
- `/analyze/network` from the app: 3 autoencoder-flagged flows (a 30 MB TCP upload and two 2 MB UDP bursts) escalated; server answered 200 in 9-13 ms each; all three were set ALLOWED with safety 1.0 and the identical reasoning sentence built from model-default values.

Finding (defect, open): the app's `/analyze/network` request body carries only ip, priority, reason, first_flagged_epoch_millis, proto and dst_port. It sends none of the flow statistics it holds (packet/byte counts, duration, handshake latency). The server scored the missing features as defaults and answered "allow". Live cloud-teacher verdicts are therefore non-informative on v3.3.0. Fixes in progress: server rejects feature-less requests (noxos-inference), client sends the flow statistics (noxos-app, planned v3.3.1). Until both are verified on a device, the cloud-teacher escalation is "designed and unit-verified, end-to-end not working".
