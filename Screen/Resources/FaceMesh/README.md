# Face mesh model

468 relative XYZ facial landmarks, inferred locally from a 192 × 192 RGB crop. Z is relative camera-space depth, not measured depth or physical distance.

- Original architecture/weights: Google MediaPipe Face Mesh, Apache 2.0.
- Core ML conversion: https://github.com/gouthamvgk/facemesh_coreml_tf at e65a8211ca694dd9517dd17837965d5858ee2e5f, Apache 2.0 (LICENSE.txt).
- FaceMesh.mlmodel SHA-256: 23dce7177c38a9be548abb1e337d4180ce14aca82905ea42c234136dbb1401ab
- Input: `input_image`, RGB 192 × 192, embedded scale 1/127.5 and bias −1.
- Output: `points_confidence`, 468 interleaved XYZ coordinates in crop-pixel units plus a presence logit. Y points down in model output; Z points away from the camera.
- triangles.json: 898 triangles from MediaPipe canonical_face_model.obj, https://github.com/google-ai-edge/mediapipe/blob/master/mediapipe/modules/face_geometry/data/canonical_face_model.obj (Apache 2.0).

The app does not download models or upload camera frames at runtime. Xcode compiles the checked-in model into the signed application.
