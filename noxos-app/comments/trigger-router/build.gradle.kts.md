# trigger-router/build.gradle.kts

## `avfStubJar` / `fetchAvfSystemStub`

`android.system.virtualmachine.*` (`VirtualMachine`/`VirtualMachineManager`/`VirtualMachineConfig`) are
`@SystemApi` — absent from the public compileSdk jar. Google's own reference app builds against
them via Soong's `sdk_version "system_current"`, which resolves to `prebuilts/sdk/<api>/system/android.jar`
inside an AOSP tree. This is a plain Gradle project with no AOSP checkout, so it fetches that same jar
from AOSP's public git mirror instead. Verified present: `android/system/virtualmachine/*.class`.
