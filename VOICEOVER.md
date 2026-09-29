# Voiceover and audio timeline

1. Finish a screen recording or import a video, then select **Audio**.
2. Move the timeline playhead to where narration should begin.
3. Choose **Record Voiceover** and allow microphone access if macOS requests it.
4. Watch the video and narrate. **Stop & Keep** adds the take; **Cancel** discards it. Recording also stops at the video's end or when playback pauses.
5. Drag the purple voiceover strips to move takes and drag their edges to trim. The Audio panel also offers precise start and trim controls, separate original/voiceover volume and mute controls, and take removal.
6. Choose **Apply Changes**, then **Download** to save a video with the mixed audio.

The teal waveform represents the original video's combined audio. Purple strips represent narration takes. Empty tracks stay hidden. Imported audio can also be added at the playhead.

Voiceover uses the Mac's default microphone. Preview audio is muted during recording to avoid capturing speaker playback. Voiceovers keep their positions on the edited timeline when video clips are rearranged or removed, so review narration timing after changing the video. Audio extending past the video's end is clipped in preview and export.

Editing is session-based, like the rest of the existing editor. Apply and download your finished video before closing the session; reopening an exported movie does not restore separate editable voiceover takes.

`test_voiceover.swift` checks decoded audio timing, independent levels/mutes, source trims, end clipping, waveform levels, and narration exports with no original audio. Its `--ui` option renders the audio controls and timeline at 1000×680 and 800×500. Live microphone quality and hardware synchronization still require a recording on the user's selected input device.
