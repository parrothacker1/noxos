# app/src/main/java/com/noxos/app/MainActivity.kt

## `netMonitorActive` property

Class-level, not `remember`-ed inside setContent: the VPN permission launcher's callback
(below) fires outside the Composable scope on first grant, and needs to flip this same
state - a local `remember` var there would be write-only from here, leaving the UI
permanently showing "inactive" even once the service is really running.
