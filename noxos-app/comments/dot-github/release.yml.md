# .github/workflows/release.yml

## `Build release APK` step

ponytail: no signing config exists yet (this app ships signed inside
the OS image eventually, not as a standalone Play-style release) —
release APKs here are unsigned until that infra exists.

(Note: as of session 15, `app/build.gradle.kts`'s `release` build type actually does set
`signingConfig = signingConfigs.getByName("debug")` — so release APKs ARE debug-signed,
not unsigned. This comment predates that change and is stale; kept here for history, not
because it's still accurate. See `knowledge-graph/noxos-app/comments/app/build.gradle.kts.md`
for the real current signing note.)
