# Recording latency validation

Validated October 9, 2026 against the recording pipeline changes in `75fdbdd`
(original local commit `cbc8981`, before switching public commit metadata to the
GitHub no-reply email address).

A 31.280-second live screen-and-camera recording became ready for editing
**1.007 seconds after Stop**, while retaining native capture dimensions.

| Stage | Seconds |
| --- | ---: |
| Capture and sidecar finalization | 0.366 |
| Editor handoff, audio preparation, and live preview setup | 0.641 |
| Total Stop to editor ready | **1.007** |

## Measurement

Application log timestamps, America/Vancouver:

- Stop entered: 17:50:28.441300.
- Recording sidecars finalized: 17:50:28.807228.
- Editor ready: 17:50:29.448279.

The start marker was the existing `Stopping recording…` log in
`RecordingState.stopRecording()`. Temporary markers recorded completion of
`RecordingCoordinator.stopRecording()` and completion of the recording's
`EditorSession.openSource()` preview setup. Both temporary markers were removed
after measurement.

The ready marker followed preview-item creation and the initial seek. This
measures session readiness, rather than the display's exact first paint or
completion of every timeline thumbnail. The native editor subsequently showed
enabled editing controls and screen, camera, and audio lanes.

## Recording conditions

- An animated test window displayed text, one-pixel bars, a moving square, and
  elapsed time. Capture was started and stopped through the native app.
- Raw screen: 1824 × 1236, HEVC, 31.280 seconds. Variable-frame-rate capture was
  configured for up to 60 fps; the recorded average was approximately 34.109 fps.
- Camera: 1920 × 1080, H.264, 31.280 seconds, approximately 25 fps.
- Microphone enabled. Synchronized preview audio contained one audio track,
  no video tracks, and a duration of 31.213 seconds.
- Landscape desktop canvas, Preserve source resolution, cursor and automatic
  zoom enabled, and a camera overlay. Face-follow, beauty, and makeup were off.
- No post-recording video export ran during the measured interval. Rendering
  remained deferred to Apply Changes or Download.

## Scope of the result

This was one live-capture measurement. There was no matched live baseline, so
the result does not establish a percentage improvement or guarantee the same
latency for other durations, hardware, or face effects.

The larger portion of the remaining delay was editor preparation. Further
profiling should separate audio assembly from preview construction and include
multi-minute recordings and face-follow/effects before changing quality settings.

The recording-quality and ruler regression checks passed before this benchmark,
including deferred export, native pixel alignment, playback through preview and
view replacement, paused seeks, and original-media preservation. The final app
was rebuilt using `Launch ScreenTake.command`; its required Developer ID signing
identity and strict signature verification passed.

Detailed local evidence remains under `.build/quality-and-latency/live-stop/`:
`timing-results.json`, `events.ndjson`, `audio-info.log`, and decoded frames.
Media and settings were saved to
`.build/session-backups/live-stop-latency.screentake` and restored in the editor.
Generated recordings and logs are not included in this commit.
