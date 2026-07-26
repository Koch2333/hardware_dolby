# Dolby Codec Port — Magisk + LSPosed

Port the **Dolby Codec2 decoders** (AC3 / E-AC3 / E-AC3-JOC, and optionally AC4)
from this `hardware/dolby` tree onto a **stock, already-built Android ROM**,
without recompiling the ROM.

> **Scope: decoders only.** No DAP/DAX audio post-processing (the "Atmos"
> virtualizer / EQ) is installed. That path requires editing
> `/vendor/etc/audio_effects.xml` and is the #1 way to send `audioserver` into a
> crash-loop; it is deliberately out of scope here.

> **"编码" clarification.** This repo ships **decoders**, not encoders. There is
> no Dolby *encoding* in these blobs. "让系统能用上编码" is delivered here as
> "let the system **decode/play** Dolby audio formats."

---

## 1. Which layer does what

The single most important fact: **LSPosed cannot make a codec exist.** Codec
availability is decided by native processes (`media.swcodec`, the vendor codec2
service, `hwservicemanager`) that have **no ART runtime**, so Xposed-style Java
hooks structurally cannot reach them. Everything that *creates the capability* is
the Magisk module's job. LSPosed only helps apps *ask* for it.

| Piece | Delivered by | Why |
|---|---|---|
| `libcodec2_soft_ddpdec` / `ac4dec` / `dolby` / `store_dolby`, `libdeccfg`, `libdapparamstorage` | **Magisk** → `/vendor/lib64` | the actual decoders |
| `vendor.dolby.media.c2@1.0-service` | **Magisk** → `/vendor/bin/hw` | the codec2 IComponentStore (`default1`) that exposes them |
| `vendor.dolby.hardware.dms@2.0-*` + `libdlbdsservice` | **Magisk** | **decoders link `vendor.dolby.hardware.dms@2.0.so`** — the DMS HAL must run or the decoders fail to load |
| `media_codecs_dolby_audio.xml` (merged into primary) | **Magisk** | maps mime → component, adds OMX aliases + limits |
| VINTF manifest fragments | **Magisk** → `/vendor/etc/vintf/manifest` | declares the c2 + DMS HALs so hwservicemanager allows registration |
| SELinux types/rules for DMS | **Magisk** `sepolicy.rule` (magiskpolicy) | `hal_dms_*` types don't exist on a stock policy |
| `hwservice_contexts` entry for `IDms` | **Magisk (direct mode only)** | magiskpolicy **cannot** edit this file; it's read too early |
| init `.rc` for the two daemons | **Magisk (direct mode only)** | init parses `.rc` before Magisk mounts anything |
| Apps requesting Dolby tracks | **LSPosed** (optional) | make apps believe Dolby direct-playback/surround is supported |

---

## 2. Why `direct` install mode exists (read this)

Boot order:

```
init 2nd stage → parse /vendor/etc/init/*.rc → hwservicemanager (reads hwservice_contexts)
      → post-fs-data  ← Magisk magic-mounts modules HERE ← too late for the two lines above
      → class_start hal/core → audioserver, media services
```

So the blobs, the merged `media_codecs`, the VINTF fragments and props all arrive
in time under a normal magic-mount **overlay**. But the DMS **init service
definition** and its **hwservice_contexts label** are read *before* Magisk mounts
anything. Two consequences:

- **`direct` mode (recommended):** the installer remounts `/vendor` read-write and
  writes everything — including the `.rc` and the `hwservice_contexts` line —
  straight into the partition. On next boot init launches the daemons normally and
  hwservicemanager knows the `IDms` label. **Requires dm-verity / AVB disabled**
  (unlocked bootloader + patched `vbmeta`), otherwise the remount fails or the
  device won't boot.
- **`overlay` mode (best-effort):** classic magic-mount; `service.sh` hand-launches
  the daemons with `runcon` after boot. Domain transition and hwservice labelling
  are approximate. Expect flakiness. Use only if you can't disable verity.

---

## 3. Hard preconditions (from binary analysis)

Verified with `readelf`/`file` on the blobs in this repo:

- **Android 13 / API 33.** `libcodec2_soft_dolby.so` needs `libstagefright_foundation-v33.so`; the c2 service needs `libcodec2_hidl@1.2` + `android.hardware.media.c2@1.2`. A different API level will almost certainly mismatch these ABIs.
- **arm64-v8a only.** Every blob is `ARM aarch64`; there are **no 32-bit variants**. A 32-bit media process cannot use these.
- **HIDL-based.** These are HIDL HALs (not AIDL). A ROM that dropped HIDL support for media.c2 won't register them.
- **Host `/vendor` must already contain** (or you must add) these libs, which are *not* Dolby-specific but are version-pinned and may be missing:
  `libstagefright_foundation-v33.so`, `libcodec2_soft_common.so`,
  `libsfplugin_ccodec_utils.so`, `libavservices_minijail.so`,
  `libcodec2_hidl@1.2.so`, `android.hardware.media.c2@1.2.so`, `libcodec2_vndk.so`.
  `customize.sh` checks for these and warns. See **Missing deps** below.
- Best results on an **AOSP-based A13 ROM for the same SoC family**. A vendor from a
  very different OEM raises the odds of a VNDK/symbol mismatch.

