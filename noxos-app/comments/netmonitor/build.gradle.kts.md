# netmonitor/build.gradle.kts

## `testImplementation(libs.junit)`

Unit tests here use plain JUnit only, no Robolectric: `PacketUtils` is plain Kotlin with
no Android deps, so it doesn't need it.
