# app/src/main/AndroidManifest.xml

## `android.permission.MANAGE_VIRTUAL_MACHINE`

Required by AVF to launch/manage VMs. Status as of session 18: this is a signature-level
permission — declaring it in the manifest does not actually grant it to a regular
`adb install`-ed APK. Confirmed live on a real Cuttlefish device: every VM attempt fails
with `SecurityException: Virtmgr didn't send any data through pipe... check
android.permission.MANAGE_VIRTUAL_MACHINE permission is granted`, even though this line
is present and the device has real AVF/Microdroid support. Only a priv-app/platform-signed
install would actually receive the grant — tracked in `knowledge-graph/noxos-os/TASKS.md`
Phase 1c, not fixable from this repo. See `knowledge-graph/noxos-app/TASKS.md` session 18
and `knowledge-graph/discussions.md` item 10 for the full testing writeup.
