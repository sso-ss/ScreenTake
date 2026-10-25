# Official MediaPipe runtime

ScreenTake and the standalone Lash Lab use the official native Face Landmarker graph in VIDEO mode,
one face per stream, with detection/presence/tracking thresholds all at 0.5.
The graph handles detection, rotated face crops, tracking and landmark filtering.
No Python process or converted CoreML model is used in the live path.

- Runtime: PyPI `mediapipe==1.1.1`, `py3-none-macosx_11_0_arm64` wheel.
  `mediapipe/tasks/c/libmediapipe.dylib` is vendored unchanged inside
  `libmediapipe_source.so.gz` (35 MB archive, 106 MB unpacked).
- Model: Google's [Face Landmarker float16 version 1](https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task).
- License and NOTICE: copied from that wheel's distribution metadata.
- C ABI subset: `Screen/Core/Render/FaceEffects/MediaPipeBridge.h`, checked
  against the pinned package by `experiments/lash-lab/scripts/check_mediapipe_bridge.py`.
- `distribution/embed-mediapipe.sh` expands the archive into the app Frameworks
  folder and signs it with the required Developer ID before the app is signed.
  There are no build-time downloads. Its original install name is
  `@rpath/libmediapipe_source.so`; system frameworks are its only dependencies.
- The pinned runtime requires Apple silicon and macOS 14+. It is loaded lazily
  with `dlopen`, without making the app itself require macOS 14. macOS 13 and
  Intel retain their existing Vision/Core ML effects and do not offer Soft Peach.

SHA-256:

```
266ff96f78f8ddf04bca35fe1d14daebab32ee2c7977ba8f400f2c6341e22b28  libmediapipe.dylib
64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff  face_landmarker.task
```

The graph returns 478 face landmarks. Each eyelid loop uses 16 actual anchors
(9-point upper and lower arcs sharing the two corners). The 64-point drawing
contour is interpolation, not additional detected detail. Coordinates are mapped
from normalized top-left to image pixels with a bottom-left origin once. Pose
uses the graph's column-major transformation matrix and the renderer's
`Rz(roll) Ry(yaw) Rx(pitch)` order.

Eye contours are direct graph results with fixed landmark correspondence. The
live path does not mix Vision, IrisLandmark, pixel-edge fitting, held stale eyes,
or the legacy temporal smoother. A missing face produces no lash overlay. The
graph does not guarantee correct invisible-eye geometry or full-profile
acquisition. ScreenTake hand-pose protection and bilateral skin smoothing are
shared with the lab. Tonal dark-strand rejection is not semantic hair segmentation.

## Nose surface correspondence

`canonical_face_model.obj` is the official 468-vertex correspondence mesh from
[MediaPipe v0.10.14](https://raw.githubusercontent.com/google-ai-edge/mediapipe/v0.10.14/mediapipe/modules/face_geometry/data/canonical_face_model.obj),
under the same Apache-2.0 license. Its XY coordinates define pigment placement;
its face shape is never substituted for the tracked face. The current graph's
projected XY positions and relative Z depths transport and occlude the pigment.

SHA-256: `8bac80443397e113f41a8b565ea72c59390bc031d9defab289dba7bc0c54e618`.
