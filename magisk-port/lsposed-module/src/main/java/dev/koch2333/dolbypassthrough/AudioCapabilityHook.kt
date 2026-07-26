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
 * Capability queries apps use to decide whether to request a Dolby track, all
 * hooked here (each hook degrades to a logged no-op where the method is absent):
 *   AudioTrack.isDirectPlaybackSupported(AudioFormat, AudioAttributes)  [API 29+]
 *   AudioTrack.getDirectPlaybackSupport(AudioFormat, AudioAttributes)   [API 34+]
 *   AudioManager.getReportedSurroundFormats() / getSurroundFormats()    [hidden]
 *   AudioManager.isSurroundFormatEnabled(int)                           [API 28+]
 *   AudioManager.getDirectProfilesForAttributes(AudioAttributes)        [API 33+]
 *
 * The last one matters most on the target Android 13: modern ExoPlayer / Media3
 * (the playback engine behind most streaming apps) reads getDirectProfilesForAttributes
 * on API 33+ to pick passthrough encodings. Without it, isDirectPlaybackSupported
 * alone is not enough to push those apps onto a Dolby track.
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

    // AudioTrack.getDirectPlaybackSupport() return value meaning "direct bitstream
    // passthrough is supported". Hardcoded because the named constant is API 34.
    private val DIRECT_PLAYBACK_BITSTREAM_SUPPORTED = 0x4

    // Output channel masks advertised in the synthesized AudioProfiles.
    private val CH_OUT_5POINT1 = 0xFC            // AudioFormat.CHANNEL_OUT_5POINT1
    private val CH_OUT_7POINT1 = 0x18FC          // AudioFormat.CHANNEL_OUT_7POINT1_SURROUND

    override fun handleLoadPackage(lpparam: LoadPackageParam) {
        hookAudioTrackCapabilities(lpparam)
        hookSurroundFormats(lpparam)
        hookSurroundFormatEnabled(lpparam)
        hookDirectProfiles(lpparam)
    }

    private fun log(m: String) = XposedBridge.log("[DolbyPassthrough] $m")

    private fun isDolby(enc: Int) = dolbyEncodings.contains(enc)

    private fun firstAudioFormat(args: Array<Any?>): AudioFormat? =
        args.firstOrNull { it is AudioFormat } as? AudioFormat

    /**
     * Both AudioTrack direct-playback capability queries (static methods). Hooked
     * via hookAllMethods so signature variants across API levels all get caught;
     * the AudioFormat argument is located positionally.
     *   isDirectPlaybackSupported(...) : boolean  -> force true for Dolby        [API 29+]
     *   getDirectPlaybackSupport(...)  : int      -> force BITSTREAM for Dolby   [API 34+]
     */
    private fun hookAudioTrackCapabilities(lpparam: LoadPackageParam) {
        val at = try {
            XposedHelpers.findClass("android.media.AudioTrack", lpparam.classLoader)
        } catch (t: Throwable) {
            log("AudioTrack not found: ${t.message}"); return
        }

        runCatching {
            XposedBridge.hookAllMethods(at, "isDirectPlaybackSupported", object : XC_MethodHook() {
                override fun afterHookedMethod(param: MethodHookParam) {
                    val fmt = firstAudioFormat(param.args) ?: return
                    if (isDolby(fmt.encoding) && param.result != true) {
                        param.result = true
                        log("isDirectPlaybackSupported -> true (enc=${fmt.encoding}) ${lpparam.packageName}")
                    }
                }
            })
        }.onFailure { log("isDirectPlaybackSupported hook skipped: ${it.message}") }

        runCatching {
            XposedBridge.hookAllMethods(at, "getDirectPlaybackSupport", object : XC_MethodHook() {
                override fun afterHookedMethod(param: MethodHookParam) {
                    val fmt = firstAudioFormat(param.args) ?: return
                    val cur = param.result as? Int ?: return
                    if (isDolby(fmt.encoding) && cur == 0) {
                        param.result = DIRECT_PLAYBACK_BITSTREAM_SUPPORTED
                        log("getDirectPlaybackSupport -> BITSTREAM (enc=${fmt.encoding}) ${lpparam.packageName}")
                    }
                }
            })
        }.onFailure { log("getDirectPlaybackSupport hook skipped: ${it.message}") }
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

    /**
     * AudioManager.isSurroundFormatEnabled(int encoding) -> boolean   [API 28+]
     * Some apps probe each encoding individually instead of reading the whole map.
     */
    private fun hookSurroundFormatEnabled(lpparam: LoadPackageParam) {
        val amClass = try {
            XposedHelpers.findClass("android.media.AudioManager", lpparam.classLoader)
        } catch (t: Throwable) {
            return
        }
        runCatching {
            XposedBridge.hookAllMethods(amClass, "isSurroundFormatEnabled", object : XC_MethodHook() {
                override fun afterHookedMethod(param: MethodHookParam) {
                    val enc = param.args.firstOrNull() as? Int ?: return
                    if (isDolby(enc) && param.result != true) {
                        param.result = true
                        log("isSurroundFormatEnabled(enc=$enc) -> true ${lpparam.packageName}")
                    }
                }
            })
        }.onFailure { log("hook isSurroundFormatEnabled skipped: ${it.message}") }
    }

    /**
     * AudioManager.getDirectProfilesForAttributes(AudioAttributes) -> List<AudioProfile>  [API 33+]
     *
     * Modern ExoPlayer / Media3 (the engine behind most streaming apps) reads THIS on
     * Android 13+ to decide which passthrough encodings the output can take. If a Dolby
     * encoding has no profile in the returned list, ExoPlayer won't offer that track —
     * hooking isDirectPlaybackSupported alone is not enough. We append a synthesized
     * AudioProfile per Dolby encoding.
     *
     * AudioProfile's constructor is @hide, so we build it reflectively. Signature (API 33):
     *   AudioProfile(int format, int[] samplingRates, int[] channelMasks,
     *                int[] channelIndexMasks, int encapsulationType)
     */
    private fun hookDirectProfiles(lpparam: LoadPackageParam) {
        val amClass = try {
            XposedHelpers.findClass("android.media.AudioManager", lpparam.classLoader)
        } catch (t: Throwable) {
            return
        }

        val profileCtor = runCatching {
            XposedHelpers.findConstructorExact(
                "android.media.AudioProfile", lpparam.classLoader,
                Int::class.javaPrimitiveType,
                IntArray::class.java,
                IntArray::class.java,
                IntArray::class.java,
                Int::class.javaPrimitiveType
            )
        }.getOrNull()
        if (profileCtor == null) {
            log("AudioProfile ctor not found; getDirectProfilesForAttributes hook disabled")
            return
        }

        runCatching {
            XposedBridge.hookAllMethods(amClass, "getDirectProfilesForAttributes", object : XC_MethodHook() {
                @Suppress("UNCHECKED_CAST")
                override fun afterHookedMethod(param: MethodHookParam) {
                    val res = param.result as? MutableList<Any> ?: return
                    val present = res.mapNotNull {
                        runCatching { XposedHelpers.callMethod(it, "getFormat") as? Int }.getOrNull()
                    }.toHashSet()
                    var changed = false
                    for (enc in dolbyEncodings) {
                        if (present.contains(enc)) continue
                        val profile = runCatching {
                            profileCtor.newInstance(
                                enc,
                                intArrayOf(48000, 44100),
                                intArrayOf(CH_OUT_5POINT1, CH_OUT_7POINT1),
                                IntArray(0),
                                0                    // AUDIO_ENCAPSULATION_TYPE_NONE
                            )
                        }.getOrNull() ?: continue
                        res.add(profile); changed = true
                    }
                    if (changed) log("getDirectProfilesForAttributes: added Dolby profiles for ${lpparam.packageName}")
                }
            })
        }.onFailure { log("hook getDirectProfilesForAttributes skipped: ${it.message}") }
    }
}
