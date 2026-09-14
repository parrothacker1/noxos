# audit/src/test/java/com/noxos/audit/RoomAclRepositoryTest.kt

## `testNextCheapFilterBatchExcludesAStrandedEntryPastTheStalenessWindow`

Simulates a destination whose sample was lost (process restart, or a prior VM attempt
that came back Unknown) - it never gets cheapFilterChecked, so without a staleness
cutoff it would sit at the front of this oldest-first query forever.

## `testStrandedEntriesDoNotStarveFreshOnesOutOfTheBatch`

The actual regression: once enough stranded entries accumulate, oldest-first with no
cutoff means they permanently fill every batch and no new destination ever gets
cheap-filter-checked again.
