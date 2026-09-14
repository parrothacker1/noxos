# trigger-router/src/main/java/com/noxos/triggerrouter/QuarantineManager.kt

## `QuarantineManager` (class)

Physically moves a file the EXIF parser flagged as malformed out of MediaStore.Downloads and
into app-private storage, so it's no longer accessible to the user (or any other app) until
force-allowed back. Only ever called for auto-scanned files (see FileArrivalWatcher) - a
manually SAF-picked file isn't ours to move.

## `restore`

Force-allow: restores a held file back into Downloads and forgets it was ever quarantined.

## `recentlyRestoredIds`

MediaStore row IDs `restore` just wrote back into Downloads, checked (and consumed) by
`FileArrivalWatcher` so a force-allowed file doesn't get immediately re-detected as a
"new arrival" and quarantined again right after the user explicitly restored it.
