# audit/src/main/java/com/noxos/audit/AclRepository.kt

## `AclRepository.nextAnalysisBatch`

Up to [limit] flagged network entries that already cleared the pVM cheap filter, highest priority and oldest first.

## `AclRepository.nextCheapFilterBatch`

Up to [limit] flagged network entries still awaiting the pVM cheap filter, oldest first.

## `AclRepository.markCheapFilterFlagged`

Records that the pVM cheap filter itself flagged this destination - stays FLAGGED, but is now eligible for `nextAnalysisBatch`.

## `AclRepository.seedDefaults`

Seeds well-known-safe network hosts. Never overwrites an existing entry (user or AI set).

## `AclRepository.clearSessionVerdicts`

Forgets AI-sourced verdicts of [kind] (sessionOnly = true) - a fresh session re-asks. Never touches user/seed entries.

## `RoomAclRepository.nextCheapFilterBatch` (staleness cutoff)

A destination whose sample was lost (process restart, or a prior VM attempt that came
back Unknown) never gets cheapFilterChecked set and never gets a fresh sample either -
it would otherwise sit at the front of this oldest-first query forever, permanently
filling every batch once enough of them accumulate. Excluding anything past a staleness
window gives up on it for good (matches the accepted "explicitly accept the loss"
stance) instead of it silently starving every destination flagged after it.
