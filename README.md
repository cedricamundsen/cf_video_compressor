# cf_video_compressor — CombatFlux Phase B0 (Android POC)

Isolated feasibility test for on-device video compression. It is **not** connected to
the CombatFlux FlutterFlow app, Cloudinary, Firebase or the Cloud Function, and it uploads nothing.

- Android: Media3 Transformer 1.11.1 with the hardware H.264 encoder and AAC audio.
- No FFmpeg and no third-party compression package.
- iOS (0.2.0, branch `ios-avfoundation`): AVFoundation - AVAssetReader with a video composition
  (upright output, 720p/540p scale, <= 30 fps, HDR -> SDR BT.709) and AVAssetWriter (H.264 High +
  AAC, MP4 with the index at the front). Same channels, methods and error codes as Android.
  Picker: PHPickerViewController (no photo-library permission; original file copied to
  `<tmp>/cf_picked` on disk). Privacy manifest: disk-space API, reason E174.1.
  `AnalysisVideoPreparer(requireMp4H264: true)` makes iOS convert small HEVC/.MOV sources
  to H.264 MP4 (default false: Android unchanged).
  **Not yet compiled or device-tested** - first build needs a Mac with Xcode.

## Production use (CombatFlux B1)

The CombatFlux app pulls this package as a Git dependency pinned to a commit
SHA. Its FlutterFlow custom actions use:

- `CfVideoCompressor.pickVideo()` and `getVideoInfo()` for picking and metadata.
- `AnalysisVideoPreparer` for the full flow: decide whether to compress, check
  free space, then either stream-copy a source that is already ≤ 95 MiB or
  compress with one 85 % retry, and verify the size. It returns a temp file of
  ≤ 95 MiB, which the app hands to its existing uploader. Afterwards it cleans
  up the temp files.

Error kinds (`PrepareFailure`):

- `tooLong`
- `unsupportedInput`
- `sourceUnreadable`
- `insufficientStorage`
- `compressionFailed`
- `stillTooLarge`
- `cancelled`

## Layout

| Path | What |
|---|---|
| `lib/src/planner.dart` | Pure-Dart rules: duration → bitrate → 720p/540p/reject; 85 % retry plan |
| `lib/src/compressor.dart` | `CfVideoCompressor`: attempt 1 → (if > 95 MiB) one retry → report |
| `lib/src/platform.dart` | Platform contract + MethodChannel/EventChannel implementation |
| `lib/src/preparer.dart` | Production orchestrator used by the CombatFlux app |
| `lib/src/models.dart` | `VideoInfo`, `CompressionPlan`, `CompressionAttempt`, `CompressionReport` |
| `android/.../CompressionJob.kt` | One Media3 Transformer export, progress poll, cancel |
| `android/.../VideoProbe.kt` | Size/duration/dimensions/rotation/fps/codecs without loading the file |
| `android/.../OutputStore.kt` | Temp outputs `<externalCache>/cf_compress/cf_<ms>_a<n>.mp4` |
| `example/` | Test app: pick → info → plan → compress (live %) → cancel → report → play |
| `test/` | 43 unit tests (planner, retry orchestration, production preparer; fake platform) |

## One-time setup (build machine)

1. Install **Android Studio** (it bundles the JDK and SDK). In the SDK Manager, install:
   - SDK Platform 36
   - Build-Tools
   - Platform-Tools
2. Accept the Android SDK licences:

   ```
   flutter doctor --android-licenses
   ```

3. `flutter doctor` must show a ✓ on the "Android toolchain" line.
4. On the phone, turn on Developer options → USB debugging, then connect it by USB.
   `flutter devices` must list the phone.

## Run

```
cd poc/cf_video_compressor/example
flutter run --release
```

Or build an APK and install it by hand:

```
flutter build apk --release
```

The APK is written to `build/app/outputs/flutter-apk/app-release.apk`.

## Test with real BJJ videos

Use videos straight from the phone camera. Suggested set:

| # | Clip | Expect |
|---|---|---|
| A | about 5 min, 1080p/30, landscape | 720p, about 2.4 Mbps, about 88–90 MiB |
| B | about 10 min, 4K or 1080p at 60 fps | 720p, about 1.2 Mbps, 30 fps |
| C | any length, **portrait** | Portrait output, not rotated or stretched |
| D | about 12–15 min | 540p, about 0.77–0.97 Mbps |
| E | HDR clip (Pixel "10-bit HDR", Samsung "HDR10+") | SDR output with normal colours |
| F | 2 min | Capped at 3 Mbps, about 44 MiB |
| G | over 19 min | Plan shows `belowFloor`; "Test anyway" is optional |

For each clip:

1. **Pick a video.** Check that the Source card shows the correct size, duration, resolution, fps and codecs.
2. **Compress.** The bar must move with a real percentage. Note the time.
3. **Result card.** Check:
   - output size and "Below 95 MiB = YES"
   - output resolution
   - output duration equals the source duration
   - requested vs. resulting bitrate
4. **Play output.** Check:
   - orientation and aspect ratio
   - audio present and in sync
   - normal speed
   - scrub to the very end
   - grips and scrambles still readable
5. **Copy report**, then paste it back into the chat.
6. **Save copy to Movies** (Android 10+) if you want to look at it on a PC. The copy lands in `Movies/CombatFlux POC`.

Also test once:

- **Cancel:** start a long clip and press Cancel halfway. The result is `CANCELLED`, and no partial file is left behind. Check with "Delete all temp outputs" (it should say 0) or with:

  ```
  adb shell ls /sdcard/Android/data/com.combatflux.cf_video_compressor_example/cache/cf_compress
  ```

- **Original untouched:** the source's size and date in Files/Gallery are unchanged, and it still plays.
- **VBR vs CBR:** compress clip A in both modes and compare size, quality and "Resulting bitrate".
- **Memory (optional):** while compressing, run:

  ```
  adb shell dumpsys meminfo com.combatflux.cf_video_compressor_example
  ```

  "TOTAL PSS" should stay far below the video's size.
- **Background:** lock the screen during a compression. This is a POC with no foreground service, so the OS may stop it. Note what happens.

Clean up with "Delete all temp outputs", then uninstall the app.

## Device smoke test (no video needed)

```
cd example && flutter test integration_test
```
