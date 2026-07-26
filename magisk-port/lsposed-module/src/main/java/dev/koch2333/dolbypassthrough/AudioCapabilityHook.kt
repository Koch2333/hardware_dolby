/*
 * Dolby Passthrough Unlocker — LSPosed companion to the Dolby Codec Magisk module.
 *
 * Scope of what this can and cannot do:
 *   - It CANNOT create a codec. Whether c2.dolby.eac3.decoder exists is decided in
 *     native audioserver/media processes, which have no ART runtime and cannot be
 *     hooked by LSPosed. That is the Magisk module's job.
 *   - It CAN make an app *believe* the device supports Dolby direct playback /
 *     surround output, so the app requests an E-AC3 / E-AC3-JOC / AC4 track (or
 *     enables a Dolby/Atmos toggle) instead of falling back to AAC. Once the app
 *     asks for a Dolby track, the Magisk-provided decoder actually plays it.
 *
 * The two capability queries most apps use, both hooked here:
 *   AudioTrack.isDirectPlaybackSupported(AudioFormat, AudioAttributes)   [API 29+]
 *   AudioManager.getReportedSurroundFormats() / getSurroundFormats()     [hidden]
 */
package dev.koch2333.dolbypassthrough

import android.media.AudioFormat
import de.robv.android.xposed.XC_MethodHook
import de.robv.android.xposed.XposedBridge
import de.robv.android.xposed.XposedHelpers
import de.robv.android.xposed.callbacks.XC_LoadPackage.LoadPackageParam
import de.robv.android.xposed.IXposedHookLoadPackage

class AudioCapabilityHook : IXposedHookLoadPackage {

    // Dolby-family AudioFormat encodings we want to advertise as supported.
    // Values are stable platform constants; some are @hide so we hardcode them
    // rather than referencing the (possibly missing) named field.
    private val dolbyEncodings = intArrayOf(
        AudioFormat.ENCODING_AC3,        // 5
        AudioFormat.ENCODING_E_AC3,      // 6
        17,                              // ENCODING_AC4        (@hide on some APIs)
        18,                              // ENCODING_E_AC3_JOC
        14,                              // ENCODING_DOLBY_TRUEHD
        30                               // ENCODING_DOLBY_MAT  (varies by API; harmless if unused)
    )

    override fun handleLoadPackage(lpparam: LoadPackageParam) {
        hookDirectPlayback(lpparam)
        hookSurroundFormats(lpparam)
    }

    private fun log(m: String) = XposedBridge.log("[DolbyPassthrough] $m")

    /**
     * AudioTrack.isDirectPlaybackSupported(AudioFormat, AudioAttributes): boolean (static).
     * Force-true for Dolby encodings; leave everything else to the platform.
     */
    private fun hookDirectPlayback(lpparam: LoadPackageParam) {
        try {
            XposedHelpers.findAndHookMethod(
                "android.media.AudioTrack",
                lpparam.classLoader,
                "isDirectPlaybackSupported",
                AudioFormat::class.java,
                "android.media.AudioAttributes",
                object : XC_MethodHook() {
                    override fun afterHookedMethod(param: MethodHookParam) {
                        val fmt = param.args[0] as? AudioFormat ?: return
                        if (dolbyEncodings.contains(fmt.encoding)) {
                            if (param.result != true) {
                                log("isDirectPlaybackSupported: forcing true for encoding=${fmt.encoding} in ${lpparam.packageName}")
                            }
                            param.result = true
                        }
                    }
                }
            )
        } catch (t: Throwable) {
            log("hookDirectPlayback failed (API too old / method absent): ${t.message}")
        }
    }

    /**
     * AudioManager.getReportedSurroundFormats() -> List<Integer>   (hidden)
     * AudioManager.getSurroundFormats()          -> Map<Integer,Boolean> (hidden)
     * Inject the Dolby encodings so apps that gate on "surround formats the sink
     * reports" see them.
     */
    private fun hookSurroundFormats(lpparam: LoadPackageParam) {
        val amClass = try {
            XposedHelpers.findClass("android.media.AudioManager", lpparam.classLoader)
        } catch (t: Throwable) {
            log("AudioManager not found: ${t.message}"); return
        }

        // List<Integer> variant
        runCatching {
            XposedBridge.hookAllMethods(amClass, "getReportedSurroundFormats", object : XC_MethodHook() {
                @Suppress("UNCHECKED_CAST")
                override fun afterHookedMethod(param: MethodHookParam) {
                    val res = param.result as? MutableList<Int> ?: return
                    var changed = false
                    for (e in dolbyEncodings) if (!res.contains(e)) { res.add(e); changed = true }
                    if (changed) log("getReportedSurroundFormats: added Dolby encodings for ${lpparam.packageName}")
                }
            })
        }.onFailure { log("hook getReportedSurroundFormats skipped: ${it.message}") }

        // Map<Integer,Boolean> variant
        runCatching {
            XposedBridge.hookAllMethods(amClass, "getSurroundFormats", object : XC_MethodHook() {
                @Suppress("UNCHECKED_CAST")
                override fun afterHookedMethod(param: MethodHookParam) {
                    val res = param.result as? MutableMap<Int, Boolean> ?: return
                    var changed = false
                    for (e in dolbyEncodings) if (res[e] != true) { res[e] = true; changed = true }
                    if (changed) log("getSurroundFormats: enabled Dolby encodings for ${lpparam.packageName}")
                }
            })
        }.onFailure { log("hook getSurroundFormats skipped: ${it.message}") }
    }
}
