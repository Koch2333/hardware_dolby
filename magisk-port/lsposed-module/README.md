# Dolby Passthrough Unlocker (LSPosed module)

Companion to the Dolby Codec Magisk module. Makes target apps believe the device
supports Dolby (E-AC3 / E-AC3-JOC / AC4) **direct playback** and **surround
output**, so they request Dolby audio tracks instead of falling back to AAC.

It does **not** create or register any codec — that is the Magisk module's job.
This only unlocks the app-side *request* path. See the parent
[`../README.md`](../README.md) §7.

## Build

Requires Android Studio / the Android SDK and a JDK 17.

```bash
cd magisk-port/lsposed-module
./gradlew assembleRelease         # or: gradle assembleRelease
# APK -> app/build/outputs/apk/release/  (unsigned; sign it or use debug build)
```

There is no Gradle wrapper jar committed (binaries are kept out of the repo). Use
a locally installed Gradle, or run `gradle wrapper` once to generate one.

### Xposed API dependency
`build.gradle.kts` uses `compileOnly("de.robv.android.xposed:api:82")` from the
`https://api.xposed.info/` maven repo (declared in `settings.gradle.kts`). If that
repo can't be reached, vendor the api jar instead:

1. download `api-82.jar` (Xposed Bridge API v82),
2. drop it in `libs/`,
3. replace the dependency with `compileOnly(files("libs/api-82.jar"))`.

The API is `compileOnly` on purpose — the LSPosed framework provides it at runtime.

## Install & use

1. Install the APK.
2. Open the **LSPosed manager** → enable **Dolby Passthrough Unlocker**.
3. Set its **scope** to the streaming/player apps you use (defaults suggested in
   `res/values/arrays.xml`).
4. Force-stop and reopen those apps.
5. Watch `adb logcat | grep DolbyPassthrough` to confirm the hooks fire.

## Tuning
Different apps gate Dolby differently. If an app still won't request a Dolby track
after this, it's using a private capability check — you'll need to identify and
hook that app's specific method. `AudioCapabilityHook.kt` is structured to make
adding another hook straightforward.
