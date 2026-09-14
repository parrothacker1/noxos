# gradle/libs.versions.toml

## `composeBom` version pin

Pinned to the newest BOM whose `androidx.compose.ui:ui` is still 1.7.x.
Anything newer (e.g. 2026.08.00 -> ui 1.12.0) requires AGP 9.1.0+ /
compileSdk 37 and will fail the build under this project's AGP 8.7.3 /
compileSdk 35 pin. Bump agp+compileSdk together with this if you need to.
