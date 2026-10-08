# AI-native editor foundation

The first three AI-native milestones are implemented by `EditorSession`, owned by
`AppState.editorSession`. `SettingsView` observes this session and binds its controls
to the same draft, selection, and undo history available to direct callers.

The session owns video loading and metadata, the retained source and audio references,
draft and applied settings, preview generation and playback, undo/redo, rendering, and
completed-video downloads. File dialogs, capture setup, panel selection, and transient
timeline gestures remain presentation concerns. Native microphone and camera take
recorders belong to the session so their busy state also protects direct operations.

## Direct workflow

All session access runs on the main actor:

```swift
let session = AppState.shared.editorSession
try await session.openVideo(sourceURL)
try session.updateEdits {
    $0.trim.cuts = [VideoCut(start: 10, end: 12)]
    $0.ratio = .vertical
    $0.backgroundEnabled = true
}
await session.waitForPreview()
let preview = session.player?.currentItem
let renderedURL = try await session.applyChanges()
try await session.saveVideo(to: destinationURL)
```

Opening validates the new video before replacing the current session. Edits retain
the original source and player identity. Preview rebuilding is independent of the
view lifecycle, cancels superseded work, and rejects stale results. Rendering captures
the current draft; failures retain the editable source and previously applied result.
Downloading uses a staged copy before replacing a destination and requires pending
edits to be applied first. Saving an editable project does not require rendering.

Each draft mutation records an undo snapshot; `updateEdits` batches several settings
in one mutation. `beginUndoGroup` / `endUndoGroup` group compound native operations.
History is bounded to 100 undo entries, shared across canvas, timeline, and other
settings, and cleared when opening a new source. Resetting pending changes is itself
undoable. Timeline gestures still use local draft values until committed.

Both recordings and reopened projects retain the source, master audio, and mouse
data needed for click zoom, cursor rendering, webcam composition, trim, and narration.

## Portable projects

File → Save Project… (Shift-Command-S) writes a `.screenize` package. File → Open
Project… (Shift-Command-O) restores the draft into the same editor session. Version 2
stores the complete `VideoEditSettings`, including exact reordered timeline times,
camera sections and take timing, crop, zooms, voiceovers, volumes, and resolution.
The package embeds source video, Duo phone video, audio, mouse data, camera takes,
and narration under `media/`; its JSON uses only package-relative media paths.

Saving stages the whole package before replacing the previous version. Live undo,
redo, and applied settings have their media references remapped during Save and Save
As; removed takes needed by that history remain embedded until the session closes.
Reopened projects require rendering before downloading. Unsaved state tracks the
saved project revision, so saving the draft protects work without exporting first.

Loading rejects unsupported versions, invalid settings, escaping media paths, and
missing media before replacing the active project. The unused version 1 placeholder
format is explicitly unsupported rather than silently dropping its fields.

## Structured commands

`AppState.editorCommands` exposes a main-actor `EditorCommandDispatcher` with typed
`execute` and JSON `executeJSON` entry points. These call the same session as the UI.
This is an in-process command boundary; an external MCP transport is the next
milestone and is not part of these first three steps.

Supported operations:

| Operation | Input / result |
| --- | --- |
| `get_capabilities` | Lists commands and revision/job requirements |
| `get_project` | Full current settings, source/project references, durations, revision, busy and undo state |
| `open_video`, `open_project` | Absolute local path; replacing existing work requires current project ID/revision and explicit `discardUnsaved` when needed |
| `save_project` | Absolute `.screenize` path |
| `apply_edits` | Partial typed settings batch, committed as one undo operation |
| `undo`, `redo` | Shared editor history |
| `find_silences` | Job with suggested removals in retained source-time ranges |
| `render_preview` | Job with PNG artifacts at 1–12 edited-video timestamps |
| `export_video` | Job rendering and atomically saving to an absolute local path |
| `get_job`, `cancel_job` | Job ID; inspect or cancel queued/running work |

Every JSON request includes a UUID `id`. Read `get_project`, then supply its
`projectID` and `expectedRevision` for edits, saves, rendering, and analysis. A stale
revision returns `stale_project` without changing the draft. Partial settings use
the `EditorEdits` schema; omitted fields remain unchanged. `removeRanges` appends
source-time cuts, while `trim` replaces the full timeline. `restoreAutomaticZooms`
restores automatic zoom generation. For example:

```json
{
  "id": "A0525B78-4C74-4E54-AD2C-2B233100E53A",
  "operation": "apply_edits",
  "projectID": "028EF2E3-D650-459A-B292-E0B4F8B1316B",
  "expectedRevision": 4,
  "edits": {
    "ratio": "vertical",
    "originalAudioVolume": 0.8,
    "removeRanges": [{"id": "C36F123F-33D4-4F72-BB4E-5B2A9E130334", "start": 10, "end": 12}]
  }
}
```

Successful mutation requests are cached for the last 100 IDs. Retrying the same ID
and parameters returns its original result without repeating an edit or export;
reusing the ID with different parameters returns `request_id_reused`. Export retries
return the same job with its latest status, including a failed or cancelled job.
Commands rejected before execution are not cached; use a new request ID to start
another job after a failure or cancellation.

Jobs move through `queued`, `running`, and a terminal `succeeded`, `failed`, or
`cancelled` state; cancellation can report `cancelling` while resources shut down.
The session stays busy until teardown completes. Exports report rendering progress;
completed jobs include output paths, frames, or silence suggestions. The last 50 jobs
are retained. Preview artifacts live in the system temporary directory. Responses
use `ok` and structured `error.code` / `error.message` values. This dispatcher does
not interpret natural language or grant filesystem permissions for a future client.

## Verification

Run `python3 tools/run_swift_checks.py test_editor_session.swift`. The check exercises
real video and audio through direct session calls, preview and export pixels, duration,
canvas dimensions, native editor recreation, undo/redo, validation, atomic downloads,
source preservation, and superseded-preview cancellation. macOS media encoding and
native window access require execution outside a restricted sandbox.

Existing regression checks can use the same runner, for example
`python3 tools/run_swift_checks.py --render-only test_video_trim.swift test_live_edit_preview.swift`.
The optional screenshot checks in the preview suite require macOS screen capture
access; `--render-only` runs its actual frame, effect, and timing assertions without
those screenshots. The session suite still checks native editor recreation.
Build and launch the application with `./Launch ScreenTake.command` and the required
Developer ID signing identity.

Run `python3 tools/run_swift_checks.py test_editor_commands.swift` for project and
protocol checks. It verifies portable save/reopen after original media is deleted,
matching preview pixels and exported audio/duration, exact timeline persistence,
media retained for undo, failed save preservation, invalid projects, JSON commands,
revision checks, retry idempotence, jobs, rendering, silence suggestions, separate
master audio without duplication, portable Duo media, load/close races, and active
export cancellation that preserves an existing destination.