### Missing deps
If `customize.sh` reports missing libs, the decoders won't load until you supply
matching-version copies. Pull them from an A13 device/ROM that has them and drop
them into `magisk-module` staging under `system/vendor/lib64/` before building, or
into `/vendor/lib64` directly in direct mode. Do **not** mix libs from a different
Android version.

---

## 4. Build & install

```bash
# 1) Build the flashable zip from the blobs in this repo
./magisk-port/build-module.sh
#   -> magisk-port/out/dolby_codec_port.zip

# 2) Flash in the Magisk app (Modules → Install from storage).
#    During flash pick a mode with the volume keys:
#      Vol UP   = direct  (needs verity off)   ← recommended
#      Vol DOWN = overlay (best-effort)

# 3) Reboot.
```

### Enabling AC4 (optional)
`configs/media/media_codecs_dolby_audio.xml` declares only AC3/E-AC3/E-AC3-JOC.
The `libcodec2_soft_ac4dec.so` blob provides `c2.dolby.ac4.decoder`, but it is not
exposed until you add an AC4 `<MediaCodec>` block, e.g.:

```xml
<MediaCodec name="c2.dolby.ac4.decoder">
    <Type name="audio/ac4">
        <Limit name="channel-count" max="24" />
        <Limit name="sample-rate" ranges="44100,48000" />
    </Type>
    <Attribute name="software-codec" />
</MediaCodec>
```

Add it inside `<Decoders>...</Decoders>` in `media_codecs_dolby_audio.xml`, then
rebuild.

---

## 5. Verify it worked

After reboot:

```bash
# decoders present in the framework's codec list?
adb shell dumpsys media.codec  | grep -i dolby
adb shell cmd media_codec ...              # (if available on your build)

# the vendor c2 store registered?
adb shell lshal | grep -i 'media.c2'       # expect ...IComponentStore/default1

# the DMS HAL running & registered?
adb shell lshal | grep -i dolby            # expect vendor.dolby.hardware.dms@2.0::IDms/default
adb shell getprop | grep -i 'init.svc.*dolby'

# our install log
adb shell cat /data/local/tmp/dolby_codec_port.log

# real playback test: play an .ec3 / E-AC3-JOC file and check the chosen codec
adb logcat | grep -iE 'c2.dolby|CCodec|eac3'
```

If `dumpsys media.codec` lists `c2.dolby.eac3.decoder`, the port succeeded.

---

## 6. Top failure modes

| Symptom | Cause | Fix |
|---|---|---|
| c2 service not in `lshal`, logcat `dlopen ... library "libstagefright_foundation-v33.so" not found` | host `/vendor` missing a pinned dep | supply the missing lib (see Missing deps) |
| `IDms` not registered / `avc: denied ... hal_dms_hwservice` | overlay mode, or hwservice_contexts line missing | use direct mode; confirm the line is in `/vendor/etc/selinux/vendor_hwservice_contexts` |
| decoders load but instantiation fails at runtime | DMS HAL not running (decoders depend on it) | check `lshal`/`init.svc`; DMS must be up first |
| bootloop after flashing in direct mode | verity/AVB still enforcing, or a bad `/vendor` write | patch `vbmeta` (disable verity+verification) or restore stock vendor |
| decoders present but streaming app still uses AAC | app never *requested* Dolby | install the LSPosed companion (§7) and add the app to its scope |

---

## 7. LSPosed companion (optional)

Directory: [`lsposed-module/`](lsposed-module/). Build it as a normal Android app
(`./gradlew assembleRelease`), install the APK, enable it in the LSPosed manager,
and set its scope to the streaming/player apps you use.

What it does: hooks `AudioTrack.isDirectPlaybackSupported(...)` and
`AudioManager.getReportedSurroundFormats()/getSurroundFormats()` inside the target
app so the app believes the device supports Dolby direct playback / surround
output — pushing it to request an E-AC3-JOC/AC4 track instead of AAC. The
Magisk-provided decoder then actually decodes it.

What it does **not** do: it does not create, register, or enable any codec. If the
Magisk half isn't working, the app will request a Dolby track and playback will
fail — LSPosed only unlocks the *request*, never the *capability*.

> The original `LunarisDolby` app is **not** usable here: it declares
> `sharedUserId="android.uid.system"` and is `certificate: "platform"`, so a
> sideloaded APK gets `INSTALL_FAILED_SHARED_USER_INCOMPATIBLE`. It's the control
> UI for the *effect* path anyway, which this codec-only port doesn't install.

---

## 8. Honest success odds

| Approach | Odds | Notes |
|---|---|---|
| Pure LSPosed, no Magisk | **0%** | can't create a codec |
| Magisk `overlay` mode | ~10–20% | init.rc + hwservice_contexts read too early; DMS registration unreliable |
| Magisk `direct` mode, matching A13/arm64 host, verity off | **30–55%** | main risk is missing pinned deps + VNDK/SoC mismatch |
| Same, but host `/vendor` is from a different OEM/SoC or wrong Android version | low | symbol/ABI mismatches |
| Build into the ROM from source (what this repo is designed for) | 90%+ | the supported path |

If your goal is just "play E-AC3/Atmos tracks," direct mode on a matching A13
arm64 host is the realistic route. If the host isn't A13/arm64, there is no
shortcut — build the ROM.
