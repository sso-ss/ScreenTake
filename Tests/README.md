# Development checks

These standalone checks cover recording, editing, audio, camera, timeline, and export behavior. They are development sources and are not bundled with the app.

Run from the repository root so checks can find app sources, assets, and local build products:

```sh
python3 tools/run_swift_checks.py Tests/test_editor_session.swift
python3 tools/run_swift_checks.py --render-only Tests/test_video_trim.swift
python3 tools/run_swift_checks.py Tests/test_editor_mcp.swift
```

Bare filenames also work, and the runner defaults to `test_editor_session.swift` when no checks are specified. `--render-only` skips optional screenshot checks in checks that support it. Some checks require recording permissions, hardware, a supplied clip, or a separately built app module.

The MCP integration check runs `Tests/test_mcp_bridge.py` with its temporary helper. For offline protocol checks against an existing Debug app helper, run `python3 Tests/test_mcp_bridge.py`; use `--bridge` to select a different helper.
