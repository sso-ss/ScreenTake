# AI-native editor

The shared editor, portable projects, typed commands, and local MCP connection are implemented. `EditorSession` is owned by
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
The local MCP transport forwards into this dispatcher; it has no separate editing or rendering implementation.

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
not interpret natural language or grant filesystem permissions for a client.

## Connect an AI client (MCP)

ScreenTake exposes the live native editor through a compiled Swift stdio MCP helper,
`screentake-mcp`. The signed app includes it at
`Contents/Helpers/screentake-mcp`; no Python, Node, package install, API key, or
computer-use control is required. Its source lives in `ScreenTakeMCP/`. Xcode builds
and signs the helper as an app dependency, then embeds it with Code Sign on Copy.
It uses the same architecture and minimum macOS version as the app.

Launch ScreenTake, then open ScreenTake → AI Connection… to check the owning app
process, copy setup JSON, or disable/retry the connection. It is enabled initially;
disabling persists across app launches. Only one app instance owns the connection.
If another instance owns it, disable there or quit that instance and retry here.
Disabling stops new requests; an already accepted command may finish. A bridge may
remain running while the app is restarted; subsequent tool calls reconnect.

Use **Copy Setup** to get the executable path for the app you are actually running.
For an app installed in `/Applications`, a STDIO server uses:

```text
Name: screentake
Command: /Applications/ScreenTake.app/Contents/Helpers/screentake-mcp
Arguments: (none)
```

The CLI equivalent is:

```sh
codex mcp add screentake -- "/Applications/ScreenTake.app/Contents/Helpers/screentake-mcp"
```

Or configure a trusted project's `.codex/config.toml` (or your user configuration):

```toml
[mcp_servers.screentake]
command = "/Applications/ScreenTake.app/Contents/Helpers/screentake-mcp"
args = []
startup_timeout_sec = 10
tool_timeout_sec = 150
```

For this checkout, `./Launch ScreenTake.command` builds the helper inside
`.build/DerivedData/Build/Products/Debug/ScreenTake.app/Contents/Helpers/`.
Copy Setup returns that app's absolute path. This project's local, uncommitted
`.codex/config.toml` points there. Existing Python-based configurations must be
replaced with the native command and empty arguments. If you move the app, copy
setup again so your client uses its new location.

Restart the client connection after updating the server. Setup follows the official
[Codex MCP documentation](https://learn.chatgpt.com/docs/extend/mcp?surface=cli).
The helper starts and discovers tools while the app is offline; calls then return
`connection_unavailable` with recovery instructions. A read-only connection check:

```sh
"/Applications/ScreenTake.app/Contents/Helpers/screentake-mcp" --check
```

The server implements MCP initialization/version negotiation, ping, tool listing
and calling, and a `screentake://editor/project` JSON resource. All 13 typed commands
above are tools, with complete input schemas. `get_preview_frame(jobID, index)` is
an additional read-only tool returning an actual PNG image from a successful preview
job, bounded to 1024 pixels per side. `get_job` lists frame timestamps/paths; only
registered job artifacts can be requested as images. The original full-resolution
PNG remains available locally. Responses include text, `isError`, and structured
content for protocol versions supporting it. Notifications produce no stdout output.

A typical AI workflow is:

1. Read `get_project` and inspect current settings and revision.
2. Call `apply_edits` with that `projectID`, `expectedRevision`, and a settings batch.
   Optionally supply a stable UUID `requestID` for safe retries.
3. Use the returned revision to call `render_preview`; poll `get_job` with its job ID.
4. Inspect `get_preview_frame`, refine edits, and repeat as needed.
5. Save a portable project or call `export_video` and poll its job to completion.

Native edits and AI edits share state and undo history. If the user changes the
project between reading and editing, the command returns `stale_project`; read again
and reassess. Paths are absolute local paths; nested media references are `file:///`
URLs. Nested objects replace their fields using the native defaults where supported;
omitted top-level edit fields remain unchanged. Cuts, zoom segments, and narration
clips require their own UUID identifiers, as advertised in the schema. Silence
suggestions use source seconds; preview timestamps use edited-video seconds.
Jobs outlive bridge disconnects. After a lost response, retry using identical
arguments and the same `requestID`; a command may already have completed. Do not
repeat a failed/cancelled export with its old ID when intending to start a new job.
Request and job caches are scoped to the running app, bounded to 100 and 50 entries;
app restart or cache eviction ends that retry guarantee.

The app listens only on `/tmp/screentake-<uid>/editor.sock`, inside a private 0700
directory with a 0600 socket. Both native and bridge endpoints verify ownership;
both sides check peer UID. A private advisory lock prevents competing app
instances from stealing an active socket and permits safe recovery after a crash.
Unexpected files and symlinks are rejected. I/O runs away from the main actor, uses
bounded requests/timeouts, and admits at most eight simultaneous connections. There
is no TCP listener. Clients running as your macOS user can read media, edit settings,
and write exports/projects with the app's filesystem access; connect trusted clients.
The MCP adapter does not add transcription or an embedded language model.

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

Run `python3 test_mcp_bridge.py` against the bundled Debug helper for offline
protocol/schema and hostile-socket checks (or pass `--bridge /path/to/screentake-mcp`).
The suite runs the helper with an empty executable search path and verifies all
supported protocol versions, boolean/numeric distinctions, nested validation,
malformed and oversized framing, private socket permissions, symlink rejection,
partial/oversized responses, and clean client disconnects. Python is only a development
test driver, never a runtime requirement for the app or MCP helper. Run
`python3 tools/run_swift_checks.py test_editor_mcp.swift` for real stdio/socket/editor
integration, reconnects and retries, revision conflicts, resources, undo/redo,
portable projects, PNG pixels and dimensions, exported duration, malformed requests,
shutdown/restart, socket ownership, stale recovery, and file/symlink preservation.

The final signed app was also checked with the bundled stdio bridge: a portable
project opened in the UI, tool edits appeared in its ratio control, PNG retrieval and
video export completed, and a native ratio edit was read and undone over MCP. Native
Save Project / Open Project restored the saved ratio and two-second timeline. The
editor title retains the project name after media is packaged.
