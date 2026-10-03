## 0.2.0

* iOS implementation (AVFoundation AVAssetReader/AVAssetWriter, PHPicker) behind the same
  platform contract as Android. Plugin privacy manifest (disk space, E174.1).
* `AnalysisVideoPreparer.requireMp4H264` (opt-in, default false): compress sources that fit
  but are not H.264 in an MP4 file (iPhone HEVC .MOV).
* Android code unchanged.

## 0.1.0

* Android Media3 on-device compression for CombatFlux.
